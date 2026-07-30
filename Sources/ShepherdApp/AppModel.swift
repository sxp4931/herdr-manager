import Foundation
import Observation
import HerdrManagerCore

// MARK: - TriageScope

/// The panel's three-way scope picker. Replaces the old opaque `showAll`
/// eye-toggle: each case is a named, countable slice of the herd instead of
/// a binary "everything / attention-only" switch.
enum TriageScope: String, CaseIterable, Hashable {
    case needsYou
    case running
    case all

    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .running: return "Running"
        case .all: return "All"
        }
    }
}

// MARK: - WorkspaceOption

/// A workspace as offered in the "New agent" menu — id for `createTab`,
/// name for display.
struct WorkspaceOption: Identifiable, Equatable {
    let id: String
    let name: String
}

/// An existing tab the New Agent menu can add a split to. `id` is one occupied
/// target pane in that tab; a terminal pane still hosts only one agent.
struct AgentPlacementOption: Identifiable, Equatable {
    let id: String
    let label: String
}

// MARK: - NewAgentState

/// Transient state for the footer's "New agent" flow, surfaced so the
/// footer can show "Starting claude…" instead of failing silently.
enum NewAgentState: Equatable {
    case idle
    case starting(kind: String)
}

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

    /// Persisted on the model (not `@AppStorage`) so it survives the panel
    /// closing and reopening within one app run, per the triage-picker spec.
    var scope: TriageScope = .needsYou
    var selectedAgentId: AgentID?
    var pendingActions: [PendingAction] = []
    var metadataWriteBackEnabled: Bool = true

    /// Cached `server.agent_manifests` result for the "New agent" menu —
    /// fetched once, not on every menu open.
    private(set) var availableAgentKinds: [String] = []
    /// Cached workspace id -> label options for the "New agent" menu,
    /// refreshed on every herd resync.
    private(set) var workspaceOptions: [WorkspaceOption] = []
    private(set) var newAgentState: NewAgentState = .idle

    /// User-controlled notification master switch (persisted by NotificationManager).
    /// Stored on the model so @Observable tracks it for the footer toggle; the
    /// `didSet` pushes changes into NotificationManager (does not fire during init).
    var notificationsEnabled: Bool = false {
        didSet { notificationManager.setEnabled(notificationsEnabled) }
    }

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
    private var hasLoadedAgentKinds = false
    /// Raw `agent.list` entries from the last herd resync — richer than the
    /// `Agent` the store publishes (carries `focused`/`foregroundCwd`), used
    /// to seed the "New agent" flow's cwd guess.
    private var lastHerdAgents: [HerdrAgentInfo] = []
    private var lastTabNames: [String: String] = [:]

    // MARK: - Init

    init() {
        let socketPath = Self.resolveSocketPath()
        self.adapter = LiveHerdrAdapter(socketPath: socketPath)
        // Notification authorization is gated on the user setting inside
        // NotificationManager; only request when enabled.
        if notificationManager.isEnabled {
            notificationManager.requestAuthorization()
        }
        // Seed the observable toggle from the persisted preference (didSet does
        // not fire during initialization, so this won't re-trigger setEnabled).
        self.notificationsEnabled = notificationManager.isEnabled
    }

    // MARK: - Coalesced UI state
    //
    // The menu bar and panel are SwiftUI views bound to this @Observable model.
    // A plain stored-property write notifies observers even when the value is
    // unchanged, which re-renders the bar item. While herdr is offline the
    // background reconnect/poll loops run continuously; if they wrote the
    // observable state on every cycle the UI would flap ("reconnecting #0… #1…")
    // and re-render constantly. These helpers make the UI quiet: the background
    // keeps working, but the view only updates when an outcome actually changes.

    private func setConnection(_ state: HerdrConnectionState) {
        if connectionState != state { connectionState = state }
    }

    private func setLastError(_ message: String?) {
        if lastError != message { lastError = message }
    }

    private func setHealth(_ health: AdapterHealth) {
        if adapterHealth != health { adapterHealth = health }
    }

    /// Apply a resolved herd snapshot to the store and refresh the
    /// derived caches (`lastHerdAgents`, `workspaceOptions`) the "New agent"
    /// flow needs. The one place `HerdSnapshot` -> UI state happens, so every
    /// resync path (initial connect, periodic poll, manual resync, reconnect)
    /// stays in lockstep.
    private func applyHerd(_ snapshot: HerdSnapshot) {
        store.applyHerdSnapshot(snapshot)
        lastHerdAgents = snapshot.agents
        lastTabNames = snapshot.tabNames
        workspaceOptions = snapshot.workspaceNames
            .map { WorkspaceOption(id: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
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
                if self.metadataWriteBackEnabled != snap.metadataWriteBackEnabled {
                    self.metadataWriteBackEnabled = snap.metadataWriteBackEnabled
                }
            } catch {
                self.setLastError("Settings load failed: \(error.localizedDescription)")
            }
        }

        eventTask?.cancel()
        eventTask = Task { [weak self] in
            await self?.connectAndSync()
            await self?.runEventLoop()
        }

        // Poll pending actions every 2 seconds; reap stale entries alongside.
        // The assignment is guarded so an unchanged action set doesn't re-render
        // the panel every cycle.
        pendingActionsTask?.cancel()
        pendingActionsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                _ = try? await self.sharedActionStore.reapStale()
                let actions = await self.sharedActionStore.pendingActions()
                await MainActor.run {
                    if self.pendingActions != actions {
                        self.pendingActions = actions
                    }
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

        // Background reconciliation + quiet reconnect probe. This single loop is
        // the UI's connection authority: it polls herdr on a fixed cadence and
        // only updates the view when the *outcome* changes (offline -> online or
        // vice-versa, or the herd actually changed). It never writes a per-attempt
        // "reconnecting #N" state, so a dead socket produces a steady indicator
        // instead of a flapping one. When herdr comes back, the next successful
        // poll flips the UI to connected exactly once. `pane_updated` events
        // (see runEventLoop) drive the fast path between polls; this is a safety
        // net, not the primary update mechanism.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                do {
                    let snapshot = try await self.adapter.herdSnapshot()
                    // Probe succeeded -> we are (back) online.
                    self.setConnection(.connected)
                    self.applyHerd(snapshot)
                    self.setHealth(self.adapter.health())
                    self.updateDwellForAllAgents()
                    if !self.hasRestoredDwell {
                        self.hasRestoredDwell = true
                        self.store.applyRestoredDwell(self.dwellTracker.load(currentAgents: self.store.agents))
                    }
                    self.setLastError(nil)
                } catch {
                    // Probe failed. herdr is reached over TWO independent sockets
                    // (reqClient for requests, subClient for the event stream), so
                    // a failure here proves only that the *request* socket hiccuped
                    // — a slow `agent.list` on a large herd can time out while the
                    // subscription is still delivering events happily. Downgrading
                    // the UI on that alone reintroduces the connected/disconnected
                    // flap this rebuild removed. Only report offline when the event
                    // stream agrees we are offline.
                    //
                    // Do NOT touch lastError either: the connection indicator
                    // already conveys offline, and a recurring failure must not
                    // spam the banner.
                    if self.adapter.connectionState != .connected {
                        self.setConnection(.disconnected)
                    }
                }
            }
        }
    }

    func resync() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.adapter.herdSnapshot()
                self.applyHerd(snapshot)
                self.setConnection(.connected)
                self.setHealth(self.adapter.health())
                self.updateDwellForAllAgents()
                if !self.hasRestoredDwell {
                    self.hasRestoredDwell = true
                    self.store.applyRestoredDwell(self.dwellTracker.load(currentAgents: self.store.agents))
                }
                self.setLastError(nil)
            } catch {
                self.setLastError("Resync failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Connection

    private func connectAndSync() async {
        setConnection(.connecting)
        do {
            try await adapter.connect()
            setConnection(.connected)
            let snapshot = try await adapter.herdSnapshot()
            applyHerd(snapshot)
            setHealth(adapter.health())
            updateDwellForAllAgents()
            if !hasRestoredDwell {
                hasRestoredDwell = true
                store.applyRestoredDwell(dwellTracker.load(currentAgents: store.agents))
            }
            setLastError(nil)
            startDiagnosisLoops()
        } catch {
            setConnection(.disconnected)
            setLastError("Connect failed: \(error.localizedDescription)")
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
            // Update connection state only on genuine transitions. The adapter's
            // internal state ticks through .reconnecting(attempt:) on every
            // backoff; we deliberately never mirror that into the UI here (the
            // old code did, on every event, which flapped the menu bar). The UI
            // connection state is driven by these real transitions plus the
            // periodic poll in refreshTask/start(), all coalesced via setConnection.
            switch event {
            case .connected:
                setConnection(.connected)
                // Re-sync on reconnect
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let snapshot = try await self.adapter.herdSnapshot()
                        self.applyHerd(snapshot)
                        self.setHealth(self.adapter.health())
                        self.updateDwellForAllAgents()
                        if !self.hasRestoredDwell {
                            self.hasRestoredDwell = true
                            self.store.applyRestoredDwell(self.dwellTracker.load(currentAgents: self.store.agents))
                        }
                        self.startDiagnosisLoops()
                    } catch {
                        self.setLastError("Reconnect snapshot failed: \(error.localizedDescription)")
                    }
                }
            case .disconnected:
                setConnection(.disconnected)
                stopDiagnosisLoops()
            default:
                break
            }

            // Check for a blocked transition BEFORE applying (so we can compare
            // against the pre-event status) on whichever event shape carries a
            // status. `pane_updated` (`.paneUpdated`) is what herdr actually
            // sends on protocol 17; `.agentStatusChanged` is the legacy/dotted
            // shape kept for back-compat and rarely if ever fires live — both
            // are handled so notifications/diagnosis trigger from the real feed.
            if case .agentStatusChanged(let paneId, let agentStatus, let seq) = event {
                let agentId = AgentID(paneId)
                let previousStatus = store.agents[agentId]?.status
                let newStatus = AgentStatus(rawValue: agentStatus) ?? .unknown

                store.applyEvent(event)
                notifyAndDiagnoseIfNeeded(agentId: agentId, previousStatus: previousStatus, newStatus: newStatus, seq: seq)
            } else if case .paneUpdated(let info) = event {
                let agentId = AgentID(info.paneId)
                let previousStatus = store.agents[agentId]?.status
                let newStatus = AgentStatus(rawValue: info.agentStatus) ?? .unknown

                store.applyEvent(event)
                notifyAndDiagnoseIfNeeded(agentId: agentId, previousStatus: previousStatus, newStatus: newStatus, seq: info.stateChangeSeq)
            } else {
                store.applyEvent(event)
            }
        }
    }

    /// Shared "did this agent just become blocked/start working" reaction for
    /// both event shapes runEventLoop understands.
    private func notifyAndDiagnoseIfNeeded(agentId: AgentID, previousStatus: AgentStatus?, newStatus: AgentStatus, seq: UInt64?) {
        if newStatus == .blocked && previousStatus != .blocked {
            if let agent = store.agents[agentId] {
                _ = notificationManager.notifyBlocked(agent: agent, seq: seq)
            }
        }
        if (newStatus == .blocked || newStatus == .working) && previousStatus != newStatus {
            Task { [weak self] in
                guard let self else { return }
                await self.runDiagnosisAndNotify()
            }
        }
    }

    // MARK: - Actions
    //
    // Every write goes through the capability gate (`adapter.health()
    // .writesEnabled`) so an incompatible/unverified herdr protocol never
    // silently fires a write the server would reject anyway.

    /// Jump: focus the workspace first, then the pane — otherwise the user
    /// lands in the right pane of a workspace they can't see. Returns whether
    /// it succeeded so the panel can dismiss itself only on success.
    @discardableResult
    func jump(_ agent: Agent) async -> Bool {
        let health = adapter.health()
        guard health.writesEnabled else {
            setLastError("Jump skipped: \(health.reason ?? "writes disabled")")
            return false
        }
        do {
            try await adapter.focusWorkspace(agent.id.workspaceId)
            try await adapter.focus(paneId: agent.id.raw)
            setLastError(nil)
            return true
        } catch {
            setLastError("Jump failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Approve = Enter. Both claude and codex render permission prompts as a
    /// menu whose first, highlighted option is the affirmative one.
    func approve(_ agent: Agent) {
        sendKeys(agent, keys: ["enter"], actionName: "Approve")
    }

    /// Deny = Esc.
    func deny(_ agent: Agent) {
        sendKeys(agent, keys: ["esc"], actionName: "Deny")
    }

    private func sendKeys(_ agent: Agent, keys: [String], actionName: String) {
        Task { [weak self] in
            guard let self else { return }
            let health = self.adapter.health()
            guard health.writesEnabled else {
                self.setLastError("\(actionName) skipped: \(health.reason ?? "writes disabled")")
                return
            }
            do {
                try await self.adapter.sendKeys(paneId: agent.id.raw, keys: keys)
                self.setLastError(nil)
            } catch {
                self.setLastError("\(actionName) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Nudge: a free-text prompt sent straight to the agent's pane.
    func nudge(_ agent: Agent, text: String) {
        Task { [weak self] in
            guard let self else { return }
            let health = self.adapter.health()
            guard health.writesEnabled else {
                self.setLastError("Nudge skipped: \(health.reason ?? "writes disabled")")
                return
            }
            do {
                try await self.adapter.prompt(paneId: agent.id.raw, text: text)
                self.setLastError(nil)
            } catch {
                self.setLastError("Nudge failed: \(error.localizedDescription)")
            }
        }
    }

    /// Close agent — destructive; the caller (AgentRow) is responsible for
    /// requiring an explicit confirmation step before invoking this.
    func closeAgent(_ agent: Agent) {
        Task { [weak self] in
            guard let self else { return }
            let health = self.adapter.health()
            guard health.writesEnabled else {
                self.setLastError("Close skipped: \(health.reason ?? "writes disabled")")
                return
            }
            do {
                try await self.adapter.closePane(paneId: agent.id.raw)
                self.setLastError(nil)
                self.resync()
            } catch {
                self.setLastError("Close failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - New agent

    /// Fetch `server.agent_manifests` once and cache it; the footer menu
    /// calls this on first open rather than re-fetching every time.
    func loadAgentKindsIfNeeded() {
        guard !hasLoadedAgentKinds else { return }
        hasLoadedAgentKinds = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let kinds = try await self.adapter.availableAgentKinds()
                self.availableAgentKinds = kinds
            } catch {
                // Leave empty — the menu still offers the three pinned kinds.
                self.hasLoadedAgentKinds = false
            }
        }
    }

    /// Best-guess cwd for a new tab in `workspaceId`: the foreground cwd of
    /// whichever pane in that workspace herdr currently reports as focused,
    /// falling back to any pane in the workspace, falling back to nil (herdr
    /// then defaults the cwd itself). `agent.list`/`HerdSnapshot` don't carry
    /// a per-workspace "last focused pane" concept beyond the single globally
    /// focused pane, so this is a reasonable approximation, not a guarantee.
    private func cwdHint(forWorkspace workspaceId: String) -> String? {
        let inWorkspace = lastHerdAgents.filter { $0.workspaceId == workspaceId }
        let candidate = inWorkspace.first(where: { $0.focused }) ?? inWorkspace.first
        return candidate?.foregroundCwd ?? candidate?.cwd
    }

    func placementOptions(forWorkspace workspaceId: String) -> [AgentPlacementOption] {
        let byTab = Dictionary(
            grouping: lastHerdAgents.filter { $0.workspaceId == workspaceId },
            by: \.tabId
        )
        return byTab.compactMap { tabId, agents in
            guard let target = agents.first(where: { $0.focused }) ?? agents.first else {
                return nil
            }
            let tab = lastTabNames[tabId] ?? tabId
            let shortTab = String(tab.prefix(18))
            let count = agents.count
            return AgentPlacementOption(
                id: target.paneId,
                label: "\(shortTab) · \(count) agent\(count == 1 ? "" : "s")"
            )
        }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func cwdHint(forPane paneId: String) -> String? {
        guard let pane = lastHerdAgents.first(where: { $0.paneId == paneId }) else { return nil }
        return pane.foregroundCwd ?? pane.cwd
    }

    /// Start in either a new tab or a split beside `targetPaneId`. Both paths
    /// yield a fresh interactive shell before calling `agent.start`.
    func startNewAgent(kind: String, workspaceId: String, targetPaneId: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            let health = self.adapter.health()
            guard health.writesEnabled else {
                self.setLastError("New agent skipped: \(health.reason ?? "writes disabled")")
                return
            }
            self.newAgentState = .starting(kind: kind)
            defer { self.newAgentState = .idle }

            let cwd = targetPaneId
                .flatMap { self.cwdHint(forPane: $0) }
                ?? self.cwdHint(forWorkspace: workspaceId)
            do {
                let rootPaneId: String
                if let targetPaneId {
                    rootPaneId = try await self.adapter.splitPane(targetPaneId: targetPaneId, cwd: cwd)
                } else {
                    (_, rootPaneId) = try await self.adapter.createTab(
                        workspaceId: workspaceId, cwd: cwd, label: kind.capitalized, focus: true
                    )
                }
                do {
                    try await self.adapter.startAgent(paneId: rootPaneId, kind: kind, name: kind)
                    self.setLastError(nil)
                } catch {
                    let location = targetPaneId == nil ? "Tab" : "Split pane"
                    self.setLastError("\(location) created, but \(kind) did not start: \(error.localizedDescription)")
                }
            } catch {
                let location = targetPaneId == nil ? "tab" : "split pane"
                self.setLastError("Failed to create a \(location) for \(kind): \(error.localizedDescription)")
            }
            self.resync()
        }
    }

    // MARK: - Action Approval (MCP pending-actions queue)

    func approveAction(_ id: String) {
        Task {
            _ = try? await sharedActionStore.approve(id)
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
            _ = try? await sharedActionStore.deny(id)
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

    // MARK: - Threshold Overrides

    /// Set a per-occupant silent-threshold override, surfacing any settings
    /// error in `lastError` instead of swallowing it.
    func setThresholdOverride(for agent: Agent, minutes: Int) {
        let occupant = Self.fingerprintForAgent(agent)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.settingsStore.setOverride(occupant: occupant, minutes: minutes)
                self.setLastError(nil)
            } catch {
                self.setLastError("Settings save failed: \(error.localizedDescription)")
            }
        }
    }

    func resetThresholdOverride(for agent: Agent) {
        let occupant = Self.fingerprintForAgent(agent)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.settingsStore.removeOverride(occupant: occupant)
                self.setLastError(nil)
            } catch {
                self.setLastError("Settings save failed: \(error.localizedDescription)")
            }
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
        // Metadata write-back is a WRITE; respect the capability gate so an
        // incompatible/unverified protocol never receives writes.
        guard adapter.health().writesEnabled else { return }
        // Only attempt while actually connected; otherwise a dead socket would
        // fail every 30s and (even coalesced) keep an alarming banner pinned.
        guard connectionState == .connected else { return }
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
                    source: "shepherd",
                    tokens: ["stuck_for": "\(dwellMinutes)m"],
                    ttlMs: 45_000
                )
            } catch {
                setLastError("Metadata write-back failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Socket path resolution

    private static func resolveSocketPath() -> String {
        return LiveHerdrAdapter.resolveSocketPath()
    }
}
