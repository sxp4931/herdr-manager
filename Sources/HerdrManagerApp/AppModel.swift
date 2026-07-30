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

    var showAll: Bool = false
    var selectedAgentId: AgentID?
    var pendingActions: [PendingAction] = []
    var metadataWriteBackEnabled: Bool = true

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

    // MARK: - Init

    init() {
        let socketPath = Self.resolveSocketPath()
        self.adapter = LiveHerdrAdapter(socketPath: socketPath)
        notificationManager.requestAuthorization()
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
            try? await settingsStore.load()
            let snap = await settingsStore.settingsSnapshot()
            self.metadataWriteBackEnabled = snap.metadataWriteBackEnabled
        }

        eventTask?.cancel()
        eventTask = Task { [weak self] in
            await self?.connectAndSync()
            await self?.runEventLoop()
        }

        // Poll pending actions every 2 seconds
        pendingActionsTask?.cancel()
        pendingActionsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
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
                if let snapshot = try? await self.adapter.snapshot() {
                    self.store.applySnapshot(snapshot)
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
            } catch {
                // resync failure is non-fatal; event loop will catch up
            }
        }
    }

    func focusAgent(_ agent: Agent) {
        let paneId = agent.id.raw
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.adapter.focus(paneId: paneId)
            } catch {
                // focus failure is non-fatal
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
            startDiagnosisLoops()
        } catch {
            connectionState = .disconnected
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

        await store.diagnoseAll(adapter: adapter, diagnoser: diagnoser)

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
                        self.startDiagnosisLoops()
                    } catch {}
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

    func approveAll(_ ids: [String]) {
        for id in ids {
            approveAction(id)
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
                // Non-fatal: metadata write-back failure
            }
        }
    }

    // MARK: - Socket path resolution

    private static func resolveSocketPath() -> String {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
           !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("herdr/herdr.sock")
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".config/herdr/herdr.sock")
    }
}
