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
    func createWorkspace(cwd: String, label: String?) async throws -> String
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
    private let stateLock = NSLock()
    private var _connectionState: HerdrConnectionState = .disconnected
    private var eventContinuation: AsyncStream<HerdrEvent>.Continuation?
    private let eventStream: AsyncStream<HerdrEvent>
    private var eventLoopTask: Task<Void, Never>?

    public init(socketPath: String) {
        self.reqClient = NDJSONClient(socketPath: socketPath)
        self.subClient = NDJSONClient(socketPath: socketPath)
        var continuation: AsyncStream<HerdrEvent>.Continuation?
        self.eventStream = AsyncStream { cont in
            continuation = cont
        }
        self.eventContinuation = continuation
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

    public func connect() async throws {
        setConnectionState(.connecting)
        try reqClient.connect()
        setConnectionState(.connected)
    }

    public func snapshot() async throws -> HerdrSnapshot {
        let result = try reqClient.send(method: "session.snapshot", params: [:])
        return try Self.parseSnapshot(result)
    }

    public func read(paneId: String, source: PaneReadSource) async throws -> PaneReadResult {
        let params: [String: Any] = [
            "pane_id": paneId,
            "source": source.rawValue
        ]
        let result = try reqClient.send(method: "pane.read", params: params)
        let text = result["text"] as? String ?? ""
        let src = result["source"] as? String ?? source.rawValue
        return PaneReadResult(text: text, source: src)
    }

    public func explain(paneId: String) async throws -> AgentExplainResult {
        let params: [String: Any] = ["target": paneId]
        let result = try reqClient.send(method: "agent.explain", params: params)

        // The herdr response nests data under result["explain"]:
        // {"type": "agent_explain", "explain": {"agent": ..., "state": ..., "matched_rule": {"id": ..., "priority": ...}, "screen_detection_skipped": ...}}
        let explain: [String: Any]
        if let nested = result["explain"] as? [String: Any] {
            explain = nested
        } else {
            // Fallback: fields at top level (shouldn't happen with current herdr, but be defensive)
            explain = result
        }

        // matched_rule is a nested dict: {"id": "...", "priority": 100, "region": "...", "state": "..."}
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

    public func processInfo(paneId: String) async throws -> ProcessInfoResult {
        let params: [String: Any] = ["pane_id": paneId]
        let result = try reqClient.send(method: "pane.process_info", params: params)
        let shellPid = result["shell_pid"] as? Int32
        var procs: [ForegroundProcess] = []
        if let fgList = result["foreground_processes"] as? [[String: Any]] {
            for p in fgList {
                procs.append(ForegroundProcess(
                    pid: p["pid"] as? Int32 ?? 0,
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
        let params: [String: Any] = ["pane_id": paneId]
        _ = try reqClient.send(method: "agent.focus", params: params)
    }

    // MARK: - Write Methods

    public func sendKeys(paneId: String, keys: [String]) async throws {
        let params: [String: Any] = [
            "target": paneId,
            "keys": keys
        ]
        _ = try reqClient.send(method: "agent.send_keys", params: params)
    }

    public func prompt(paneId: String, text: String) async throws {
        let params: [String: Any] = [
            "target": paneId,
            "text": text
        ]
        _ = try reqClient.send(method: "agent.prompt", params: params)
    }

    public func closePane(paneId: String) async throws {
        let params: [String: Any] = ["pane_id": paneId]
        _ = try reqClient.send(method: "pane.close", params: params)
    }

    public func createWorkspace(cwd: String, label: String?) async throws -> String {
        var params: [String: Any] = ["cwd": cwd]
        if let label { params["label"] = label }
        let result = try reqClient.send(method: "workspace.create", params: params)
        return result["workspace_id"] as? String ?? ""
    }

    public func startAgent(paneId: String, kind: String, name: String) async throws {
        let params: [String: Any] = [
            "pane_id": paneId,
            "kind": kind,
            "name": name
        ]
        _ = try reqClient.send(method: "agent.start", params: params)
    }

    public func waitStatus(paneId: String, until: [String], timeoutMs: Int) async throws -> Bool {
        let params: [String: Any] = [
            "target": paneId,
            "until": until,
            "timeout_ms": timeoutMs
        ]
        let result = try reqClient.send(method: "agent.wait", params: params)
        // herdr returns the final status; if we got a response, it settled
        return result["status"] != nil || result["settled"] != nil
    }

    public func reportMetadata(paneId: String, source: String, tokens: [String: String], ttlMs: Int) async throws {
        let params: [String: Any] = [
            "pane_id": paneId,
            "source": source,
            "tokens": tokens,
            "ttl_ms": ttlMs
        ]
        _ = try reqClient.send(method: "pane.report_metadata", params: params)
    }

    public func events() -> AsyncStream<HerdrEvent> {
        // Start the self-healing subscription loop in the background.
        eventLoopTask?.cancel()
        eventLoopTask = Task { [weak self] in
            await self?.runSubscriptionLoop()
        }
        return eventStream
    }

    /// Subscribe on the dedicated `subClient`, forever. On any error or clean
    /// close, mark disconnected, back off, and re-subscribe — so a transient
    /// socket hiccup no longer kills live updates permanently.
    private func runSubscriptionLoop() async {
        var attempt = 0
        var backoff: UInt64 = 1_000_000_000 // 1s
        while !Task.isCancelled {
            do {
                if !subClient.connected {
                    try subClient.connect()
                }
                let stream = subClient.subscribe(subscriptions: [
                    "pane.agent_status_changed",
                    "pane.created",
                    "pane.closed",
                    "pane.moved"
                ])
                // Subscription (re)established — we are live again.
                setConnectionState(.connected)
                eventContinuation?.yield(.connected)
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
            setConnectionState(.disconnected)
            eventContinuation?.yield(.disconnected)
            subClient.closeSocket()

            setConnectionState(.reconnecting(attempt: attempt))
            try? await Task.sleep(nanoseconds: backoff)
            attempt += 1
            backoff = min(backoff * 2, 30_000_000_000) // cap at 30s
        }
    }

    // MARK: - Parsing

    private static func parseSnapshot(_ dict: [String: Any]) throws -> HerdrSnapshot {
        // The result has {type: "session_snapshot", snapshot: {...}}
        let snap: [String: Any]
        if let inner = dict["snapshot"] as? [String: Any] {
            snap = inner
        } else {
            snap = dict
        }

        let version = snap["version"] as? String ?? ""
        let proto = snap["protocol"] as? String ?? ""

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

    private static func parseEvent(_ dict: [String: Any]) -> HerdrEvent {
        let type = dict["type"] as? String ?? ""
        let paneId = dict["pane_id"] as? String ?? ""

        switch type {
        case "pane_agent_status_changed":
            let status = dict["agent_status"] as? String ?? "unknown"
            let seq = dict["state_change_seq"] as? UInt64
            return .agentStatusChanged(paneId: paneId, agentStatus: status, stateChangeSeq: seq)
        case "pane_created":
            let wsId = dict["workspace_id"] as? String ?? ""
            let tabId = dict["tab_id"] as? String ?? ""
            return .paneCreated(paneId: paneId, workspaceId: wsId, tabId: tabId)
        case "pane_closed":
            return .paneClosed(paneId: paneId)
        case "pane_moved":
            let wsId = dict["workspace_id"] as? String
            let tabId = dict["tab_id"] as? String
            return .paneMoved(paneId: paneId, workspaceId: wsId, tabId: tabId)
        default:
            return .disconnected
        }
    }
}
