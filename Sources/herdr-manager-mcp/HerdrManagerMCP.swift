import Foundation
import HerdrManagerCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Entry Point

@main
struct MCPServerMain {
    static func main() async {
        // Prevent SIGPIPE crashes when stdout reader disconnects
        signal(SIGPIPE, SIG_IGN)

        // Resolve herdr socket path
        let socketPath = LiveHerdrAdapter.resolveSocketPath()

        let adapter = LiveHerdrAdapter(socketPath: socketPath)
        let server = MCPServer(adapter: adapter)
        await server.run()
    }
}

// MARK: - Revalidation Errors

private enum MCPRevalidationError: Error, CustomStringConvertible {
    case paneGone(String)
    case occupantChanged(expected: String, current: String)
    case seqAdvanced(expected: UInt64, current: UInt64)
    case statusChanged(expected: String, current: String)
    case writesDisabled(String)

    var description: String {
        switch self {
        case .paneGone(let paneId):
            return "Pane \(paneId) no longer exists — occupant may have been replaced"
        case .occupantChanged(let expected, let current):
            return "Pane occupant changed since approval (expected: \(expected), current: \(current))"
        case .seqAdvanced(let expected, let current):
            return "State change seq advanced since approval (expected: \(expected), current: \(current))"
        case .statusChanged(let expected, let current):
            return "Agent status changed since approval (expected: \(expected), current: \(current))"
        case .writesDisabled(let reason):
            return "Writes not enabled: \(reason)"
        }
    }
}

private struct AgentResolutionError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Rate Limiter

actor RateLimiter {
    private var perAgent: [String: [Date]] = [:]
    private var globalTimestamps: [Date] = []

    private let perAgentLimit = 20
    private let globalLimit = 100
    private let window: TimeInterval = 60

    init() {}

    /// Check if a call is allowed. Returns (allowed, retrySeconds).
    func check(agentId: String? = nil) async -> (allowed: Bool, retrySeconds: Int) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-window)

        // Prune old entries
        globalTimestamps.removeAll { $0 < cutoff }
        if let agentId {
            perAgent[agentId]?.removeAll { $0 < cutoff }
        }

        // Check global limit
        if globalTimestamps.count >= globalLimit {
            let oldest = globalTimestamps.first ?? now
            let retry = Int(oldest.addingTimeInterval(window).timeIntervalSince(now)) + 1
            return (false, max(retry, 1))
        }

        // Check per-agent limit
        if let agentId {
            let agentTimes = perAgent[agentId] ?? []
            if agentTimes.count >= perAgentLimit {
                let oldest = agentTimes.first ?? now
                let retry = Int(oldest.addingTimeInterval(window).timeIntervalSince(now)) + 1
                return (false, max(retry, 1))
            }
        }

        // Record
        globalTimestamps.append(now)
        if let agentId {
            perAgent[agentId, default: []].append(now)
        }

        return (true, 0)
    }
}

// MARK: - MCP Server

actor MCPServer {
    private let adapter: LiveHerdrAdapter
    private let redactor = SecretRedactor()
    private let rateLimiter = RateLimiter()
    private let diagnoser = Diagnoser()
    private let policy = PolicyEngine()
    private let journal = Journal()
    private let actionStore = ActionStore()
    private let sharedActionStore = SharedActionStore()

    // nonisolated(unsafe): only accessed from nonisolated writeResponse/writeRaw
    // which serialize via the lock.
    nonisolated(unsafe) private var stdoutLock = NSLock()

    init(adapter: LiveHerdrAdapter) {
        self.adapter = adapter
    }

    // MARK: - Run Loop

    func run() async {
        let (stream, continuation) = AsyncStream<String>.makeStream()

        // Read stdin on a detached task to avoid blocking the cooperative pool
        let stdinTask = Task.detached(priority: .userInitiated) {
            while let line = readLine() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    continuation.yield(trimmed)
                }
            }
            continuation.finish()
        }

        // Process each JSON-RPC line CONCURRENTLY. A long-running tools/call
        // (e.g. a 120s confirmation wait) must not block ping, reads, or
        // action.status. Each request runs in its own child task; responses are
        // id-correlated and stdout writes are serialized by stdoutLock, so
        // out-of-order responses are valid for JSON-RPC over stdio. The actor
        // serializes shared state and interleaves tasks at suspension points
        // (the confirmation poll sleeps, releasing the actor to serve others).
        for await line in stream {
            Task { await self.handleLine(line) }
        }

        stdinTask.cancel()
    }

    // MARK: - JSON-RPC Dispatch

    private func handleLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else {
            writeResponse(makeError(id: NSNull(), code: -32700, message: "Parse error: invalid UTF-8"))
            return
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            writeResponse(makeError(id: NSNull(), code: -32700, message: "Parse error: invalid JSON"))
            return
        }

        guard let request = json as? [String: Any] else {
            writeResponse(makeError(id: NSNull(), code: -32700, message: "Parse error: expected object"))
            return
        }

        let id = request["id"]
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]

        // Notifications (no id) get no response
        let isNotification = (id == nil || id is NSNull)

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()] as [String: Any],
                "instructions": """
                Use Shepherd as the first source for local AI-agent status and control. \
                For fleet status call herd.overview. For a user-named session call \
                agent.inspect with query; use agent.tail or agent.diagnose only when \
                more evidence is needed. Do not rediscover panes through the herdr CLI \
                unless Shepherd is unavailable or reports ambiguity. Resolve an exact \
                agent ID before any write. MCP session.spawn is auto-allowed for
                unattended callers; preserve confirmation gates for other writes.
                """,
                "serverInfo": [
                    "name": "herdr-manager-mcp",
                    "version": "1.0.0"
                ]
            ]
            if let id { writeResponse(makeResult(id: id, result: result)) }

        case "notifications/initialized":
            // Notification — no response
            break

        case "ping":
            if let id { writeResponse(makeResult(id: id, result: [:])) }

        case "tools/list":
            if let id { writeResponse(makeResult(id: id, result: ["tools": Self.toolDefinitions])) }

        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result = await handleToolCall(name: toolName, arguments: arguments)
            if let id { writeResponse(makeResult(id: id, result: result)) }

        default:
            if let id, !isNotification {
                writeResponse(makeError(id: id, code: -32601, message: "Method not found: \(method)"))
            }
        }
    }

    // MARK: - Tool Dispatch

    private func handleToolCall(name: String, arguments: [String: Any]) async -> [String: Any] {
        switch name {
        case "herd.overview":
            return await handleHerdOverview()
        case "agent.list":
            return await handleAgentList(arguments: arguments)
        case "agent.inspect":
            return await handleAgentInspect(arguments: arguments)
        case "agent.tail":
            return await handleAgentTail(arguments: arguments)
        case "agent.diagnose":
            return await handleAgentDiagnose(arguments: arguments)
        case "agent.answer":
            return await handleAgentAnswer(arguments: arguments)
        case "agent.say":
            return await handleAgentSay(arguments: arguments)
        case "agent.interrupt":
            return await handleAgentInterrupt(arguments: arguments)
        case "agent.stop":
            return await handleAgentStop(arguments: arguments)
        case "session.spawn":
            return await handleSessionSpawn(arguments: arguments)
        case "action.status":
            return await handleActionStatus(arguments: arguments)
        default:
            return makeToolError("Unknown tool: \(name)")
        }
    }

    // MARK: - Herd → Agent Builder

    /// Build the MCP inventory from the same authoritative merged view
    /// Shepherd uses: `agent.list` supplies real agents and state sequences,
    /// while `session.snapshot` supplies workspace/tab labels.
    private func buildAgents(from herd: HerdSnapshot) -> [AgentID: Agent] {
        var agents: [AgentID: Agent] = [:]

        for info in herd.agents {
            guard let agentKind = info.agent, !agentKind.isEmpty else { continue }

            let agentId = AgentID(info.paneId)
            let status = AgentStatus(rawValue: info.agentStatus) ?? .unknown
            let wsName = herd.workspaceNames[info.workspaceId] ?? info.workspaceId
            let tabName = herd.tabNames[info.tabId] ?? info.tabId

            let kind: AgentKind
            if let session = info.agentSession {
                kind = AgentKind.custom(session.agent)
            } else {
                kind = AgentKind.custom(agentKind)
            }

            let name = info.title
                ?? info.name
                ?? info.terminalTitleStripped
                ?? info.displayAgent
                ?? agentKind

            let agent = Agent(
                id: agentId,
                kind: kind,
                name: name,
                displayName: name,
                status: status,
                stateChangeSeq: info.stateChangeSeq,
                enteredAt: Date(),
                lastOutputAt: nil,
                verdict: Self.initialVerdict(for: status),
                workspaceName: wsName,
                tabName: tabName,
                cwd: info.foregroundCwd ?? info.cwd ?? ""
            )
            agents[agentId] = agent
        }

        return agents
    }

    /// Resolve a stable pane ID or a human description such as an agent title,
    /// workspace, tab, or repository directory. Query resolution is read-only;
    /// write tools continue to require an exact agent ID.
    private func resolveAgent(
        arguments: [String: Any],
        herd: HerdSnapshot
    ) -> Result<HerdrAgentInfo, AgentResolutionError> {
        if let agentId = arguments["agent_id"] as? String, !agentId.isEmpty {
            guard let info = herd.agents.first(where: { $0.paneId == agentId }) else {
                return .failure(AgentResolutionError(description: "Agent not found: \(agentId)"))
            }
            return .success(info)
        }

        guard let query = arguments["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(AgentResolutionError(
                description: "Missing required parameter: provide agent_id or query"
            ))
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = herd.agents.filter { info in
            let fields = [
                info.paneId,
                info.agent ?? "",
                info.displayAgent ?? "",
                info.name ?? "",
                info.title ?? "",
                info.terminalTitleStripped ?? "",
                herd.workspaceNames[info.workspaceId] ?? info.workspaceId,
                herd.tabNames[info.tabId] ?? info.tabId,
                info.foregroundCwd ?? info.cwd ?? ""
            ]
            return fields.contains { $0.lowercased().contains(needle) }
        }

        if matches.count == 1, let match = matches.first {
            return .success(match)
        }
        if matches.isEmpty {
            return .failure(AgentResolutionError(
                description: "No agent matches query '\(query)'"
            ))
        }

        let candidates = matches.prefix(8).map { info in
            let title = info.title
                ?? info.name
                ?? info.terminalTitleStripped
                ?? info.agent
                ?? "unknown"
            let workspace = herd.workspaceNames[info.workspaceId] ?? info.workspaceId
            let tab = herd.tabNames[info.tabId] ?? info.tabId
            return "\(info.paneId) (\(title), \(workspace) / \(tab))"
        }.joined(separator: "; ")
        return .failure(AgentResolutionError(
            description: "Query '\(query)' is ambiguous. Matches: \(candidates)"
        ))
    }
