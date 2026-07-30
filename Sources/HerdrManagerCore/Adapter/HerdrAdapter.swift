import Foundation

// MARK: - HerdrAdapter Protocol

public protocol HerdrAdapter: Sendable {
    func snapshot() async throws -> HerdrSnapshot
    func read(paneId: String, source: PaneReadSource) async throws -> PaneReadResult
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
        // Request client: bounded I/O timeout so a stalled herdr errors out
        // (.timeout) instead of blocking forever.
        self.reqClient = NDJSONClient(socketPath: socketPath, ioTimeoutSeconds: 30)
        // Subscription client: no timeout — the event stream is push-based and
        // legitimately blocks between events.
        self.subClient = NDJSONClient(socketPath: socketPath, ioTimeoutSeconds: 0)
        var continuation: AsyncStream<HerdrEvent>.Continuation?
        self.eventStream = AsyncStream { cont in
            continuation = cont
        }
        self.eventContinuation = continuation
    }

    /// Run blocking socket I/O on the dedicated `ioQueue`, off the cooperative
    /// pool and off the main actor. The body must do its own parsing and return
    /// a `Sendable` result so no non-Sendable value (e.g. `[String: Any]`)
    /// crosses the thread boundary. Combined with the socket-level timeouts, a
    /// hung herdr surfaces as `.timeout` rather than blocking indefinitely.
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

    /// Bounded pane read for compact UI previews. The protocol requirement
    /// keeps the unbounded form above for diagnosis/MCP callers, while
    /// Shepherd's Peek can ask herdr to do the truncation at the source.
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

    /// `pane.read` -> `{"type":"pane_read","read":{...PaneReadResult...}}`.
    /// The fields live one level down; reading `text` off the envelope returned
    /// an empty string on every call, which is what made Peek render a blank
    /// box. The flat shape is still accepted so older fixtures keep parsing.
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
                matchedRulePriority = rule["priority"] as? Int
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

    /// `pane.process_info` -> `{"type":"pane_process_info","process_info":{...}}`
    /// — the same envelope trap as `pane.read`. Reading the fields off the
    /// envelope produced a nil `shell_pid` and an empty process list, which
    /// silently disabled the process-gone diagnosis.
    internal static func parseProcessInfo(_ dict: [String: Any]) -> ProcessInfoResult {
        let payload = (dict["process_info"] as? [String: Any]) ?? dict
        // Via `Int`: an NSNumber off the wire bridges to either, but a native
        // Swift `Int` (as in a hand-written fixture) only casts to `Int`.
        let shellPid = (payload["shell_pid"] as? Int).map(Int32.init(truncatingIfNeeded:))
        var procs: [ForegroundProcess] = []
        if let fgList = payload["foreground_processes"] as? [[String: Any]] {
            for p in fgList {
                procs.append(ForegroundProcess(
                    pid: (p["pid"] as? Int).map(Int32.init(truncatingIfNeeded:)) ?? 0,
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

    /// Extracted so the param shape (`{"target": …}`, per schema `AgentTarget`)
    /// is independently testable without a socket.
    internal static func focusParams(paneId: String) -> [String: Any] {
        ["target": paneId]
    }

    // MARK: - Write Methods

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
            // Keep Nudge as one user action, but send text and Enter as two
            // ordered herdr writes. `agent.prompt` is documented as an atomic
            // submission, yet some live agent TUIs only accepted its paste
            // portion. Separate channel messages preserve bracketed-paste
            // handling while making the Enter key unambiguous.
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
        try await onIO { [reqClient] in
            let params: [String: Any] = [
                "pane_id": paneId,
                "kind": kind,
                "name": name
            ]
            _ = try reqClient.sendWrite(method: "agent.start", params: params)
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
            return result["status"] != nil || result["settled"] != nil
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

    // MARK: - Agent-centric methods (Bug 4: agent.list is the source of truth)

    /// `agent.list` — the authoritative list of real agents (never plain
    /// shells) with a genuine `state_change_seq`, which `session.snapshot`
    /// panes do not carry.
    public func agentList() async throws -> [HerdrAgentInfo] {
        try await onIO { [reqClient] in
            let result = try reqClient.sendRead(method: "agent.list", params: [:])
            return LiveHerdrAdapter.parseAgentList(result)
        }
    }

    /// `agent.list` merged with `session.snapshot`'s workspace/tab labels and
    /// focus pointers — the one-stop call sites should use going forward.
    public func herdSnapshot() async throws -> HerdSnapshot {
        let result: HerdSnapshot = try await onIO { [reqClient] in
            let agentsResult = try reqClient.sendRead(method: "agent.list", params: [:])
            let agents = LiveHerdrAdapter.parseAgentList(agentsResult)

            let snapResult = try reqClient.sendRead(method: "session.snapshot", params: [:])
            let snap = try LiveHerdrAdapter.parseSnapshot(snapResult)

            let workspaceNames = Dictionary(uniqueKeysWithValues: snap.workspaces.map { ($0.workspaceId, $0.name) })
            let tabNames = Dictionary(uniqueKeysWithValues: snap.tabs.map { ($0.tabId, $0.name) })

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

    /// `tab.create` -> `{"type":"tab_created","tab":{...},"root_pane":{...}}`.
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

    /// Split beside an existing pane in the same tab and return the new shell
    /// pane. `agent.start` can then launch into that interactive shell.
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

    /// `workspace.focus` -> `{workspace_id}` (schema `WorkspaceTarget`).
    public func focusWorkspace(_ workspaceId: String) async throws {
        try await onIO { [reqClient] in
            _ = try reqClient.sendWrite(method: "workspace.focus", params: ["workspace_id": workspaceId])
        }
    }

    /// `tab.focus` -> `{tab_id}` (schema `TabTarget`).
    public func focusTab(_ tabId: String) async throws {
        try await onIO { [reqClient] in
            _ = try reqClient.sendWrite(method: "tab.focus", params: ["tab_id": tabId])
        }
    }

    /// `pane.focus` -> `{pane_id}` (schema `PaneTarget`). Distinct from
    /// `agent.focus`, which takes `{target}` and additionally routes agent
    /// attention; this is a plain pane focus.
    public func focusPane(_ paneId: String) async throws {
        try await onIO { [reqClient] in
            _ = try reqClient.sendWrite(method: "pane.focus", params: ["pane_id": paneId])
        }
    }

    /// `server.agent_manifests` -> `{"type":"agent_manifest_status","manifests":[{"agent":...},...]}`.
    public func availableAgentKinds() async throws -> [String] {
        try await onIO { [reqClient] in
            let result = try reqClient.sendRead(method: "server.agent_manifests", params: [:])
            guard let manifests = result["manifests"] as? [[String: Any]] else { return [] }
            return manifests.compactMap { $0["agent"] as? String }
        }
    }

    public func events() -> AsyncStream<HerdrEvent> {
        // Start the self-healing subscription loop in the background.
        eventLoopTask?.cancel()
        eventLoopTask = Task { [weak self] in
            await self?.runSubscriptionLoop()
        }
        return eventStream
    }

    /// Global (no-argument) subscription types. `pane.updated` carries the
    /// entire pane object including `agent_status`, which is what the old
    /// (and never-working — it required a `pane_id` we never sent)
    /// `pane.agent_status_changed` per-pane subscription was for. Deliberately
    /// excludes `pane.agent_status_changed`, `pane.scroll_changed`, and
    /// `pane.output_matched`, which the schema requires a `pane_id` for.
    internal static let globalSubscriptionTypes: [String] = [
        "pane.updated", "pane.created", "pane.closed",
        "pane.exited", "pane.focused", "pane.agent_detected",
        "workspace.created", "workspace.closed", "workspace.renamed", "workspace.focused",
        "tab.created", "tab.closed", "tab.renamed"
    ]

    /// Subscribe on the dedicated `subClient`, forever. On any error or clean
    /// close, back off and re-subscribe — so a transient socket hiccup no
    /// longer kills live updates permanently. `.disconnected` is only ever
    /// yielded on a genuine transition away from a previously-connected state
    /// (tracked via `wasConnected`) — a retry loop that never got connected in
    /// the first place must not flap `.connected`/`.disconnected` on every
    /// backoff cycle.
    private func runSubscriptionLoop() async {
        var attempt = 0
        var backoff: UInt64 = 1_000_000_000 // 1s
        var wasConnected = false
        while !Task.isCancelled {
            do {
                if !subClient.connected {
                    try subClient.connect()
                }
                // `subscribe` blocks until herdr confirms `subscription_started`
                // (or throws) before returning the stream — so reaching this
                // line means the subscription is genuinely live, not merely
                // that a stream object was constructed.
                let stream = try subClient.subscribe(subscriptions: Self.globalSubscriptionTypes)
                setConnectionState(.connected)
                eventContinuation?.yield(.connected)
                wasConnected = true
                attempt = 0
                backoff = 1_000_000_000

                for try await lineData in stream {
                    if let dict = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                        let event = Self.parseEvent(dict)
                        eventContinuation?.yield(event)
                    }
                }
                // Stream ended without throwing: server closed the subscription.
            } catch {
                // fall through to backoff/reconnect below
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
            backoff = min(backoff * 2, 30_000_000_000) // cap at 30s
        }
    }

    // MARK: - Parsing

    internal static func parseSnapshot(_ dict: [String: Any]) throws -> HerdrSnapshot {
        // The result has {type: "session_snapshot", snapshot: {...}}
        let snap: [String: Any]
        if let inner = dict["snapshot"] as? [String: Any] {
            snap = inner
        } else {
            snap = dict
        }

        let version = snap["version"] as? String ?? ""
        let proto = snap["protocol"] as? Int ?? 0

        var workspaces: [HerdrSnapshot.Workspace] = []
        if let wsList = snap["workspaces"] as? [[String: Any]] {
            for ws in wsList {
                workspaces.append(HerdrSnapshot.Workspace(
                    workspaceId: ws["workspace_id"] as? String ?? "",
                    name: ws["label"] as? String ?? ws["workspace_id"] as? String ?? ""
                ))
            }
        }

        var tabs: [HerdrSnapshot.Tab] = []
        if let tabList = snap["tabs"] as? [[String: Any]] {
            for t in tabList {
                tabs.append(HerdrSnapshot.Tab(
                    tabId: t["tab_id"] as? String ?? "",
                    workspaceId: t["workspace_id"] as? String ?? "",
                    name: t["label"] as? String ?? t["tab_id"] as? String ?? ""
                ))
            }
        }

        var panes: [HerdrSnapshot.PaneInfo] = []
        if let paneList = snap["panes"] as? [[String: Any]] {
            for p in paneList {
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
                    paneId: p["pane_id"] as? String ?? "",
                    workspaceId: p["workspace_id"] as? String ?? "",
                    tabId: p["tab_id"] as? String ?? "",
                    agent: p["agent"] as? String,
                    agentStatus: p["agent_status"] as? String ?? "unknown",
                    agentSession: agentSession,
                    terminalTitleStripped: p["terminal_title_stripped"] as? String,
                    stateChangeSeq: p["state_change_seq"] as? UInt64,
                    cwd: p["cwd"] as? String,
                    foregroundCwd: p["foreground_cwd"] as? String,
                    revision: p["revision"] as? UInt64
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
        // Real herdr subscription envelope, protocol 17:
        //   {"event":"pane_updated","data":{"type":"pane_updated","pane":{...}}}
        // Event names are UNDERSCORED on the wire (pane_updated, pane_closed,
        // pane_focused, workspace_focused, ...). We also accept the dotted
        // forms harmlessly, so older test fixtures and any future herdr
        // rename back to dotted names keep working.
        guard let eventKind = dict["event"] as? String,
              let data = dict["data"] as? [String: Any] else {
            return .ignored
        }
        let paneId = data["pane_id"] as? String ?? ""

        switch eventKind {
        // MARK: Legacy/dotted forms (kept for back-compat; not the real wire format)
        case "pane.agent_status_changed":
            let status = data["agent_status"] as? String ?? "unknown"
            let seq = data["state_change_seq"] as? UInt64
            return .agentStatusChanged(paneId: paneId, agentStatus: status, stateChangeSeq: seq)
        case "pane.created":
            let wsId = data["workspace_id"] as? String ?? ""
            let tabId = data["tab_id"] as? String ?? ""
            return .paneCreated(paneId: paneId, workspaceId: wsId, tabId: tabId)
        case "pane.closed":
            return .paneClosed(paneId: paneId)
        case "pane.moved":
            let wsId = data["workspace_id"] as? String
            let tabId = data["tab_id"] as? String
            return .paneMoved(paneId: paneId, workspaceId: wsId, tabId: tabId)

        // MARK: Real herdr wire format (underscored)
        case "pane_agent_status_changed":
            let status = data["agent_status"] as? String ?? "unknown"
            let seq = data["state_change_seq"] as? UInt64
            return .agentStatusChanged(paneId: paneId, agentStatus: status, stateChangeSeq: seq)
        case "pane_updated":
            // {"type":"pane_updated","pane":{ ...full pane... }}
            guard let pane = data["pane"] as? [String: Any] else { return .ignored }
            return .paneUpdated(parseAgentInfo(pane))
        case "pane_created":
            // {"type":"pane_created","pane":{ ...full pane... }}
            guard let pane = data["pane"] as? [String: Any] else { return .ignored }
            let pId = pane["pane_id"] as? String ?? ""
            let wsId = pane["workspace_id"] as? String ?? ""
            let tabId = pane["tab_id"] as? String ?? ""
            return .paneCreated(paneId: pId, workspaceId: wsId, tabId: tabId)
        case "pane_closed":
            // {"type":"pane_closed","pane_id":...,"workspace_id":...} — the
            // .paneClosed case only carries paneId; workspace_id isn't needed
            // to remove the agent from the store.
            return .paneClosed(paneId: paneId)
        case "pane_focused":
            let wsId = data["workspace_id"] as? String
            return .paneFocused(paneId: paneId, workspaceId: wsId)
        case "pane_exited":
            return .paneExited(paneId: paneId)
        case "pane_moved":
            // {"type":"pane_moved","pane":{...}, "previous_pane_id":..., ...}
            guard let pane = data["pane"] as? [String: Any] else { return .ignored }
            let pId = pane["pane_id"] as? String ?? ""
            let wsId = pane["workspace_id"] as? String
            let tabId = pane["tab_id"] as? String
            return .paneMoved(paneId: pId, workspaceId: wsId, tabId: tabId)
        case "workspace_created", "workspace_updated", "workspace_metadata_updated",
             "workspace_closed", "workspace_renamed", "workspace_moved", "workspace_focused",
             "worktree_created", "worktree_opened", "worktree_removed",
             "tab_created", "tab_closed", "tab_renamed", "tab_moved", "tab_focused",
             "layout_updated":
            return .workspacesChanged
        default:
            // Includes pane_agent_detected/pane_output_changed (not modeled
            // yet — harmless to drop) and any genuinely unknown event.
            return .ignored
        }
    }

    /// Shared parser for both `agent.list`'s `AgentInfo` entries and the
    /// `pane_updated` event's nested `PaneInfo` — the two shapes overlap on
    /// every field this type needs; fields present only on one side (e.g.
    /// `state_change_seq`, `name`, `interactive_ready` are `agent.list`-only)
    /// simply default when absent.
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
            stateChangeSeq: dict["state_change_seq"] as? UInt64 ?? 0,
            cwd: dict["cwd"] as? String,
            foregroundCwd: dict["foreground_cwd"] as? String,
            revision: dict["revision"] as? UInt64,
            tokens: dict["tokens"] as? [String: String] ?? [:],
            stateLabels: dict["state_labels"] as? [String: String] ?? [:],
            interactiveReady: dict["interactive_ready"] as? Bool ?? false,
            launchPending: dict["launch_pending"] as? Bool ?? false
        )
    }

    /// Parses `agent.list`'s `{"agents":[AgentInfo, ...]}` result, dropping
    /// any entry with no `agent` (a plain shell pane is not an agent).
    internal static func parseAgentList(_ dict: [String: Any]) -> [HerdrAgentInfo] {
        let list = dict["agents"] as? [[String: Any]] ?? []
        return list.compactMap { entry -> HerdrAgentInfo? in
            let info = parseAgentInfo(entry)
            guard let agent = info.agent, !agent.isEmpty else { return nil }
            return info
        }
    }

    // MARK: - Health

    public func health() -> AdapterHealth {
        let proto = latestProtocol()
        // Protocol 17 is the version this adapter was built and verified
        // against. Anything newer is presumed additive/compatible (herdr's
        // protocol has been append-only in practice) so a routine herdr bump
        // doesn't silently disable every write in the app; anything older is
        // unverified and left disabled.
        let minSupportedVersion = 17
        if proto == 0 {
            return AdapterHealth(protocolVersion: 0, compatible: false, writesEnabled: false, reason: "protocol unknown")
        }
        if proto == minSupportedVersion {
            return AdapterHealth(protocolVersion: proto, compatible: true, writesEnabled: true, reason: nil)
        }
        if proto > minSupportedVersion {
            return AdapterHealth(
                protocolVersion: proto,
                compatible: true,
                writesEnabled: true,
                reason: "herdr protocol \(proto) is newer than the verified \(minSupportedVersion); treating as compatible-with-writes"
            )
        }
        return AdapterHealth(protocolVersion: proto, compatible: false, writesEnabled: false, reason: "herdr protocol \(proto) is older than the minimum verified \(minSupportedVersion); writes disabled")
    }

    // MARK: - Socket Resolution

    /// Resolve herdr socket path in priority order:
    /// 1. HERDR_SOCKET_PATH (explicit override)
    /// 2. HERDR_SESSION (session-based lookup)
    /// 3. XDG_CONFIG_HOME/herdr/herdr.sock
    /// 4. ~/.config/herdr/herdr.sock (default)
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

    /// Resolve the socket path for a named herdr session (`HERDR_SESSION`).
    /// Prefers herdr's own registry (`herdr session list`) so we never guess
    /// the on-disk layout; falls back to the conventional
    /// `<config>/herdr/sessions/<name>/herdr.sock`. Returns nil if the named
    /// session cannot be resolved (caller falls through to the default socket).
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

    /// Ask the herdr CLI for a session's authoritative socket path by parsing
    /// `herdr session list` (columns: name, status, directory, socket).
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

// MARK: - AdapterHealth

/// Bounded capability/health surface for the herdr adapter.
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
