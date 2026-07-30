import Foundation
import Observation
import HerdrManagerCore

@MainActor
@Observable
final class AppModel {
    // MARK: - Owned state

    let store = AgentStore()
    private(set) var adapter: LiveHerdrAdapter
    private(set) var connectionState: HerdrConnectionState = .disconnected
    let sharedActionStore = SharedActionStore()
    let settingsStore = SettingsStore()
    let journal = Journal()
    let dwellTracker = DwellTracker()

    var showAll: Bool = false
    var selectedAgentId: AgentID?
    var pendingActions: [PendingAction] = []
    var metadataWriteBackEnabled: Bool = true

    /// The most recent user-visible error from resync / focus / settings /
    /// metadata / subscription paths. `nil` when everything is healthy. The
    /// panel footer renders this so failures are no longer silently swallowed.
    var lastError: String?

    /// Cached adapter health for the footer badge. Refreshed on every
    /// successful snapshot so protocol/version mismatches surface quickly.
    var adapterHealth: AdapterHealth?

    // MARK: - Private

    private let notificationManager = NotificationManager()
    private let diagnoser = Diagnoser()
    private let poller = HeartbeatPoller()
    private var eventTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var diagnosisTask: Task<Void, Never>?
    private var pendingActionsTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var hasStarted = false
    private var hasRestoredDwell = false

    // MARK: - Init

    init() {
        let socketPath = Self.resolveSocketPath()
        self.adapter = LiveHerdrAdapter(socketPath: socketPath)
        // Notification authorization is gated on the user setting inside
        // NotificationManager; only request when enabled.
        if notificationManager.isEnabled {
            notificationManager.requestAuthorization()
        }
    }

    // MARK: - Lifecycle

    func start() {
        // `start` spins up long-lived tasks; it must run exactly once. The
        // menu-bar label calls it from `onAppear`, which SwiftUI can re-invoke,
        // and re-running would cancel and recreate every task (and reconnect the
        // socket) — churn that can bounce the menu-bar window on open.
        guard !hasStarted else { return }
        hasStarted = true

        // Clean up old journal entries on launch
        Task {
            await journal.cleanup()
        }

        // Load settings
        Task {
            do {
                try await settingsStore.load()
                let snap = await settingsStore.settingsSnapshot()
                self.metadataWriteBackEnabled = snap.metadataWriteBackEnabled
            } catch {
                self.lastError = "Settings load failed: \(error.localizedDescription)"
            }
        }

        eventTask?.cancel()
        eventTask = Task { [weak self] in
            await self?.connectAndSync()
            await self?.runEventLoop()
        }

        // Poll pending actions every 2 seconds; reap stale entries alongside.
        pendingActionsTask?.cancel()
        pendingActionsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                await self.sharedActionStore.reapStale()
                let actions = await self.sharedActionStore.pendingActions()
                await MainActor.run {
                    self.pendingActions = actions
                }
            }
        }

        // Metadata write-back every 30 seconds
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                guard self.metadataWriteBackEnabled else { continue }
                await self.reportMetadataForStuckAgents()
            }
        }

        // Reconcile with herdr every few seconds. The live event stream is
        // edge-triggered and can drop or delay a pane appearing, which left the
        // UI showing a stale agent count until a manual ⌘R. A cheap periodic
        // snapshot is the safety net; applySnapshot preserves diagnosed state so
        // this never flickers the verdict lines.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                guard self.connectionState == .connected else { continue }
                do {
                    let snapshot = try await self.adapter.snapshot()
                    self.store.applySnapshot(snapshot)
                    self.adapterHealth = self.adapter.health()
                    self.updateDwellForAllAgents()
                    // Restore persisted dwell once after the first successful snapshot.
                    if !self.hasRestoredDwell {
                        self.hasRestoredDwell = true
                        _ = self.dwellTracker.load(currentAgents: self.store.agents)
                    }
                } catch {
                    self.lastError = "Snapshot failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func resync() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.adapter.snapshot()
                self.store.applySnapshot(snapshot)
                self.connectionState = self.adapter.connectionState
                self.adapterHealth = self.adapter.health()
                self.updateDwellForAllAgents()
                if !self.hasRestoredDwell {
                    self.hasRestoredDwell = true
                    _ = self.dwellTracker.load(currentAgents: self.store.agents)
                }
                self.lastError = nil
            } catch {
                self.lastError = "Resync failed: \(error.localizedDescription)"
            }
        }
    }

    func focusAgent(_ agent: Agent) {
        let paneId = agent.id.raw
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.adapter.focus(paneId: paneId)
                self.lastError = nil
            } catch {
                self.lastError = "Focus failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Connection

    private func connectAndSync() async {
        connectionState = .connecting
        do {
            try await adapter.connect()
            connectionState = .connected
            let snapshot = try await adapter.snapshot()
            store.applySnapshot(snapshot)
            adapterHealth = adapter.health()
            updateDwellForAllAgents()
            if !hasRestoredDwell {
                hasRestoredDwell = true
                _ = dwellTracker.load(currentAgents: store.agents)
            }
            lastError = nil
            startDiagnosisLoops()
        } catch {
            connectionState = .disconnected
            lastError = "Connect failed: \(error.localizedDescription)"
        }
    }

    private func startDiagnosisLoops() {
        heartbeatTask?.cancel()
        diagnosisTask?.cancel()

        // Heartbeat polling every 10 seconds
        heartbeatTask = store.startHeartbeatPolling(adapter: adapter, poller: poller)

        // Periodic diagnosis every 15 seconds
        diagnosisTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                await self.runDiagnosisAndNotify()
            }
        }
    }

    private func stopDiagnosisLoops() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        diagnosisTask?.cancel()
        diagnosisTask = nil
    }

    private func runDiagnosisAndNotify() async {
        // Snapshot previous silent state for notification diff
        let previousSilentIds = Set(store.agents.values.filter { $0.verdict.isSilent }.map { $0.id })

        await store.diagnoseAll(adapter: adapter, diagnoser: diagnoser, settings: settingsStore)

        // Check for newly-silent agents
        for agent in store.agents.values {
            if agent.verdict.isSilent && !previousSilentIds.contains(agent.id) {
                notificationManager.notifySilent(agent: agent)
            }
            // Clear silent notification key when agent is no longer silent
            if !agent.verdict.isSilent && previousSilentIds.contains(agent.id) {
                notificationManager.clearSilentNotification(for: agent.id)
            }
        }

        // Persist dwell after diagnosis so significant verdict changes are saved.
        dwellTracker.save()
    }

    private func runEventLoop() async {
        let stream = adapter.events()
        for await event in stream {
            // Update connection state from events
            switch event {
            case .connected:
                connectionState = .connected
                // Re-sync on reconnect
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let snapshot = try await self.adapter.snapshot()
                        self.store.applySnapshot(snapshot)
                        self.adapterHealth = self.adapter.health()
                        self.updateDwellForAllAgents()
                        if !self.hasRestoredDwell {
                            self.hasRestoredDwell = true
                            _ = self.dwellTracker.load(currentAgents: self.store.agents)
                        }
                        self.startDiagnosisLoops()
                    } catch {
                        self.lastError = "Reconnect snapshot failed: \(error.localizedDescription)"
                    }
                }
            case .disconnected:
                connectionState = .disconnected
                stopDiagnosisLoops()
            default:
                break
            }

            // Check for blocked transition BEFORE applying (so we can compare)
            if case .agentStatusChanged(let paneId, let agentStatus, let seq) = event {
                let agentId = AgentID(paneId)
                let previousStatus = store.agents[agentId]?.status
                let newStatus = AgentStatus(rawValue: agentStatus) ?? .unknown

                store.applyEvent(event)

                // Notify on transition TO blocked
                if newStatus == .blocked && previousStatus != .blocked {
                    if let agent = store.agents[agentId] {
                        let notified = notificationManager.notifyBlocked(agent: agent, seq: seq)
                        _ = notified // tracked internally
                    }
                }

                // Trigger immediate diagnosis on transition to blocked or working
                if (newStatus == .blocked || newStatus == .working) && previousStatus != newStatus {
                    Task { [weak self] in
                        guard let self else { return }
                        await self.runDiagnosisAndNotify()
                    }
                }
            } else {
                store.applyEvent(event)
            }

            // Keep connection state in sync with adapter
            connectionState = adapter.connectionState
        }
    }

    // MARK: - Action Approval

    func approveAction(_ id: String) {
        Task {
            await sharedActionStore.approve(id)
            await journal.record(JournalEntry(
                actionId: id,
                tool: await sharedActionStore.get(id)?.tool ?? "unknown",
                params: await sharedActionStore.get(id)?.params ?? [:],
                caller: "ui",
                preState: "pending",
                postState: "approved",
                outcome: "approved"
            ))
        }
    }

    func denyAction(_ id: String) {
        Task {
            await sharedActionStore.deny(id)
            await journal.record(JournalEntry(
                actionId: id,
                tool: await sharedActionStore.get(id)?.tool ?? "unknown",
                params: await sharedActionStore.get(id)?.params ?? [:],
                caller: "ui",
                preState: "pending",
                postState: "denied",
                outcome: "denied"
            ))
        }
    }

    // MARK: - Dwell tracking

    /// Update the dwell tracker for every known agent. Called after each
    /// successful snapshot so the persisted dwell state stays in lockstep
    /// with the live herd.
    private func updateDwellForAllAgents() {
        for agent in store.agents.values {
            dwellTracker.update(
                agentId: agent.id,
                status: agent.status,
                enteredAt: agent.enteredAt,
                lastOutputAt: agent.lastOutputAt,
                occupantFingerprint: Self.fingerprintForAgent(agent),
                stateChangeSeq: agent.stateChangeSeq
            )
        }
    }

    /// Derive a stable occupant fingerprint from an Agent. Mirrors
    /// `DwellTracker.fingerprint(for:)` which is `internal` to Core and
    /// therefore not directly callable from the app module.
    private static func fingerprintForAgent(_ agent: Agent) -> String {
        switch agent.kind {
        case .claude: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        case .aider: return "aider"
        case .gemini: return "gemini"
        case .custom(let name): return "custom:\(name)"
        }
    }

    // MARK: - Metadata Write-back

    private func reportMetadataForStuckAgents() async {
        let stuckAgents = store.agents.values.filter {
            $0.status == .blocked || $0.status == .working
        }
        for agent in stuckAgents {
            let enteredAt = agent.enteredAt
            let dwellMinutes = Int(Date().timeIntervalSince(enteredAt) / 60)
            guard dwellMinutes > 0 else { continue }
            do {
                try await adapter.reportMetadata(
                    paneId: agent.id.raw,
                    source: "herdr-manager",
                    tokens: ["stuck_for": "\(dwellMinutes)m"],
                    ttlMs: 45_000
                )
            } catch {
                lastError = "Metadata write-back failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Socket path resolution

    private static func resolveSocketPath() -> String {
        return LiveHerdrAdapter.resolveSocketPath()
    }
}
