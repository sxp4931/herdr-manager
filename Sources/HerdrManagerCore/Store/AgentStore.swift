import Foundation
import Observation

// MARK: - AgentStore

@MainActor
@Observable
public final class AgentStore {
    public private(set) var agents: [AgentID: Agent] = [:]

    public init() {}

    // MARK: - Snapshot

    public func applySnapshot(_ snapshot: HerdrSnapshot) {
        // Build lookup maps
        let wsMap = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceId, $0.name) })
        let tabMap = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.tabId, $0.name) })

        var newAgents: [AgentID: Agent] = [:]

        for pane in snapshot.panes {
            // Only track panes that have an agent
            guard pane.agent != nil || pane.agentStatus != "unknown" else { continue }

            let agentId = AgentID(pane.paneId)
            let status = AgentStatus(rawValue: pane.agentStatus) ?? .unknown
            let wsName = wsMap[pane.workspaceId] ?? ""
            let tabName = tabMap[pane.tabId] ?? ""

            let existing = agents[agentId]
            let enteredAt: Date
            if let ex = existing, ex.status == status {
                enteredAt = ex.enteredAt
            } else {
                enteredAt = Date()
            }

            let kind: AgentKind
            if let session = pane.agentSession {
                kind = AgentKind.custom(session.agent)
            } else if let agentName = pane.agent {
                kind = AgentKind.custom(agentName)
            } else {
                kind = .custom("unknown")
            }

            let name = pane.agent ?? pane.terminalTitleStripped ?? ""

            // Preserve a diagnosed verdict across periodic snapshots so the
            // few-second reconciliation refresh doesn't flicker "silent"/"gone"
            // lines back to a generic status verdict between diagnosis passes.
            // A genuine status change still resets to the status-derived verdict.
            let verdict: Verdict
            if let ex = existing, ex.status == status {
                verdict = ex.verdict
            } else {
                verdict = Self.verdict(for: status)
            }

            let agent = Agent(
                id: agentId,
                kind: kind,
                name: name,
                displayName: name,
                status: status,
                stateChangeSeq: pane.stateChangeSeq ?? 0,
                enteredAt: enteredAt,
                lastOutputAt: existing?.lastOutputAt,
                verdict: verdict,
                workspaceName: wsName,
                tabName: tabName,
                cwd: pane.foregroundCwd ?? pane.cwd ?? ""
            )
            newAgents[agentId] = agent
        }

        // Only publish a change when the herd actually differs. The periodic
        // reconciliation snapshot (every few seconds) usually returns an
        // identical herd; rewriting the dictionary anyway would fire @Observable
        // on a timer and re-render the menu-bar panel continuously — which makes
        // a MenuBarExtra window flicker. Skipping the no-op write keeps the UI
        // calm while still picking up genuine additions/removals instantly.
        if newAgents != agents {
            agents = newAgents
        }
    }

    // MARK: - Events

    public func applyEvent(_ event: HerdrEvent) {
        switch event {
        case .agentStatusChanged(let paneId, let agentStatus, let seq):
            let agentId = AgentID(paneId)
            guard var agent = agents[agentId] else { return }

            // Sequence guard: only apply if new seq >= current
            if let newSeq = seq, newSeq < agent.stateChangeSeq {
                return
            }

            let newStatus = AgentStatus(rawValue: agentStatus) ?? .unknown
            if newStatus != agent.status {
                agent.enteredAt = Date()
            }
            agent.status = newStatus
            if let seq { agent.stateChangeSeq = seq }
            agent.verdict = Self.verdict(for: newStatus)
            agents[agentId] = agent

        case .paneCreated(let paneId, let workspaceId, let tabId):
            let agentId = AgentID(paneId)
            if agents[agentId] == nil {
                agents[agentId] = Agent(
                    id: agentId,
                    status: .unknown,
                    workspaceName: workspaceId,
                    tabName: tabId
                )
            }

        case .paneClosed(let paneId):
            let agentId = AgentID(paneId)
            agents.removeValue(forKey: agentId)

        case .paneMoved(let paneId, let workspaceId, let tabId):
            let agentId = AgentID(paneId)
            if var agent = agents[agentId] {
                if let ws = workspaceId { agent.workspaceName = ws }
                if let tab = tabId { agent.tabName = tab }
                agents[agentId] = agent
            }

        case .connected, .disconnected, .ignored:
            break
        }
    }

    /// Apply persisted dwell timestamps back onto the live agents after a
    /// relaunch so displayed and diagnosed dwell time is not reset. Only
    /// entries the DwellTracker validated (occupant fingerprint + seq match)
    /// should be passed in. Restored timestamps are applied only when earlier
    /// than the current value (dwell is never moved forward).
    public func applyRestoredDwell(_ restored: [AgentID: DwellEntry]) {
        for (agentId, entry) in restored {
            guard var agent = agents[agentId] else { continue }
            if entry.enteredAt < agent.enteredAt {
                agent.enteredAt = entry.enteredAt
            }
            if let restoredOutput = entry.lastOutputAt,
               restoredOutput > (agent.lastOutputAt ?? .distantPast) {
                agent.lastOutputAt = restoredOutput
            }
            agents[agentId] = agent
        }
    }

    // MARK: - Computed Properties

    public var attentionAgents: [Agent] {
        agents.values
            .filter { $0.status == .blocked || $0.verdict.isSilent || $0.status == .done }
            .sorted { a, b in
                // blocked first, then done, then silent
                let priority: (Agent) -> Int = { agent in
                    switch agent.status {
                    case .blocked: return 0
                    case .done: return 1
                    default: return 2
                    }
                }
                let pa = priority(a)
                let pb = priority(b)
                if pa != pb { return pa < pb }
                return a.enteredAt < b.enteredAt
            }
    }

    public var blockedCount: Int {
        agents.values.filter { $0.status == .blocked }.count
    }

    public var silentCount: Int {
        agents.values.filter { $0.verdict.isSilent }.count
    }

    public var doneCount: Int {
        agents.values.filter { $0.status == .done }.count
    }

    // MARK: - Diagnosis

    /// Diagnose all non-idle agents and update their verdicts.
    /// - Parameters:
    ///   - adapter: The HerdrAdapter to use for herdr API calls.
    ///   - diagnoser: The Diagnoser to classify each agent.
    ///   - settings: Optional SettingsStore for per-agent silent-threshold
    ///     overrides. When nil, each agent falls back to the kind-based
    ///     default (source-compatible with the previous signature).
    public func diagnoseAll(
        adapter: HerdrAdapter,
        diagnoser: Diagnoser,
        settings: SettingsStore? = nil
    ) async {
        let nonIdle = agents.values.filter { $0.status != .idle }

        // Snapshot per-agent thresholds off the actor before the loop so we
        // don't hop into SettingsStore on every iteration.
        let thresholds: [String: TimeInterval]?
        if let settings {
            var map: [String: TimeInterval] = [:]
            for agent in nonIdle {
                // SettingsStore keys overrides by pane-id (the herdr session
                // identity). `agent.id.raw` is the full "wX:pY" form; the
                // pane component is what the UI persists.
                // Look up by occupant identity first (follows the agent across
                // panes), falling back to the pane-id key, then the default.
                let minutes = await settings.threshold(
                    for: agent.id.raw,
                    occupant: DwellTracker.fingerprint(for: agent)
                )
                map[agent.id.raw] = TimeInterval(minutes) * 60.0
            }
            thresholds = map
        } else {
            thresholds = nil
        }

        for agent in nonIdle {
            let override = thresholds?[agent.id.raw]
            let verdict = await diagnoser.diagnose(
                agent: agent,
                adapter: adapter,
                silentThreshold: override
            )
            // Update on MainActor (we're already @MainActor)
            if var current = agents[agent.id] {
                current.verdict = verdict
                agents[agent.id] = current
            }
        }
    }

    /// Start heartbeat polling. Returns a Task that polls every 10 seconds.
    /// The caller is responsible for cancelling the task.
    public func startHeartbeatPolling(adapter: HerdrAdapter, poller: HeartbeatPoller) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                guard let self else { return }

                let workingAgents = self.agents.values.filter { $0.status == .working }
                let updates = await poller.poll(agents: workingAgents, adapter: adapter)

                // Apply lastOutputAt updates on MainActor
                await MainActor.run {
                    for (agentId, date) in updates {
                        if var agent = self.agents[agentId] {
                            agent.lastOutputAt = date
                            self.agents[agentId] = agent
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private static func verdict(for status: AgentStatus) -> Verdict {
        switch status {
        case .blocked:
            return .awaitingInput(BlockClassification(
                kind: .unknownBlock, since: Date(), summary: "blocked"
            ))
        case .idle, .working: return .healthy
        case .done: return .healthy
        case .unknown: return .unclassifiable(reason: "unknown status")
        }
    }
}
