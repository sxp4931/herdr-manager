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
    private let stateLock = NSLock()
    private var _connectionState: HerdrConnectionState = .disconnected
    private var _latestProtocolVersion: Int = 0
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
        try reqClient.connect()
        setConnectionState(.connected)
    }

    public func snapshot() async throws -> HerdrSnapshot {
        let result = try reqClient.sendRead(method: "session.snapshot", params: [:])
        let snap = try Self.parseSnapshot(result)
        setLatestProtocol(snap.protocol)
        return snap
    }

    public func read(paneId: String, source: PaneReadSource) async throws -> PaneReadResult {
        let params: [String: Any] = [
            "pane_id": paneId,
            "source": source.rawValue
        ]
        let result = try reqClient.sendRead(method: "pane.read", params: params)
        let text = result["text"] as? String ?? ""
        let src = result["source"] as? String ?? source.rawValue
        return PaneReadResult(text: text, source: src)
    }

    public func explain(paneId: String) async throws -> AgentExplainResult {
        let params: [String: Any] = ["target": paneId]
        let result = try reqClient.sendRead(method: "agent.explain", params: params)

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
        let result = try reqClient.sendRead(method: "pane.process_info", params: params)
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
        _ = try reqClient.sendWrite(method: "agent.focus", params: params)
    }

    // MARK: - Write Methods

    public func sendKeys(paneId: String, keys: [String]) async throws {
        let params: [String: Any] = [
            "target": paneId,
            "keys": keys
        ]
        _ = try reqClient.sendWrite(method: "agent.send_keys", params: params)
    }

    public func prompt(paneId: String, text: String) async throws {
        let params: [String: Any] = [
            "target": paneId,
            "text": text
        ]
        _ = try reqClient.sendWrite(method: "agent.prompt", params: params)
    }

    public func closePane(paneId: String) async throws {
        let params: [String: Any] = ["pane_id": paneId]
        _ = try reqClient.sendWrite(method: "pane.close", params: params)
    }

    public func createWorkspace(cwd: String, label: String?) async throws -> WorkspaceCreation {
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

    public func startAgent(paneId: String, kind: String, name: String) async throws {
        let params: [String: Any] = [
            "pane_id": paneId,
            "kind": kind,
            "name": name
        ]
        _ = try reqClient.sendWrite(method: "agent.start", params: params)
    }

    public func waitStatus(paneId: String, until: [String], timeoutMs: Int) async throws -> Bool {
        let params: [String: Any] = [
            "target": paneId,
            "until": until,
            "timeout_ms": timeoutMs
        ]
        let result = try reqClient.sendWrite(method: "agent.wait", params: params)
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
        _ = try reqClient.sendWrite(method: "pane.report_metadata", params: params)
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
                    "pane.agent_status_changed"
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
        // Real herdr subscription envelope: {event:"pane.agent_status_changed", data:{pane_id, workspace_id, agent_status, ...}}
        guard let eventKind = dict["event"] as? String,
              let data = dict["data"] as? [String: Any] else {
            return .ignored
        }
        let paneId = data["pane_id"] as? String ?? ""

        switch eventKind {
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
        default:
            return .ignored
        }
    }

    // MARK: - Health

    public func health() -> AdapterHealth {
        let proto = latestProtocol()
        let supportedVersions: Set<Int> = [17]
        if proto == 0 {
            return AdapterHealth(protocolVersion: 0, compatible: false, writesEnabled: false, reason: "protocol unknown")
        }
        if supportedVersions.contains(proto) {
            return AdapterHealth(protocolVersion: proto, compatible: true, writesEnabled: true, reason: nil)
        }
        return AdapterHealth(protocolVersion: proto, compatible: false, writesEnabled: false, reason: "herdr protocol \(proto) not verified for writes")
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
        if let session = env["HERDR_SESSION"], !session.isEmpty {
            // Session-based path resolution (if herdr supports it)
            // For now, fall through to XDG/default
            _ = session
        }
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("herdr/herdr.sock")
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".config/herdr/herdr.sock")
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
