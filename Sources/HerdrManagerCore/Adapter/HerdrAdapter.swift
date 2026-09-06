import Foundation

// MARK: - HerdrAdapter Protocol

public protocol HerdrAdapter: Sendable {
    func snapshot() async throws -> HerdrSnapshot
    func read(paneId: String, source: PaneReadSource, lines: Int?) async throws -> PaneReadResult
    func explain(paneId: String) async throws -> AgentExplainResult
    func processInfo(paneId: String) async throws -> ProcessInfoResult
    func focus(paneId: String) async throws
    func events() -> AsyncStream<HerdrEvent>
    var connectionState: HerdrConnectionState { get }

    // MARK: - Write methods
    func sendKeys(paneId: String, keys: [String]) async throws
    func prompt(paneId: String, text: String) async throws
    func closePane(paneId: String) async throws
    func createWorkspace(cwd: String, label: String?) async throws -> WorkspaceCreation
    func startAgent(paneId: String, kind: String, name: String) async throws
    func waitStatus(paneId: String, until: [String], timeoutMs: Int) async throws -> Bool
    func reportMetadata(paneId: String, source: String, tokens: [String: String], ttlMs: Int) async throws
}

public extension HerdrAdapter {
    func read(paneId: String, source: PaneReadSource) async throws -> PaneReadResult {
        try await read(paneId: paneId, source: source, lines: nil)
    }
}

// MARK: - LiveHerdrAdapter

/// Two sockets, by design. `reqClient` carries request/response traffic
/// (snapshot, explain, reads, writes) — one short transaction at a time,
/// serialized inside the client. `subClient` is dedicated to the long-lived
/// `events.subscribe` stream and is NEVER used for requests. Sharing one socket
/// between a blocking event read-loop and concurrent requests raced two readers
/// on a single file descriptor, corrupting the NDJSON framing and flapping the
/// connection — which both stalled live updates and reflowed the menu bar.
public final class LiveHerdrAdapter: HerdrAdapter, @unchecked Sendable {
    private let reqClient: NDJSONClient
    private let subClient: NDJSONClient
    /// Dedicated serial queue for blocking socket I/O. Runs request transactions
    /// off the cooperative pool and off the main actor so a stalled herdr socket
    /// can never freeze the menu-bar UI or starve Swift concurrency's threads.
    /// Serial (like the client's txLock) so transactions never interleave.
    private let ioQueue = DispatchQueue(label: "HerdrManager.adapterIO", qos: .userInitiated)
    private let stateLock = NSLock()
    private var _connectionState: HerdrConnectionState = .disconnected
    private var _latestProtocolVersion: Int = 0
    private var eventContinuation: AsyncStream<HerdrEvent>.Continuation?
    private let eventStream: AsyncStream<HerdrEvent>
    private var eventLoopTask: Task<Void, Never>?

    public init(socketPath: String) {
        self.reqClient = NDJSONClient(socketPath: socketPath, ioTimeoutSeconds: 30)
        self.subClient = NDJSONClient(socketPath: socketPath, ioTimeoutSeconds: 0)
        var continuation: AsyncStream<HerdrEvent>.Continuation?
        self.eventStream = AsyncStream { cont in
            continuation = cont
        }
        self.eventContinuation = continuation
    }

    private func onIO<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            ioQueue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public var connectionState: HerdrConnectionState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _connectionState
    }

    private func setConnectionState(_ state: HerdrConnectionState) {
        stateLock.lock()
        _connectionState = state
        stateLock.unlock()
    }

    private func setLatestProtocol(_ version: Int) {
        stateLock.lock()
        _latestProtocolVersion = version
        stateLock.unlock()
    }

    private func latestProtocol() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _latestProtocolVersion
    }

    public func connect() async throws {
        setConnectionState(.connecting)
        try await onIO { [reqClient] in try reqClient.connect() }
        setConnectionState(.connected)
    }

    public func snapshot() async throws -> HerdrSnapshot {
        let snap = try await onIO { [reqClient] in
            let result = try reqClient.sendRead(method: "session.snapshot", params: [:])
            return try LiveHerdrAdapter.parseSnapshot(result)
        }
        setLatestProtocol(snap.protocol)
        return snap
    }

    public func read(paneId: String, source: PaneReadSource) async throws -> PaneReadResult {
        try await read(paneId: paneId, source: source, lines: nil)
    }

    public func read(paneId: String, source: PaneReadSource, lines: Int?) async throws -> PaneReadResult {
        try await onIO { [reqClient] in
            let params = LiveHerdrAdapter.readParams(paneId: paneId, source: source, lines: lines)
            let result = try reqClient.sendRead(method: "pane.read", params: params)
            return LiveHerdrAdapter.parsePaneRead(result, requested: source)
        }
    }

    internal static func readParams(
        paneId: String,
        source: PaneReadSource,
        lines: Int?
    ) -> [String: Any] {
        var params: [String: Any] = [
            "pane_id": paneId,
            "source": source.rawValue
        ]
        if let lines { params["lines"] = lines }
        return params
    }

    internal static func parsePaneRead(_ dict: [String: Any], requested: PaneReadSource) -> PaneReadResult {
        let payload = (dict["read"] as? [String: Any]) ?? dict
        return PaneReadResult(
            text: payload["text"] as? String ?? "",
            source: payload["source"] as? String ?? requested.rawValue
        )
    }

    public func explain(paneId: String) async throws -> AgentExplainResult {
        try await onIO { [reqClient] in
            let params: [String: Any] = ["target": paneId]
            let result = try reqClient.sendRead(method: "agent.explain", params: params)
            let explain: [String: Any]
            if let nested = result["explain"] as? [String: Any] {
                explain = nested
            } else {
                explain = result
            }
            var matchedRuleId: String?
            var matchedRulePriority: Int?
            if let rule = explain["matched_rule"] as? [String: Any] {
                matchedRuleId = rule["id"] as? String
                matchedRulePriority = JSONNumber.int(rule["priority"])
            }
            return AgentExplainResult(
                agent: explain["agent"] as? String,
                state: explain["state"] as? String,
                matchedRuleId: matchedRuleId,
                matchedRulePriority: matchedRulePriority,
                screenDetectionSkipped: explain["screen_detection_skipped"] as? Bool ?? false
            )
        }
    }

    public func processInfo(paneId: String) async throws -> ProcessInfoResult {
        try await onIO { [reqClient] in
            let params: [String: Any] = ["pane_id": paneId]
            let result = try reqClient.sendRead(method: "pane.process_info", params: params)
            return LiveHerdrAdapter.parseProcessInfo(result)
        }
    }

    internal static func parseProcessInfo(_ dict: [String: Any]) -> ProcessInfoResult {
        let payload = (dict["process_info"] as? [String: Any]) ?? dict
        let shellPid = JSONNumber.int(payload["shell_pid"]).map(Int32.init(truncatingIfNeeded:))
        var procs: [ForegroundProcess] = []
        if let fgList = payload["foreground_processes"] as? [[String: Any]] {
            for p in fgList {
                procs.append(ForegroundProcess(
                    pid: JSONNumber.int(p["pid"]).map(Int32.init(truncatingIfNeeded:)) ?? 0,
                    name: p["name"] as? String ?? "",
                    argv0: p["argv0"] as? String,
                    cmdline: p["cmdline"] as? String,
                    cwd: p["cwd"] as? String
                ))
            }
        }
        return ProcessInfoResult(shellPid: shellPid, foregroundProcesses: procs)
    }

    public func focus(paneId: String) async throws {
        try await onIO { [reqClient] in
            _ = try reqClient.sendWrite(method: "agent.focus", params: Self.focusParams(paneId: paneId))
        }
    }

    internal static func focusParams(paneId: String) -> [String: Any] {
        ["target": paneId]
    }

    public func sendKeys(paneId: String, keys: [String]) async throws {
        try await onIO { [reqClient] in
            let params: [String: Any] = [
                "target": paneId,
                "keys": keys
            ]
            _ = try reqClient.sendWrite(method: "agent.send_keys", params: params)
        }
    }

    public func prompt(paneId: String, text: String) async throws {
        try await onIO { [reqClient] in
            _ = try reqClient.sendWrite(
                method: "pane.send_input",
                params: Self.promptTextParams(paneId: paneId, text: text)
            )
            do {
                _ = try reqClient.sendWrite(
                    method: "agent.send_keys",
                    params: Self.promptEnterParams(paneId: paneId)
                )
            } catch {
                throw NDJSONClientError.invalidResponse(
                    "text was inserted, but Enter failed: \(String(describing: error))"
                )
            }
        }
    }

    internal static func promptTextParams(paneId: String, text: String) -> [String: Any] {
        [
            "pane_id": paneId,
            "text": text
        ]
    }

    internal static func promptEnterParams(paneId: String) -> [String: Any] {
        [
            "target": paneId,
            "keys": ["enter"]
        ]
    }

    public func closePane(paneId: String) async throws {
        try await onIO { [reqClient] in
            _ = try reqClient.sendWrite(method: "pane.close", params: ["pane_id": paneId])
        }
    }

    public func createWorkspace(cwd: String, label: String?) async throws -> WorkspaceCreation {
        try await onIO { [reqClient] in
            var params: [String: Any] = ["cwd": cwd]
            if let label { params["label"] = label }
            let result = try reqClient.sendWrite(method: "workspace.create", params: params)
            guard let workspaceId = result["workspace"] as? [String: Any],
                  let wid = workspaceId["workspace_id"] as? String, !wid.isEmpty else {
                throw NDJSONClientError.invalidResponse("workspace.create missing workspace.workspace_id")
            }
            guard let rootPane = result["root_pane"] as? [String: Any],
                  let pid = rootPane["pane_id"] as? String, !pid.isEmpty else {
                throw NDJSONClientError.invalidResponse("workspace.create missing root_pane.pane_id")
            }
            let tabId = (result["tab"] as? [String: Any])?["tab_id"] as? String
            return WorkspaceCreation(workspaceId: wid, rootPaneId: pid, tabId: tabId)
        }
    }

    public func startAgent(paneId: String, kind: String, name: String) async throws {
        try await startAgent(paneId: paneId, kind: kind, name: name, timeoutMs: nil)
    }

    public func startAgent(paneId: String, kind: String, name: String, timeoutMs: Int?) async throws {
        try await onIO { [reqClient] in
            var params: [String: Any] = [
                "pane_id": paneId,
                "kind": kind,
                "name": name
            ]
            if let timeoutMs { params["timeout_ms"] = timeoutMs }
            _ = try reqClient.sendWrite(method: "agent.start", params: params)
        }
    }

    public func waitForShell(paneId: String, timeoutMs: Int = 10_000) async throws -> Bool {
        let deadline = Date().addingTimeInterval(Double(max(timeoutMs, 0)) / 1000.0)
        while true {
            do {
                let result = try await read(
                    paneId: paneId,
                    source: .detection,
                    lines: HeartbeatPoller.detectionReadLines
                )
                if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            } catch {
            }
            guard Date() < deadline else { return false }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    public func waitStatus(paneId: String, until: [String], timeoutMs: Int) async throws -> Bool {
        try await onIO { [reqClient] in
            let params: [String: Any] = [
                "target": paneId,
                "until": until,
                "timeout_ms": timeoutMs
            ]
            let result = try reqClient.sendWrite(method: "agent.wait", params: params)
            if let settled = result["settled"] as? Bool {
                if settled { return true }
            }
            if let status = result["status"] as? String {
                if until.contains(status) { return true }
            }
            if let agent = result["agent"] as? [String: Any],
               let status = agent["agent_status"] as? String {
                return until.contains(status)
            }
            return false
        }
    }

    public func reportMetadata(paneId: String, source: String, tokens: [String: String], ttlMs: Int) async throws {
        try await onIO { [reqClient] in
            let params: [String: Any] = [
                "pane_id": paneId,
                "source": source,
                "tokens": tokens,
                "ttl_ms": ttlMs
            ]
            _ = try reqClient.sendWrite(method: "pane.report_metadata", params: params)
        }
    }

    public func agentList() async throws -> [HerdrAgentInfo] {
        try await onIO { [reqClient] in
            let result = try reqClient.sendRead(method: "agent.list", params: [:])
            return LiveHerdrAdapter.parseAgentList(result)
        }
    }

    public func herdSnapshot() async throws -> HerdSnapshot {
        let result: HerdSnapshot = try await onIO { [reqClient] in
            let agentsResult = try reqClient.sendRead(method: "agent.list", params: [:])
            let agents = LiveHerdrAdapter.parseAgentList(agentsResult)
            let snapResult = try reqClient.sendRead(method: "session.snapshot", params: [:])
            let snap = try LiveHerdrAdapter.parseSnapshot(snapResult)
            let workspaceNames = snap.workspaceNameMap
            let tabNames = snap.tabNameMap
            return HerdSnapshot(
                version: snap.version,
                protocol: snap.protocol,
                agents: agents,
                workspaceNames: workspaceNames,
                tabNames: tabNames,
                focusedWorkspaceId: snap.focusedWorkspaceId,
                focusedTabId: snap.focusedTabId,
                focusedPaneId: snap.focusedPaneId
            )
        }
        setLatestProtocol(result.protocol)
        return result
    }

    public func createTab(
        workspaceId: String?,
        cwd: String?,
        label: String?,
        focus: Bool
    ) async throws -> (tabId: String, rootPaneId: String) {
        try await onIO { [reqClient] in
            var params: [String: Any] = ["focus": focus]
            if let workspaceId { params["workspace_id"] = workspaceId }
            if let cwd { params["cwd"] = cwd }
            if let label { params["label"] = label }
            let result = try reqClient.sendWrite(method: "tab.create", params: params)
            guard let tab = result["tab"] as? [String: Any],
                  let tabId = tab["tab_id"] as? String, !tabId.isEmpty else {
                throw NDJSONClientError.invalidResponse("tab.create missing tab.tab_id")
            }
            guard let rootPane = result["root_pane"] as? [String: Any],
                  let paneId = rootPane["pane_id"] as? String, !paneId.isEmpty else {
                throw NDJSONClientError.invalidResponse("tab.create missing root_pane.pane_id")
            }
            return (tabId: tabId, rootPaneId: paneId)
        }
    }

    public func splitPane(targetPaneId: String, cwd: String?) async throws -> String {
        try await onIO { [reqClient] in
            let params = LiveHerdrAdapter.splitPaneParams(targetPaneId: targetPaneId, cwd: cwd)
            let result = try reqClient.sendWrite(method: "pane.split", params: params)
            return try LiveHerdrAdapter.parsePaneInfoID(result)
        }
    }

    internal static func splitPaneParams(targetPaneId: String, cwd: String?) -> [String: Any] {
        var params: [String: Any] = [
            "target_pane_id": targetPaneId,
            "direction": "right",
            "focus": true
        ]
        if let cwd { params["cwd"] = cwd }
        return params
    }

    internal static func parsePaneInfoID(_ dict: [String: Any]) throws -> String {
        let payload = (dict["pane"] as? [String: Any]) ?? dict
        guard let paneId = payload["pane_id"] as? String, !paneId.isEmpty else {
            throw NDJSONClientError.invalidResponse("pane.split missing pane.pane_id")
        }
        return paneId
    }

    public func focusWorkspace(_ workspaceId: String) async throws {
        try await onIO { [reqClient] in
            _ = try reqClient.sendWrite(method: "workspace.focus", params: ["workspace_id": workspaceId])
        }
    }

    public func focusTab(_ tabId: String) async throws {
        try await onIO { [reqClient] in
            _ = try reqClient.sendWrite(method: "tab.focus", params: ["tab_id": tabId])
        }
    }

    public func focusPane(_ paneId: String) async throws {
        try await onIO { [reqClient] in
            _ = try reqClient.sendWrite(method: "pane.focus", params: ["pane_id": paneId])
        }
    }

    public func availableAgentKinds() async throws -> [String] {
        try await onIO { [reqClient] in
            let result = try reqClient.sendRead(method: "server.agent_manifests", params: [:])
            guard let manifests = result["manifests"] as? [[String: Any]] else { return [] }
            return manifests.compactMap { $0["agent"] as? String }
        }
    }

    public func events() -> AsyncStream<HerdrEvent> {
        eventLoopTask?.cancel()
        eventLoopTask = Task { [weak self] in
            await self?.runSubscriptionLoop()
        }
        return eventStream
    }

    internal static let globalSubscriptionTypes: [String] = [
        "pane.updated", "pane.created", "pane.closed",
        "pane.exited", "pane.focused", "pane.agent_detected",
        "workspace.created", "workspace.closed", "workspace.renamed", "workspace.focused",
        "tab.created", "tab.closed", "tab.renamed"
    ]

    private func runSubscriptionLoop() async {
        var attempt = 0
        var backoff: UInt64 = 1_000_000_000
        var wasConnected = false
        while !Task.isCancelled {
            do {
                if !subClient.connected {
                    try subClient.connect()
                }
                let stream = try subClient.subscribe(subscriptions: Self.globalSubscriptionTypes)
                setConnectionState(.connected)
                eventContinuation?.yield(.connected)
                wasConnected = true
                attempt = 0
                backoff = 1_000_000_000
                for try await lineData in stream {
                    if let event = Self.event(fromSubscriptionLine: lineData) {
                        eventContinuation?.yield(event)
                    }
                }
            } catch {
            }
            guard !Task.isCancelled else { return }
            if wasConnected {
                setConnectionState(.disconnected)
                eventContinuation?.yield(.disconnected)
                wasConnected = false
            }
            subClient.closeSocket()
            setConnectionState(.reconnecting(attempt: attempt))
            try? await Task.sleep(nanoseconds: backoff)
            attempt += 1
            backoff = min(backoff * 2, 30_000_000_000)
        }
    }

    internal static func parseSnapshot(_ dict: [String: Any]) throws -> HerdrSnapshot {
        let snap: [String: Any]
        if let inner = dict["snapshot"] as? [String: Any] {
            snap = inner
        } else {
            snap = dict
        }
        let version = snap["version"] as? String ?? ""
        let proto = JSONNumber.int(snap["protocol"]) ?? 0
        var workspaces: [HerdrSnapshot.Workspace] = []
        if let wsList = snap["workspaces"] as? [[String: Any]] {
            for ws in wsList {
                let workspaceId = ws["workspace_id"] as? String ?? ""
                guard !workspaceId.isEmpty else { continue }
                workspaces.append(HerdrSnapshot.Workspace(
                    workspaceId: workspaceId,
                    name: ws["label"] as? String ?? workspaceId
                ))
            }
        }
        var tabs: [HerdrSnapshot.Tab] = []
        if let tabList = snap["tabs"] as? [[String: Any]] {
            for t in tabList {
                let tabId = t["tab_id"] as? String ?? ""
                guard !tabId.isEmpty else { continue }
                tabs.append(HerdrSnapshot.Tab(
                    tabId: tabId,
                    workspaceId: t["workspace_id"] as? String ?? "",
                    name: t["label"] as? String ?? tabId
                ))
            }
        }
        var panes: [HerdrSnapshot.PaneInfo] = []
        if let paneList = snap["panes"] as? [[String: Any]] {
            for p in paneList {
                let paneId = p["pane_id"] as? String ?? ""
                guard !paneId.isEmpty else { continue }
                var agentSession: HerdrSnapshot.AgentSession?
                if let asDict = p["agent_session"] as? [String: Any] {
                    agentSession = HerdrSnapshot.AgentSession(
                        source: asDict["source"] as? String ?? "",
                        agent: asDict["agent"] as? String ?? "",
                        kind: asDict["kind"] as? String ?? "",
                        value: asDict["value"] as? String ?? ""
                    )
                }
                panes.append(HerdrSnapshot.PaneInfo(
                    paneId: paneId,
                    workspaceId: p["workspace_id"] as? String ?? "",
                    tabId: p["tab_id"] as? String ?? "",
                    agent: p["agent"] as? String,
                    agentStatus: p["agent_status"] as? String ?? "unknown",
                    agentSession: agentSession,
                    terminalTitleStripped: p["terminal_title_stripped"] as? String,
                    stateChangeSeq: JSONNumber.uint64(p["state_change_seq"]),
                    cwd: p["cwd"] as? String,
                    foregroundCwd: p["foreground_cwd"] as? String,
                    revision: JSONNumber.uint64(p["revision"])
                ))
            }
        }
        return HerdrSnapshot(
            version: version,
            protocol: proto,
            workspaces: workspaces,
            tabs: tabs,
            panes: panes,
            focusedWorkspaceId: snap["focused_workspace_id"] as? String,
            focusedTabId: snap["focused_tab_id"] as? String,
            focusedPaneId: snap["focused_pane_id"] as? String
        )
    }

    internal static func parseEvent(_ dict: [String: Any]) -> HerdrEvent {
        guard let eventKind = (dict["event"] as? String) ?? (dict["type"] as? String) else {
            return .ignored
        }
        let data = (dict["data"] as? [String: Any]) ?? dict
        let kind = eventKind.replacingOccurrences(of: ".", with: "_")
        let pane = (data["pane"] as? [String: Any]) ?? data
        let paneId = pane["pane_id"] as? String ?? data["pane_id"] as? String ?? ""
        switch kind {
        case "pane_agent_status_changed":
            guard !paneId.isEmpty else { return .ignored }
            let status = pane["agent_status"] as? String ?? data["agent_status"] as? String ?? "unknown"
            let seq = JSONNumber.uint64(pane["state_change_seq"]) ?? JSONNumber.uint64(data["state_change_seq"])
            return .agentStatusChanged(paneId: paneId, agentStatus: status, stateChangeSeq: seq)
        case "pane_updated":
            guard !paneId.isEmpty else { return .ignored }
            return .paneUpdated(parseAgentInfo(pane))
        case "pane_created":
            guard !paneId.isEmpty else { return .ignored }
            let wsId = pane["workspace_id"] as? String ?? data["workspace_id"] as? String ?? ""
            let tabId = pane["tab_id"] as? String ?? data["tab_id"] as? String ?? ""
            return .paneCreated(paneId: paneId, workspaceId: wsId, tabId: tabId)
        case "pane_closed":
            guard !paneId.isEmpty else { return .ignored }
            return .paneClosed(paneId: paneId)
        case "pane_focused":
            guard !paneId.isEmpty else { return .ignored }
            let wsId = pane["workspace_id"] as? String ?? data["workspace_id"] as? String
            return .paneFocused(paneId: paneId, workspaceId: wsId)
        case "pane_exited":
            guard !paneId.isEmpty else { return .ignored }
            return .paneExited(paneId: paneId)
        case "pane_moved":
            guard !paneId.isEmpty else { return .ignored }
            let wsId = pane["workspace_id"] as? String ?? data["workspace_id"] as? String
            let tabId = pane["tab_id"] as? String ?? data["tab_id"] as? String
            return .paneMoved(paneId: paneId, workspaceId: wsId, tabId: tabId)
        case "workspace_created", "workspace_updated", "workspace_metadata_updated",
             "workspace_closed", "workspace_renamed", "workspace_moved", "workspace_focused",
             "worktree_created", "worktree_opened", "worktree_removed",
             "tab_created", "tab_closed", "tab_renamed", "tab_moved", "tab_focused",
             "layout_updated":
            return .workspacesChanged
        default:
            return .ignored
        }
    }

    internal static func parseAgentInfo(_ dict: [String: Any]) -> HerdrAgentInfo {
        var agentSession: HerdrSnapshot.AgentSession?
        if let asDict = dict["agent_session"] as? [String: Any] {
            agentSession = HerdrSnapshot.AgentSession(
                source: asDict["source"] as? String ?? "",
                agent: asDict["agent"] as? String ?? "",
                kind: asDict["kind"] as? String ?? "",
                value: asDict["value"] as? String ?? ""
            )
        }
        return HerdrAgentInfo(
            paneId: dict["pane_id"] as? String ?? "",
            workspaceId: dict["workspace_id"] as? String ?? "",
            tabId: dict["tab_id"] as? String ?? "",
            agent: dict["agent"] as? String,
            displayAgent: dict["display_agent"] as? String,
            name: dict["name"] as? String,
            title: dict["title"] as? String,
            terminalTitleStripped: dict["terminal_title_stripped"] as? String,
            agentStatus: dict["agent_status"] as? String ?? "unknown",
            agentSession: agentSession,
            focused: dict["focused"] as? Bool ?? false,
            stateChangeSeq: JSONNumber.uint64(dict["state_change_seq"]) ?? 0,
            cwd: dict["cwd"] as? String,
            foregroundCwd: dict["foreground_cwd"] as? String,
            revision: JSONNumber.uint64(dict["revision"]),
            tokens: dict["tokens"] as? [String: String] ?? [:],
            stateLabels: dict["state_labels"] as? [String: String] ?? [:],
            interactiveReady: dict["interactive_ready"] as? Bool ?? false,
            launchPending: dict["launch_pending"] as? Bool ?? false
        )
    }

    internal static func parseAgentList(_ dict: [String: Any]) -> [HerdrAgentInfo] {
        let list = dict["agents"] as? [[String: Any]] ?? []
        return list.compactMap { entry -> HerdrAgentInfo? in
            let info = parseAgentInfo(entry)
            guard !info.paneId.isEmpty else { return nil }
            guard let agent = info.agent, !agent.isEmpty else { return nil }
            return info
        }
    }

    public static let minSupportedProtocolVersion = 17
    public static let supportedProtocolRange: ClosedRange<Int> =
        minSupportedProtocolVersion...Int.max

    public func health() -> AdapterHealth {
        Self.health(forProtocol: latestProtocol())
    }

    public static func health(forProtocol proto: Int) -> AdapterHealth {
        let minSupportedVersion = minSupportedProtocolVersion
        if proto <= 0 {
            return AdapterHealth(
                protocolVersion: proto,
                compatible: false,
                writesEnabled: false,
                reason: "protocol unknown"
            )
        }
        if proto == minSupportedVersion {
            return AdapterHealth(
                protocolVersion: proto,
                compatible: true,
                writesEnabled: true,
                reason: nil
            )
        }
        if proto > minSupportedVersion {
            return AdapterHealth(
                protocolVersion: proto,
                compatible: true,
                writesEnabled: true,
                reason: "herdr protocol \(proto) is newer than the verified \(minSupportedVersion); treating as compatible-with-writes"
            )
        }
        return AdapterHealth(
            protocolVersion: proto,
            compatible: false,
            writesEnabled: false,
            reason: "herdr protocol \(proto) is older than the minimum verified \(minSupportedVersion); writes disabled"
        )
    }

    internal static func event(fromSubscriptionLine lineData: Data) -> HerdrEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: lineData),
              let dict = object as? [String: Any] else {
            return nil
        }
        return parseEvent(dict)
    }

    public static func missingSocketMessage(resolvedPath: String) -> String {
        """
        Error: herdr socket not found at \(resolvedPath)
        Is herdr running? Install it from https://herdr.dev
        \(socketHint(resolvedPath: resolvedPath))
        """
    }

    public static func protocolStatusLine(for health: AdapterHealth) -> String? {
        guard let reason = health.reason else { return nil }
        return "herdr protocol \(health.protocolVersion): \(reason)"
    }

    public static func socketHint(resolvedPath: String) -> String {
        """
        Socket: \(resolvedPath)
        Set HERDR_SOCKET_PATH or HERDR_SESSION, or pass --socket if this is the wrong socket.
        """
    }

    public static func resolveSocketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["HERDR_SOCKET_PATH"], !explicit.isEmpty {
            return explicit
        }
        if let session = env["HERDR_SESSION"], !session.isEmpty,
           let resolved = resolveSessionSocket(name: session, env: env) {
            return resolved
        }
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("herdr/herdr.sock")
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".config/herdr/herdr.sock")
    }

    private static func resolveSessionSocket(name: String, env: [String: String]) -> String? {
        if let fromRegistry = sessionSocketFromHerdrCLI(name: name) {
            return fromRegistry
        }
        let base: String
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = xdg
        } else {
            base = (env["HOME"] ?? NSHomeDirectory()) + "/.config"
        }
        let candidate = (base as NSString)
            .appendingPathComponent("herdr/sessions/\(name)/herdr.sock")
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    private static func sessionSocketFromHerdrCLI(name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["herdr", "session", "list"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if cols.first == name, let socket = cols.last, socket.hasSuffix(".sock") {
                return socket
            }
        }
        return nil
    }
}

public struct AdapterHealth: Sendable, Equatable {
    public let protocolVersion: Int
    public let compatible: Bool
    public let writesEnabled: Bool
    public let reason: String?
    public init(protocolVersion: Int, compatible: Bool, writesEnabled: Bool, reason: String?) {
        self.protocolVersion = protocolVersion
        self.compatible = compatible
        self.writesEnabled = writesEnabled
        self.reason = reason
    }
}

public enum JSONNumber {
    public static func int(_ value: Any?) -> Int? {
        guard let value, !isJSONBoolean(value) else { return nil }
        if let number = value as? NSNumber {
            return intFromNSNumber(number)
        }
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? UInt64, value <= UInt64(Int.max) { return Int(value) }
        if let value = value as? Double {
            return intFromWholeDouble(value)
        }
        if let value = value as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    public static func uint64(_ value: Any?) -> UInt64? {
        guard let value, !isJSONBoolean(value) else { return nil }
        if let number = value as? NSNumber {
            return uint64FromNSNumber(number)
        }
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        if let value = value as? Int64, value >= 0 { return UInt64(value) }
        if let value = value as? Double, value >= 0,
           let asInt = intFromWholeDouble(value) {
            return UInt64(asInt)
        }
        if let value = value as? String {
            return UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    public static func matchesStringId(_ value: Any?, expected: String) -> Bool {
        if let string = value as? String {
            return string == expected
        }
        if let int = int(value) {
            return String(int) == expected
        }
        return false
    }

    private static func isJSONBoolean(_ value: Any) -> Bool {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        return value is Bool
    }

    private static func intFromWholeDouble(_ value: Double) -> Int? {
        guard value.isFinite,
              value >= Double(Int.min),
              value <= Double(Int.max),
              value.rounded(.towardZero) == value else {
            return nil
        }
        return Int(value)
    }

    private static func intFromNSNumber(_ number: NSNumber) -> Int? {
        let type = String(cString: number.objCType)
        if type == "d" || type == "f" {
            return intFromWholeDouble(number.doubleValue)
        }
        let i = number.int64Value
        guard i >= Int64(Int.min), i <= Int64(Int.max) else { return nil }
        return Int(i)
    }

    private static func uint64FromNSNumber(_ number: NSNumber) -> UInt64? {
        let type = String(cString: number.objCType)
        if type == "d" || type == "f" {
            guard let asInt = intFromWholeDouble(number.doubleValue), asInt >= 0 else {
                return nil
            }
            return UInt64(asInt)
        }
        guard number.int64Value >= 0 else { return nil }
        return number.uint64Value
    }
}
