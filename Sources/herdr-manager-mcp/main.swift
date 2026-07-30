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
                agent ID before any write, and preserve confirmation gates.
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

    private static func initialVerdict(for status: AgentStatus) -> Verdict {
        switch status {
        case .blocked:
            return .awaitingInput(BlockClassification(
                kind: .unknownBlock, since: Date(), summary: "blocked"
            ))
        case .idle, .working, .done:
            return .healthy
        case .unknown:
            return .unclassifiable(reason: "unknown status")
        }
    }

    // MARK: - herd.overview

    private func handleHerdOverview() async -> [String: Any] {
        do {
            try await ensureConnected()
            let herd = try await adapter.herdSnapshot()
            var agents = buildAgents(from: herd)

            // Diagnose non-idle agents
            for agent in agents.values where agent.status != .idle {
                let verdict = await diagnoser.diagnose(agent: agent, adapter: adapter)
                if var current = agents[agent.id] {
                    current.verdict = verdict
                    agents[agent.id] = current
                }
            }

            let text = Self.formatOverview(
                agents: Array(agents.values),
                workspaceNames: herd.workspaceNames
            )
            let redacted = redactor.redact(text)
            return makeToolResult(redacted.redactedText)
        } catch {
            return makeToolError("Failed to get overview: \(error.localizedDescription)")
        }
    }

    // MARK: - agent.list

    private func handleAgentList(arguments: [String: Any]) async -> [String: Any] {
        do {
            try await ensureConnected()
            let herd = try await adapter.herdSnapshot()
            var agents = buildAgents(from: herd)

            // Diagnose non-idle agents
            for agent in agents.values where agent.status != .idle {
                let verdict = await diagnoser.diagnose(agent: agent, adapter: adapter)
                if var current = agents[agent.id] {
                    current.verdict = verdict
                    agents[agent.id] = current
                }
            }

            var agentList = Array(agents.values)

            // Apply filters
            if let statusStr = arguments["status"] as? String,
               let filterStatus = AgentStatus(rawValue: statusStr) {
                agentList = agentList.filter { $0.status == filterStatus }
            }
            if let workspace = arguments["workspace"] as? String {
                agentList = agentList.filter { agent in
                    let wsName = herd.workspaceNames[agent.id.workspaceId] ?? agent.id.workspaceId
                    return wsName.lowercased().contains(workspace.lowercased()) ||
                           agent.id.workspaceId.lowercased().contains(workspace.lowercased())
                }
            }
            if let query = arguments["query"] as? String, !query.isEmpty {
                let needle = query.lowercased()
                agentList = agentList.filter { agent in
                    [
                        agent.id.raw,
                        agent.name,
                        agent.displayName,
                        agent.workspaceName,
                        agent.tabName,
                        agent.cwd,
                        Self.agentKindString(agent.kind)
                    ].contains { $0.lowercased().contains(needle) }
                }
            }

            let text = Self.formatAgentList(
                agents: agentList,
                workspaceNames: herd.workspaceNames
            )
            let redacted = redactor.redact(text)
            return makeToolResult(redacted.redactedText)
        } catch {
            return makeToolError("Failed to list agents: \(error.localizedDescription)")
        }
    }

    // MARK: - agent.inspect

    private func handleAgentInspect(arguments: [String: Any]) async -> [String: Any] {
        do {
            try await ensureConnected()
            let herd = try await adapter.herdSnapshot()
            let info: HerdrAgentInfo
            switch resolveAgent(arguments: arguments, herd: herd) {
            case .success(let resolved):
                info = resolved
            case .failure(let error):
                return makeToolError(error.description)
            }
            let paneId = info.paneId
            let agentId = AgentID(paneId)

            let (allowed, retry) = await rateLimiter.check(agentId: paneId)
            guard allowed else {
                return makeToolError("Rate limit exceeded. Try again in \(retry) seconds.")
            }

            var agents = buildAgents(from: herd)

            // Diagnose
            var verdict: Verdict = .unclassifiable(reason: "agent not found")
            if let agent = agents[agentId] {
                verdict = await diagnoser.diagnose(agent: agent, adapter: adapter)
                if var current = agents[agentId] {
                    current.verdict = verdict
                    agents[agentId] = current
                }
            }

            // Call explain, processInfo, read
            let explain: AgentExplainResult?
            do {
                explain = try await adapter.explain(paneId: paneId)
            } catch {
                explain = nil
            }

            let procInfo: ProcessInfoResult?
            do {
                procInfo = try await adapter.processInfo(paneId: paneId)
            } catch {
                procInfo = nil
            }

            let readResult: PaneReadResult?
            do {
                readResult = try await adapter.read(paneId: paneId, source: .detection)
            } catch {
                readResult = nil
            }

            let text = Self.formatInspect(
                info: info,
                verdict: verdict,
                explain: explain,
                procInfo: procInfo,
                recentOutput: readResult?.text,
                workspaceNames: herd.workspaceNames,
                tabNames: herd.tabNames
            )
            let redacted = redactor.redact(text)
            return makeToolResult(redacted.redactedText)
        } catch {
            return makeToolError("Failed to inspect agent: \(error.localizedDescription)")
        }
    }

    // MARK: - agent.tail

    private func handleAgentTail(arguments: [String: Any]) async -> [String: Any] {
        let lineCount = min(max(arguments["lines"] as? Int ?? 50, 1), 200)

        let sourceStr = arguments["source"] as? String ?? "detection"
        let source: PaneReadSource
        switch sourceStr {
        case "visible": source = .visible
        case "recent": source = .recent
        case "recent_unwrapped": source = .recentUnwrapped
        case "detection": source = .detection
        default: source = .detection
        }

        do {
            try await ensureConnected()
            let herd = try await adapter.herdSnapshot()
            let info: HerdrAgentInfo
            switch resolveAgent(arguments: arguments, herd: herd) {
            case .success(let resolved):
                info = resolved
            case .failure(let error):
                return makeToolError(error.description)
            }

            let (allowed, retry) = await rateLimiter.check(agentId: info.paneId)
            guard allowed else {
                return makeToolError("Rate limit exceeded. Try again in \(retry) seconds.")
            }

            // Ask herdr to bound the read at the source, matching Shepherd's
            // Peek behavior and avoiding a large scrollback round trip.
            let result = try await adapter.read(
                paneId: info.paneId,
                source: source,
                lines: lineCount
            )
            let allLines = result.text.split(separator: "\n", omittingEmptySubsequences: false)
            let startIdx = max(allLines.count - lineCount, 0)
            let selectedLines = allLines[startIdx...]
            var output = selectedLines.joined(separator: "\n")

            let redacted = redactor.redact(output)
            output = redacted.redactedText

            if redacted.redactionCount > 0 {
                output += "\n\n[\(redacted.redactionCount) secret\(redacted.redactionCount == 1 ? "" : "s") redacted]"
            }

            return makeToolResult(output)
        } catch {
            return makeToolError("Failed to tail agent: \(error.localizedDescription)")
        }
    }

    // MARK: - agent.diagnose

    private func handleAgentDiagnose(arguments: [String: Any]) async -> [String: Any] {
        do {
            try await ensureConnected()
            let herd = try await adapter.herdSnapshot()
            let info: HerdrAgentInfo
            switch resolveAgent(arguments: arguments, herd: herd) {
            case .success(let resolved):
                info = resolved
            case .failure(let error):
                return makeToolError(error.description)
            }

            let (allowed, retry) = await rateLimiter.check(agentId: info.paneId)
            guard allowed else {
                return makeToolError("Rate limit exceeded. Try again in \(retry) seconds.")
            }

            let agents = buildAgents(from: herd)
            let agentId = AgentID(info.paneId)
            guard let agent = agents[agentId] else {
                return makeToolError("Agent not found: \(info.paneId)")
            }

            let verdict = await diagnoser.diagnose(agent: agent, adapter: adapter)

            // Get explain for extra evidence
            let explain: AgentExplainResult?
            do {
                explain = try await adapter.explain(paneId: agent.id.raw)
            } catch {
                explain = nil
            }

            // Get process info for CPU state
            let procInfo: ProcessInfoResult?
            do {
                procInfo = try await adapter.processInfo(paneId: agent.id.raw)
            } catch {
                procInfo = nil
            }

            let text = Self.formatDiagnosis(agent: agent, verdict: verdict, explain: explain, procInfo: procInfo)
            let redacted = redactor.redact(text)
            return makeToolResult(redacted.redactedText)
        } catch {
            return makeToolError("Failed to diagnose agent: \(error.localizedDescription)")
        }
    }

    // MARK: - agent.answer

    private func handleAgentAnswer(arguments: [String: Any]) async -> [String: Any] {
        // Write-gate: reject if herdr protocol not verified for writes
        if let error = await checkWritesEnabled() { return error }

        guard let agentIdStr = arguments["agent_id"] as? String, !agentIdStr.isEmpty else {
            return makeToolError("Missing required parameter: agent_id")
        }
        guard let choice = arguments["choice"] as? String else {
            return makeToolError("Missing required parameter: choice")
        }

        let validChoices = ["approve", "deny", "accept_once", "select", "cancel"]
        guard validChoices.contains(choice) else {
            return makeToolError("Invalid choice '\(choice)'. Must be one of: \(validChoices.joined(separator: ", "))")
        }

        // state_change_seq is MANDATORY for agent.answer
        guard let providedSeq = arguments["state_change_seq"] as? Int else {
            return makeToolError("Missing required parameter: state_change_seq (mandatory for agent.answer)")
        }

        if choice == "select" {
            guard let index = arguments["index"] as? Int else {
                return makeToolError("choice 'select' requires an 'index' parameter (integer)")
            }
            // Index bounds: 0...20
            guard SpawnPathPolicy.isValidSelectIndex(index) else {
                return makeToolError("Index out of bounds: \(index). Must be 0...20.")
            }
        }

        do {
            try await ensureConnected()
            let herd = try await adapter.herdSnapshot()
            let paneId = agentIdStr

            guard let paneInfo = herd.agents.first(where: { $0.paneId == paneId }) else {
                return makeToolError("Agent not found: \(agentIdStr)")
            }

            guard paneInfo.agentStatus == "blocked" else {
                return makeToolError("Agent \(agentIdStr) is not blocked (status: \(paneInfo.agentStatus)). agent.answer requires status=blocked.")
            }

            // Verify state_change_seq matches current
            let currentSeq = paneInfo.stateChangeSeq
            if UInt64(providedSeq) != currentSeq {
                return makeToolError("Stale state_change_seq: provided \(providedSeq), current \(currentSeq). Re-diagnose and retry.")
            }

            // Record the observed status sequence so the consecutive-answer
            // protection RESETS when the agent's status episode actually
            // advances. Without this, three answers would permanently block
            // further answers for this agent for the process lifetime.
            await policy.recordStatusChange(agentId: agentIdStr, newSeq: currentSeq)

            // Check policy
            let policyResult = await policy.checkWriteAllowed(agentId: agentIdStr, tier: .gated)
            guard policyResult.allowed else {
                return makeToolError("Policy denied: \(policyResult.reason ?? "unknown")")
            }

            // Detect the block kind so we only answer RECOGNIZED prompts.
            // Unknown or merely-probable blocks stay read-only — we never send
            // keystrokes we cannot justify for the detected prompt shape.
            let explain = try await adapter.explain(paneId: paneId)
            let blockKind = explain.matchedRuleId.map { BlockKind.from(ruleId: $0) } ?? .unknownBlock

            guard let resolvedKeys = Self.keys(forChoice: choice, index: arguments["index"] as? Int, blockKind: blockKind) else {
                return makeToolError("Cannot answer: detected block kind '\(blockKind.rawValue)' does not permit choice '\(choice)'. Recognized prompts only; unknown/weak blocks stay read-only.")
            }

            try await adapter.sendKeys(paneId: paneId, keys: resolvedKeys)

            await policy.recordWrite(agentId: agentIdStr)
            await policy.recordAnswer(agentId: agentIdStr)

            // Capture fingerprint in params for audit trail
            var params: [String: String] = ["agent_id": agentIdStr, "choice": choice]
            params["_fp_occupant"] = occupantFingerprint(from: paneInfo)
            params["_fp_status"] = paneInfo.agentStatus
            params["_fp_seq"] = "\(currentSeq)"

            let actionId = await actionStore.create(tool: "agent.answer", params: params)
            await actionStore.markExecuted(actionId)

            await journal.record(JournalEntry(
                actionId: actionId,
                tool: "agent.answer",
                params: ["agent_id": agentIdStr, "choice": choice, "keys": resolvedKeys.joined(separator: ",")],
                caller: "mcp",
                preState: "status=blocked, seq=\(currentSeq)",
                postState: "status=working",
                outcome: "executed"
            ))

            let keysJson = resolvedKeys.map { "\"\($0)\"" }.joined(separator: ",")
            return makeToolResult("{\"sent\":true,\"resolvedKeys\":[\(keysJson)],\"newStatus\":\"working\",\"actionId\":\"\(actionId)\"}")
        } catch {
            return makeToolError("agent.answer failed: \(error.localizedDescription)")
        }
    }

    // MARK: - agent.say

    private func handleAgentSay(arguments: [String: Any]) async -> [String: Any] {
        // Write-gate: reject if herdr protocol not verified for writes
        if let error = await checkWritesEnabled() { return error }

        guard let agentIdStr = arguments["agent_id"] as? String, !agentIdStr.isEmpty else {
            return makeToolError("Missing required parameter: agent_id")
        }
        guard let text = arguments["text"] as? String else {
            return makeToolError("Missing required parameter: text")
        }
        guard text.count <= 2000 else {
            return makeToolError("Text too long: \(text.count) chars (max 2000)")
        }

        do {
            try await ensureConnected()
            let herd = try await adapter.herdSnapshot()
            let paneId = agentIdStr

            guard let paneInfo = herd.agents.first(where: { $0.paneId == paneId }) else {
                return makeToolError("Agent not found: \(agentIdStr)")
            }

            let status = paneInfo.agentStatus
            let tier: AuthorityTier = (status == "idle" || status == "done") ? .gated : .confirm

            let policyResult = await policy.checkWriteAllowed(agentId: agentIdStr, tier: tier)
            guard policyResult.allowed else {
                return makeToolError("Policy denied: \(policyResult.reason ?? "unknown")")
            }

            // Capture fingerprint info for revalidation after confirmation wait
            let fpOccupant = occupantFingerprint(from: paneInfo)
            let fpStatus = paneInfo.agentStatus
            let fpSeq = paneInfo.stateChangeSeq

            // Confirm tier: create pending action and wait for UI approval
            if case .confirm = tier {
                var params: [String: String] = [
                    "agent_id": agentIdStr, "text": String(text.prefix(100))
                ]
                params["_fp_occupant"] = fpOccupant
                params["_fp_status"] = fpStatus
                params["_fp_seq"] = "\(fpSeq)"

                let actionId = try await sharedActionStore.create(tool: "agent.say", params: params)

                await journal.record(JournalEntry(
                    actionId: actionId, tool: "agent.say",
                    params: ["agent_id": agentIdStr, "text_length": "\(text.count)"],
                    caller: "mcp", preState: "status=\(status), seq=\(fpSeq)",
                    outcome: "pending_confirmation"
                ))

                // Poll for approval from menu-bar UI
                let finalState = await waitForConfirmation(actionId: actionId)

                if finalState == .approved {
                    // Atomic claim gate
                    guard let claimed = try await sharedActionStore.claimExecuting(actionId: actionId) else {
                        try? await sharedActionStore.markFailed(actionId, detail: "action no longer claimable")
                        return makeToolError("Action no longer claimable (actionId: \(actionId))")
                    }

                    // Revalidate pane occupant + status episode after the wait
                    do {
                        try await revalidate(action: claimed, paneId: paneId)
                    } catch {
                        try? await sharedActionStore.markFailed(actionId, detail: "revalidation failed: \(error)")
                        return makeToolError("Revalidation failed: \(error). No input sent.")
                    }

                    try await adapter.prompt(paneId: paneId, text: text)
                    await policy.recordWrite(agentId: agentIdStr)
                    try? await sharedActionStore.markExecuted(actionId)

                    await journal.record(JournalEntry(
                        actionId: actionId, tool: "agent.say",
                        params: ["agent_id": agentIdStr, "text_length": "\(text.count)"],
                        caller: "mcp", preState: "status=\(status)",
                        postState: "sent", outcome: "executed"
                    ))

                    if let waitFor = arguments["wait_for"] as? String {
                        let timeoutMs = arguments["timeout_ms"] as? Int ?? 30000
                        let settled = try await adapter.waitStatus(paneId: paneId, until: [waitFor], timeoutMs: timeoutMs)
                        return makeToolResult("{\"sent\":true,\"actionId\":\"\(actionId)\",\"outcome\":\"\(settled ? "settled" : "timeout")\"}")
                    }
                    return makeToolResult("{\"sent\":true,\"actionId\":\"\(actionId)\",\"outcome\":\"sent\"}")
                } else if finalState == .denied {
                    await journal.record(JournalEntry(
                        actionId: actionId, tool: "agent.say",
                        params: ["agent_id": agentIdStr],
                        caller: "mcp", preState: "status=\(status)",
                        outcome: "denied"
                    ))
                    return makeToolError("Action denied by user (actionId: \(actionId))")
                } else {
                    await journal.record(JournalEntry(
                        actionId: actionId, tool: "agent.say",
                        params: ["agent_id": agentIdStr],
                        caller: "mcp", preState: "status=\(status)",
                        outcome: "expired"
                    ))
                    return makeToolError("Action expired (actionId: \(actionId))")
                }
            }

            // Gated tier: auto-allowed
            try await adapter.prompt(paneId: paneId, text: text)
            await policy.recordWrite(agentId: agentIdStr)

            var params: [String: String] = [
                "agent_id": agentIdStr, "text": String(text.prefix(100))
            ]
            params["_fp_occupant"] = fpOccupant
            params["_fp_status"] = fpStatus
            params["_fp_seq"] = "\(fpSeq)"

            let actionId = await actionStore.create(tool: "agent.say", params: params)
            await actionStore.markExecuted(actionId)

            await journal.record(JournalEntry(
                actionId: actionId, tool: "agent.say",
                params: ["agent_id": agentIdStr, "text_length": "\(text.count)"],
                caller: "mcp", preState: "status=\(status), seq=\(fpSeq)",
                postState: "sent", outcome: "executed"
            ))

            if let waitFor = arguments["wait_for"] as? String {
                let timeoutMs = arguments["timeout_ms"] as? Int ?? 30000
                let settled = try await adapter.waitStatus(paneId: paneId, until: [waitFor], timeoutMs: timeoutMs)
                return makeToolResult("{\"sent\":true,\"actionId\":\"\(actionId)\",\"outcome\":\"\(settled ? "settled" : "timeout")\"}")
            }
            return makeToolResult("{\"sent\":true,\"actionId\":\"\(actionId)\",\"outcome\":\"sent\"}")
        } catch {
            return makeToolError("agent.say failed: \(error.localizedDescription)")
        }
    }

    // MARK: - agent.interrupt

    private func handleAgentInterrupt(arguments: [String: Any]) async -> [String: Any] {
        // Write-gate: reject if herdr protocol not verified for writes
        if let error = await checkWritesEnabled() { return error }

        guard let agentIdStr = arguments["agent_id"] as? String, !agentIdStr.isEmpty else {
            return makeToolError("Missing required parameter: agent_id")
        }
        let level = arguments["level"] as? String ?? "escape"
        guard level == "escape" || level == "sigint" else {
            return makeToolError("Invalid level '\(level)'. Must be 'escape' or 'sigint'.")
        }

        do {
            try await ensureConnected()
            let herd = try await adapter.herdSnapshot()
            let paneId = agentIdStr

            guard let paneInfo = herd.agents.first(where: { $0.paneId == paneId }) else {
                return makeToolError("Agent not found: \(agentIdStr)")
            }

            // Capture fingerprint info for revalidation after confirmation wait
            var params: [String: String] = ["agent_id": agentIdStr, "level": level]
            params["_fp_occupant"] = occupantFingerprint(from: paneInfo)
            params["_fp_status"] = paneInfo.agentStatus
            params["_fp_seq"] = "\(paneInfo.stateChangeSeq)"

            let actionId = try await sharedActionStore.create(tool: "agent.interrupt", params: params)

            await journal.record(JournalEntry(
                actionId: actionId, tool: "agent.interrupt",
                params: ["agent_id": agentIdStr, "level": level],
                caller: "mcp", preState: "status=\(paneInfo.agentStatus), seq=\(paneInfo.stateChangeSeq)",
                outcome: "pending_confirmation"
            ))

            // Poll for approval from menu-bar UI
            let finalState = await waitForConfirmation(actionId: actionId)

            if finalState == .approved {
                // Atomic claim gate
                guard let claimed = try await sharedActionStore.claimExecuting(actionId: actionId) else {
                    try? await sharedActionStore.markFailed(actionId, detail: "action no longer claimable")
                    return makeToolError("Action no longer claimable (actionId: \(actionId))")
                }

                // Revalidate pane occupant + status episode after the wait
                do {
                    _ = try await revalidate(action: claimed, paneId: paneId)
                } catch {
                    try? await sharedActionStore.markFailed(actionId, detail: "revalidation failed: \(error)")
                    return makeToolError("Revalidation failed: \(error). No input sent.")
                }

                let keys: [String] = level == "escape" ? ["esc"] : ["ctrl+c"]
                try await adapter.sendKeys(paneId: paneId, keys: keys)
                await policy.recordWrite(agentId: agentIdStr)
                try? await sharedActionStore.markExecuted(actionId)

                await journal.record(JournalEntry(
                    actionId: actionId, tool: "agent.interrupt",
                    params: ["agent_id": agentIdStr, "level": level],
                    caller: "mcp", preState: "status=\(paneInfo.agentStatus)",
                    postState: "interrupted", outcome: "executed"
                ))
                return makeToolResult("{\"sent\":true,\"actionId\":\"\(actionId)\",\"level\":\"\(level)\"}")
            } else if finalState == .denied {
                await journal.record(JournalEntry(
                    actionId: actionId, tool: "agent.interrupt",
                    params: ["agent_id": agentIdStr],
                    caller: "mcp", preState: "status=\(paneInfo.agentStatus)",
                    outcome: "denied"
                ))
                return makeToolError("Action denied by user (actionId: \(actionId))")
            } else {
                await journal.record(JournalEntry(
                    actionId: actionId, tool: "agent.interrupt",
                    params: ["agent_id": agentIdStr],
                    caller: "mcp", preState: "status=\(paneInfo.agentStatus)",
                    outcome: "expired"
                ))
                return makeToolError("Action expired (actionId: \(actionId))")
            }
        } catch {
            return makeToolError("agent.interrupt failed: \(error.localizedDescription)")
        }
    }

    // MARK: - agent.stop

    private func handleAgentStop(arguments: [String: Any]) async -> [String: Any] {
        // Write-gate: reject if herdr protocol not verified for writes
        if let error = await checkWritesEnabled() { return error }

        guard let agentIdStr = arguments["agent_id"] as? String, !agentIdStr.isEmpty else {
            return makeToolError("Missing required parameter: agent_id")
        }
        let reason = arguments["reason"] as? String ?? "user requested"

        do {
            try await ensureConnected()
            let herd = try await adapter.herdSnapshot()
            let paneId = agentIdStr

            guard let paneInfo = herd.agents.first(where: { $0.paneId == paneId }) else {
                return makeToolError("Agent not found: \(agentIdStr)")
            }

            // Capture fingerprint info for revalidation after confirmation wait
            var params: [String: String] = ["agent_id": agentIdStr, "reason": reason]
            params["_fp_occupant"] = occupantFingerprint(from: paneInfo)
            params["_fp_status"] = paneInfo.agentStatus
            params["_fp_seq"] = "\(paneInfo.stateChangeSeq)"

            let actionId = try await sharedActionStore.create(tool: "agent.stop", params: params)

            await journal.record(JournalEntry(
                actionId: actionId, tool: "agent.stop",
                params: ["agent_id": agentIdStr, "reason": reason],
                caller: "mcp", preState: "status=\(paneInfo.agentStatus), seq=\(paneInfo.stateChangeSeq)",
                outcome: "pending_confirmation",
                keepForever: true
            ))

            // Poll for approval from menu-bar UI
            let finalState = await waitForConfirmation(actionId: actionId)

            if finalState == .approved {
                // Atomic claim gate
                guard let claimed = try await sharedActionStore.claimExecuting(actionId: actionId) else {
                    try? await sharedActionStore.markFailed(actionId, detail: "action no longer claimable")
                    return makeToolError("Action no longer claimable (actionId: \(actionId))")
                }

                // Revalidate pane occupant + status episode after the wait
                do {
                    _ = try await revalidate(action: claimed, paneId: paneId)
                } catch {
                    try? await sharedActionStore.markFailed(actionId, detail: "revalidation failed: \(error)")
                    return makeToolError("Revalidation failed: \(error). No input sent.")
                }

                try await adapter.closePane(paneId: paneId)
                await policy.recordWrite(agentId: agentIdStr)
                try? await sharedActionStore.markExecuted(actionId)

                await journal.record(JournalEntry(
                    actionId: actionId, tool: "agent.stop",
                    params: ["agent_id": agentIdStr, "reason": reason],
                    caller: "mcp", preState: "status=\(paneInfo.agentStatus)",
                    postState: "closed", outcome: "executed",
                    keepForever: true
                ))
                return makeToolResult("{\"closed\":true,\"actionId\":\"\(actionId)\"}")
            } else if finalState == .denied {
                await journal.record(JournalEntry(
                    actionId: actionId, tool: "agent.stop",
                    params: ["agent_id": agentIdStr],
                    caller: "mcp", preState: "status=\(paneInfo.agentStatus)",
                    outcome: "denied",
                    keepForever: true
                ))
                return makeToolError("Action denied by user (actionId: \(actionId))")
            } else {
                await journal.record(JournalEntry(
                    actionId: actionId, tool: "agent.stop",
                    params: ["agent_id": agentIdStr],
                    caller: "mcp", preState: "status=\(paneInfo.agentStatus)",
                    outcome: "expired",
                    keepForever: true
                ))
                return makeToolError("Action expired (actionId: \(actionId))")
            }
        } catch {
            return makeToolError("agent.stop failed: \(error.localizedDescription)")
        }
    }

    // MARK: - session.spawn

    private func handleSessionSpawn(arguments: [String: Any]) async -> [String: Any] {
        // Write-gate: reject if herdr protocol not verified for writes
        if let error = await checkWritesEnabled() { return error }

        guard let kind = arguments["kind"] as? String, !kind.isEmpty else {
            return makeToolError("Missing required parameter: kind")
        }
        guard let name = arguments["name"] as? String, !name.isEmpty else {
            return makeToolError("Missing required parameter: name")
        }

        // Validate agent kind
        guard SpawnPathPolicy.isSupportedSpawnKind(kind) else {
            let supportedKinds = SpawnPathPolicy.supportedKinds
            return makeToolError("Unsupported agent kind '\(kind)'. Must be one of: \(supportedKinds.sorted().joined(separator: ", "))")
        }

        let placement = arguments["placement"] as? String ?? "new_workspace"
        guard ["new_workspace", "new_tab", "split"].contains(placement) else {
            return makeToolError("Invalid placement '\(placement)'. Must be new_workspace, new_tab, or split.")
        }

        var resolvedPath: String?
        var workspaceId = arguments["workspace_id"] as? String
        var targetInfo: HerdrAgentInfo?
        var cwdHint: String?

        if placement == "new_workspace" {
            guard let repoPath = arguments["repo_path"] as? String, !repoPath.isEmpty else {
                return makeToolError("placement=new_workspace requires repo_path")
            }

            // Canonicalize with symlink resolution, then validate path
            // components to defeat sibling-prefix and symlink escapes.
            let expandedPath = NSString(string: repoPath).expandingTildeInPath
            let standardizedPath = (expandedPath as NSString).standardizingPath
            let canonical = URL(fileURLWithPath: standardizedPath).resolvingSymlinksInPath().path

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDir),
                  isDir.boolValue else {
                return makeToolError("repo_path does not exist or is not a directory: \(canonical)")
            }

            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let allowedRoots = [
                homeDir + "/Documents",
                homeDir + "/Developer",
                homeDir + "/Projects"
            ]
            guard SpawnPathPolicy.isPathWithinAllowedRoots(canonical, allowedRoots: allowedRoots) else {
                return makeToolError(
                    "repo_path '\(canonical)' is outside allowed roots: \(allowedRoots.joined(separator: ", "))"
                )
            }
            resolvedPath = canonical
            cwdHint = canonical
        } else {
            do {
                try await ensureConnected()
                let herd = try await adapter.herdSnapshot()

                if placement == "new_tab" {
                    guard let requestedWorkspace = workspaceId, !requestedWorkspace.isEmpty else {
                        return makeToolError("placement=new_tab requires workspace_id")
                    }
                    guard herd.workspaceNames[requestedWorkspace] != nil else {
                        return makeToolError("Workspace not found: \(requestedWorkspace)")
                    }
                    cwdHint = herd.agents.first(where: {
                        $0.workspaceId == requestedWorkspace
                    }).flatMap { $0.foregroundCwd ?? $0.cwd }
                } else {
                    guard let targetId = arguments["target_agent_id"] as? String,
                          !targetId.isEmpty else {
                        return makeToolError("placement=split requires target_agent_id")
                    }
                    guard let target = herd.agents.first(where: { $0.paneId == targetId }) else {
                        return makeToolError("Target agent not found: \(targetId)")
                    }
                    targetInfo = target
                    workspaceId = target.workspaceId
                    cwdHint = target.foregroundCwd ?? target.cwd
                }
            } catch {
                return makeToolError("Failed to resolve placement: \(error.localizedDescription)")
            }
        }

        let brief = arguments["brief"] as? String
        let spaceLabel = arguments["space_label"] as? String

        var params: [String: String] = [
            "placement": placement,
            "kind": kind,
            "name": name
        ]
        if let resolvedPath { params["repo_path"] = resolvedPath }
        if let workspaceId { params["workspace_id"] = workspaceId }
        if let targetInfo {
            params["target_agent_id"] = targetInfo.paneId
            params["_fp_occupant"] = occupantFingerprint(from: targetInfo)
            params["_fp_status"] = targetInfo.agentStatus
            params["_fp_seq"] = "\(targetInfo.stateChangeSeq)"
        } else {
            params["_fp_occupant"] = ""
            params["_fp_status"] = ""
            params["_fp_seq"] = "0"
        }

        guard let actionId = try? await sharedActionStore.create(tool: "session.spawn", params: params) else {
            return makeToolError("Failed to record spawn action (lock unavailable)")
        }

        await journal.record(JournalEntry(
            actionId: actionId, tool: "session.spawn",
            params: params.filter { !$0.key.hasPrefix("_fp_") },
            caller: "mcp", preState: "placement=\(placement)", outcome: "pending_confirmation",
            keepForever: true
        ))

        // Poll for approval from menu-bar UI
        let finalState = await waitForConfirmation(actionId: actionId)

        if finalState == .approved {
            // Atomic claim gate
            guard let claimed = try? await sharedActionStore.claimExecuting(actionId: actionId) else {
                try? await sharedActionStore.markFailed(actionId, detail: "action no longer claimable")
                return makeToolError("Action no longer claimable (actionId: \(actionId))")
            }

            do {
                try await ensureConnected()
                let paneId: String
                let finalWorkspaceId: String
                var tabId: String?

                switch placement {
                case "new_workspace":
                    guard let resolvedPath else {
                        throw AgentResolutionError(description: "resolved repo path missing")
                    }
                    let creation = try await adapter.createWorkspace(
                        cwd: resolvedPath,
                        label: spaceLabel
                    )
                    finalWorkspaceId = creation.workspaceId
                    tabId = creation.tabId
                    paneId = creation.rootPaneId

                case "new_tab":
                    guard let workspaceId else {
                        throw AgentResolutionError(description: "workspace ID missing")
                    }
                    let freshHerd = try await adapter.herdSnapshot()
                    guard freshHerd.workspaceNames[workspaceId] != nil else {
                        throw AgentResolutionError(description: "workspace disappeared before execution")
                    }
                    let creation = try await adapter.createTab(
                        workspaceId: workspaceId,
                        cwd: cwdHint,
                        label: kind.capitalized,
                        focus: true
                    )
                    finalWorkspaceId = workspaceId
                    tabId = creation.tabId
                    paneId = creation.rootPaneId

                case "split":
                    guard let targetInfo else {
                        throw AgentResolutionError(description: "split target missing")
                    }
                    try await revalidate(action: claimed, paneId: targetInfo.paneId)
                    finalWorkspaceId = targetInfo.workspaceId
                    paneId = try await adapter.splitPane(
                        targetPaneId: targetInfo.paneId,
                        cwd: cwdHint
                    )

                default:
                    throw AgentResolutionError(description: "invalid placement")
                }

                try await adapter.startAgent(paneId: paneId, kind: kind, name: name)

                if let brief, !brief.isEmpty {
                    try await adapter.prompt(paneId: paneId, text: brief)
                }

                await policy.recordWrite(agentId: paneId)
                try? await sharedActionStore.markExecuted(actionId)

                await journal.record(JournalEntry(
                    actionId: actionId, tool: "session.spawn",
                    params: [
                        "placement": placement,
                        "kind": kind,
                        "name": name,
                        "workspace_id": finalWorkspaceId,
                        "pane_id": paneId
                    ],
                    caller: "mcp", preState: "placement=\(placement)",
                    postState: "started", outcome: "executed",
                    keepForever: true
                ))
                var result = "{\"agentId\":\"\(paneId)\",\"space\":\"\(finalWorkspaceId)\",\"placement\":\"\(placement)\""
                if let tabId { result += ",\"tab\":\"\(tabId)\"" }
                result += ",\"started\":true,\"actionId\":\"\(actionId)\"}"
                return makeToolResult(result)
            } catch {
                try? await sharedActionStore.markFailed(actionId, detail: error.localizedDescription)
                return makeToolError("session.spawn execution failed: \(error.localizedDescription)")
            }
        } else if finalState == .denied {
            await journal.record(JournalEntry(
                actionId: actionId, tool: "session.spawn",
                params: ["placement": placement],
                caller: "mcp", preState: "placement=\(placement)", outcome: "denied",
                keepForever: true
            ))
            return makeToolError("Action denied by user (actionId: \(actionId))")
        } else {
            await journal.record(JournalEntry(
                actionId: actionId, tool: "session.spawn",
                params: ["placement": placement],
                caller: "mcp", preState: "placement=\(placement)", outcome: "expired",
                keepForever: true
            ))
            return makeToolError("Action expired (actionId: \(actionId))")
        }
    }

    // MARK: - action.status

    private func handleActionStatus(arguments: [String: Any]) async -> [String: Any] {
        guard let actionId = arguments["action_id"] as? String, !actionId.isEmpty else {
            return makeToolError("Missing required parameter: action_id")
        }

        try? await sharedActionStore.expireStale()

        if let state = await sharedActionStore.status(actionId) {
            var json = "{\"state\":\"\(state.rawValue)\""
            if let action = await sharedActionStore.get(actionId), let detail = action.failDetail {
                json += ",\"detail\":\"\(detail)\""
            }
            json += "}"
            return makeToolResult(json)
        }
        return makeToolError("Action not found: \(actionId)")
    }

    // MARK: - Confirmation Polling

    /// Poll sharedActionStore until the action is approved, denied, or expired.
    /// Returns the final ActionState, or nil if the action was not found.
    private func waitForConfirmation(actionId: String, timeoutSeconds: Int = 120) async -> ActionState? {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(2))
            try? await sharedActionStore.expireStale()
            if let state = await sharedActionStore.status(actionId) {
                switch state {
                case .approved:
                    return .approved
                case .denied:
                    return .denied
                case .expired:
                    return .expired
                case .executed, .failed:
                    return state
                case .pending, .executing:
                    continue
                }
            } else {
                return nil
            }
        }
        // Timeout — expire stale and return expired
        try? await sharedActionStore.expireStale()
        return await sharedActionStore.status(actionId) ?? .expired
    }

    // MARK: - Connection Helper

    private func ensureConnected() async throws {
        if adapter.connectionState != .connected {
            try await adapter.connect()
        }
    }

    // MARK: - Write-Gate Helper

    /// Returns a tool error dict if writes are disabled, or nil if writes are
    /// allowed. A fresh process has no protocol reading until its first
    /// snapshot, so before gating we ensure a live reading exists — otherwise
    /// the very first write would be wrongly rejected as "protocol unknown".
    private func checkWritesEnabled() async -> [String: Any]? {
        if adapter.health().protocolVersion == 0 {
            try? await ensureConnected()
            _ = try? await adapter.herdSnapshot()
        }
        let health = adapter.health()
        if !health.writesEnabled {
            return makeToolError("Writes not enabled: \(health.reason ?? "herdr protocol not verified for writes")")
        }
        return nil
    }

    // MARK: - Answer Key Mapping

    /// Map an answer choice to keystrokes, gated on the detected block kind.
    /// Returns nil when the choice is not valid for the kind (or the kind is
    /// unknown/weak), so unrecognized prompts stay read-only and we never send
    /// a global hardcoded keystroke that the detected prompt does not warrant.
    private static func keys(forChoice choice: String, index: Int?, blockKind: BlockKind) -> [String]? {
        // Weak or unknown blocks: never send input.
        switch blockKind {
        case .unknownBlock, .probableApproval:
            return nil
        default:
            break
        }

        let permissionKinds: Set<BlockKind> = [.bashPermission, .toolPermission, .approval, .workflowConfirm]
        let selectionKinds: Set<BlockKind> = [.selectionForm, .menu]

        if permissionKinds.contains(blockKind) {
            switch choice {
            case "approve": return ["enter"]
            case "accept_once": return ["down", "enter"]
            case "deny", "cancel": return ["esc"]
            default: return nil  // 'select' is meaningless on a yes/no prompt
            }
        }
        if selectionKinds.contains(blockKind) {
            switch choice {
            case "select":
                let idx = index ?? 0
                return Array(repeating: "down", count: idx) + ["enter"]
            case "approve": return ["enter"]  // accept the highlighted default
            case "cancel", "deny": return ["esc"]
            default: return nil  // 'accept_once' is meaningless on a list
            }
        }
        return nil
    }

    // MARK: - Occupant Fingerprint & Revalidation

    /// Compute a stable fingerprint for the current occupant of a pane, keyed
    /// on the NATIVE herdr agent-session identity (source|agent|kind|value) so
    /// that replacing an occupant with another agent of the same kind/name in
    /// the same pane is still detected as a change. Falls back to a
    /// kind|name|paneId form only when no agent-session identity is present.
    private func occupantFingerprint(from info: HerdrAgentInfo) -> String {
        if let session = info.agentSession {
            return "session|\(session.source)|\(session.agent)|\(session.kind)|\(session.value)|\(info.paneId)"
        }
        let kind = info.agent ?? "unknown"
        let name = info.title ?? info.name ?? info.terminalTitleStripped ?? kind
        return "fallback|\(kind)|\(name)|\(info.paneId)"
    }

    /// Revalidate that the pane still has the same occupant and status episode
    /// as when the action was created. Throws if mismatch.
    /// Reads fingerprint info from action.params["_fp_*"] keys.
    private func revalidate(action: PendingAction, paneId: String) async throws {
        let herd = try await adapter.herdSnapshot()

        guard let paneInfo = herd.agents.first(where: { $0.paneId == paneId }) else {
            throw MCPRevalidationError.paneGone(paneId)
        }

        let seq = paneInfo.stateChangeSeq

        // Compare the NATIVE occupant fingerprint (agent-session identity).
        let currentFingerprint = occupantFingerprint(from: paneInfo)
        let expectedFingerprint = action.params["_fp_occupant"]
        if let expectedFingerprint, !expectedFingerprint.isEmpty,
           expectedFingerprint != currentFingerprint {
            throw MCPRevalidationError.occupantChanged(
                expected: expectedFingerprint,
                current: currentFingerprint
            )
        }

        // Compare status episode (seq)
        let expectedSeq = action.params["_fp_seq"].flatMap { UInt64($0) }
        if let expectedSeq, expectedSeq != seq {
            throw MCPRevalidationError.seqAdvanced(
                expected: expectedSeq,
                current: seq
            )
        }

        // Compare status
        let expectedStatus = action.params["_fp_status"]
        if let expectedStatus, !expectedStatus.isEmpty,
           expectedStatus != paneInfo.agentStatus {
            throw MCPRevalidationError.statusChanged(
                expected: expectedStatus,
                current: paneInfo.agentStatus
            )
        }
    }

    // MARK: - Formatting (nonisolated — pure functions on Sendable inputs)

    nonisolated private static func formatOverview(
        agents: [Agent],
        workspaceNames: [String: String]
    ) -> String {
        guard !agents.isEmpty else {
            return "Herd Overview — 0 agents\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nNo agents found."
        }

        // Count statuses
        let blocked = agents.filter { $0.status == .blocked }.count
        let silent = agents.filter { $0.verdict.isSilent && $0.status != .blocked }.count
        let done = agents.filter { $0.status == .done }.count
        let working = agents.filter { $0.status == .working }.count
        let idle = agents.filter { $0.status == .idle }.count

        // Group by workspace
        var byWorkspace: [String: [Agent]] = [:]
        for agent in agents {
            let wsKey = agent.id.workspaceId
            byWorkspace[wsKey, default: []].append(agent)
        }

        var lines: [String] = []
        lines.append("Herd Overview — \(agents.count) agents across \(byWorkspace.count) workspace\(byWorkspace.count == 1 ? "" : "s")")
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        var statusParts: [String] = []
        if blocked > 0 { statusParts.append("🔴 \(blocked) blocked") }
        if silent > 0 { statusParts.append("🟠 \(silent) silent") }
        if done > 0 { statusParts.append("🔵 \(done) done") }
        if working > 0 { statusParts.append("🟡 \(working) working") }
        if idle > 0 { statusParts.append("🟢 \(idle) idle") }
        let unknown = agents.filter { $0.status == .unknown }.count
        if unknown > 0 { statusParts.append("⚪ \(unknown) unknown") }
        lines.append(statusParts.joined(separator: " · "))
        lines.append("")

        // Sort workspaces by name
        let sortedWs = byWorkspace.keys.sorted {
            let nameA = workspaceNames[$0] ?? $0
            let nameB = workspaceNames[$1] ?? $1
            return nameA < nameB
        }

        for wsId in sortedWs {
            let wsAgents = byWorkspace[wsId] ?? []
            let wsName = workspaceNames[wsId] ?? wsId
            lines.append("\(wsName) (\(wsId)) — \(wsAgents.count) agent\(wsAgents.count == 1 ? "" : "s")")

            // Sort: blocked first, then done, then silent, then working, then idle
            let sorted = wsAgents.sorted { a, b in
                statusPriority(a) < statusPriority(b)
            }

            for agent in sorted {
                let glyph = statusGlyph(agent)
                let verdictHint = agent.verdict.summaryLine ?? agent.status.rawValue
                lines.append("  \(glyph) \(agent.name) [\(agent.id.paneId)] — \(verdictHint)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    nonisolated private static func formatAgentList(
        agents: [Agent],
        workspaceNames: [String: String]
    ) -> String {
        guard !agents.isEmpty else {
            return "No agents found."
        }

        var lines: [String] = []
        lines.append(pad("Status", 8) + " " + pad("Name", 20) + " " + pad("Kind", 10) + " " + pad("Workspace", 12) + " " + pad("Pane", 8) + " Verdict")
        lines.append(String(repeating: "─", count: 90))

        let sorted = agents.sorted { statusPriority($0) < statusPriority($1) }
        for agent in sorted {
            let glyph = statusGlyph(agent)
            let kindStr = agentKindString(agent.kind)
            let wsName = workspaceNames[agent.id.workspaceId] ?? agent.id.workspaceId
            let verdictStr = agent.verdict.summaryLine ?? agent.status.rawValue

            lines.append(pad(glyph, 8) + " " + pad(truncate(agent.name, 20), 20) + " " + pad(truncate(kindStr, 10), 10) + " " + pad(truncate(wsName, 12), 12) + " " + pad(truncate(agent.id.paneId, 8), 8) + " " + truncate(verdictStr, 40))
        }

        lines.append("")
        lines.append("Total: \(agents.count) agent\(agents.count == 1 ? "" : "s")")
        return lines.joined(separator: "\n")
    }

    nonisolated private static func formatInspect(
        info: HerdrAgentInfo,
        verdict: Verdict,
        explain: AgentExplainResult?,
        procInfo: ProcessInfoResult?,
        recentOutput: String?,
        workspaceNames: [String: String],
        tabNames: [String: String]
    ) -> String {
        var lines: [String] = []
        let agentId = AgentID(info.paneId)
        let wsName = workspaceNames[info.workspaceId] ?? info.workspaceId
        let tabName = tabNames[info.tabId] ?? info.tabId
        let title = info.title
            ?? info.name
            ?? info.terminalTitleStripped
            ?? info.displayAgent
            ?? info.agent
            ?? "unknown"

        lines.append("Agent: \(title) (\(agentId.raw))")
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        lines.append("Workspace: \(wsName) (\(info.workspaceId))")
        lines.append("Tab: \(tabName) (\(info.tabId))")
        lines.append("Status: \(info.agentStatus)")
        lines.append("State sequence: \(info.stateChangeSeq)")
        lines.append("Focused: \(info.focused ? "yes" : "no")")
        lines.append("Interactive ready: \(info.interactiveReady ? "yes" : "no")")
        if info.launchPending {
            lines.append("Launch pending: yes")
        }
        if let session = info.agentSession {
            lines.append("Kind: \(session.agent) (source: \(session.source))")
        } else if let agent = info.agent {
            lines.append("Kind: \(agent)")
        }
        if let cwd = info.cwd {
            lines.append("CWD: \(cwd)")
        }
        if let foregroundCwd = info.foregroundCwd, foregroundCwd != info.cwd {
            lines.append("Foreground CWD: \(foregroundCwd)")
        }
        if !info.stateLabels.isEmpty {
            let labels = info.stateLabels.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            lines.append("State labels: \(labels)")
        }
        lines.append("")

        // Verdict
        lines.append("Diagnosis:")
        lines.append("  Verdict: \(verdictName(verdict))")
        if let summary = verdict.summaryLine {
            lines.append("  \(summary)")
        }
        lines.append("")

        // Explain
        if let explain {
            lines.append("Explain:")
            if let agent = explain.agent { lines.append("  Agent: \(agent)") }
            if let state = explain.state { lines.append("  State: \(state)") }
            if let ruleId = explain.matchedRuleId {
                var ruleStr = "  Matched rule: \(ruleId)"
                if let priority = explain.matchedRulePriority {
                    ruleStr += " (priority \(priority))"
                }
                lines.append(ruleStr)
            }
            lines.append("  Screen detection skipped: \(explain.screenDetectionSkipped)")
            lines.append("")
        }

        // Process info
        if let procInfo {
            lines.append("Process Info:")
            if let pid = procInfo.shellPid {
                lines.append("  Shell PID: \(pid)")
            }
            if procInfo.foregroundProcesses.isEmpty {
                lines.append("  Foreground processes: (none)")
            } else {
                lines.append("  Foreground processes:")
                for proc in procInfo.foregroundProcesses {
                    var procLine = "    PID \(proc.pid): \(proc.name)"
                    if let cmdline = proc.cmdline, !cmdline.isEmpty {
                        procLine += " — \(truncate(cmdline, 60))"
                    }
                    lines.append(procLine)
                }
            }
            lines.append("")
        }

        // Recent output (last 10 lines)
        if let output = recentOutput, !output.isEmpty {
            lines.append("Recent Output (last 10 lines):")
            let outputLines = output.split(separator: "\n", omittingEmptySubsequences: false)
            let last10 = outputLines.suffix(10)
            for line in last10 {
                lines.append("  | \(line)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    nonisolated private static func formatDiagnosis(
        agent: Agent,
        verdict: Verdict,
        explain: AgentExplainResult?,
        procInfo: ProcessInfoResult?
    ) -> String {
        var lines: [String] = []

        lines.append("Diagnosis: \(agent.id.raw) (\(agent.name))")
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        switch verdict {
        case .healthy:
            lines.append("Verdict: HEALTHY")
            lines.append("Confidence: high")
            lines.append("")
            lines.append("Suggested actions:")
            lines.append("  - No action needed")

        case .awaitingInput(let classification):
            lines.append("Verdict: AWAITING INPUT")
            let ruleInfo: String
            if let explain, let ruleId = explain.matchedRuleId {
                var info = "matched rule: \(ruleId)"
                if let priority = explain.matchedRulePriority {
                    info += ", priority \(priority)"
                }
                ruleInfo = info
            } else {
                ruleInfo = "block detected"
            }
            let elapsed = formatElapsed(since: classification.since)
            lines.append("Confidence: high (\(ruleInfo))")
            lines.append("Waiting on: \(classification.summary)")
            lines.append("Since: \(elapsed) ago")

            lines.append("Evidence:")
            lines.append("  - Status: \(agent.status.rawValue) (from herdr)")
            if let explain, let ruleId = explain.matchedRuleId {
                lines.append("  - Matched rule: \(ruleId)\(explain.matchedRulePriority.map { " (priority \($0))" } ?? "")")
            }
            if let explain {
                lines.append("  - Screen detection: \(explain.screenDetectionSkipped ? "skipped" : "active")")
            }

            lines.append("Suggested actions:")
            lines.append("  - agent.answer: respond to the prompt")
            lines.append("  - agent.say: provide alternative instructions")
            lines.append("  - agent.interrupt: if the agent is stuck")

        case .silent(let since, let cpu):
            let elapsed = formatElapsed(since: since)
            lines.append("Verdict: SILENT")

            var confParts: [String] = []
            confParts.append("heuristic: no output for \(elapsed) while status=\(agent.status.rawValue)")
            lines.append("Confidence: medium (\(confParts.joined(separator: ", ")))")

            if let cpu {
                switch cpu {
                case .thinking: lines.append("CPU: thinking (high CPU usage)")
                case .deadlocked: lines.append("CPU: deadlocked (near-zero CPU)")
                case .ioWait: lines.append("CPU: I/O wait")
                case .unknown: break
                }
            }

            lines.append("Evidence:")
            lines.append("  - Status: \(agent.status.rawValue)")
            lines.append("  - No output for \(elapsed)")
            if let lastOutput = agent.lastOutputAt {
                lines.append("  - Last output: \(formatElapsed(since: lastOutput)) ago")
            }

            lines.append("Suggested actions:")
            if cpu == .thinking {
                lines.append("  - Wait (agent appears to be thinking)")
                lines.append("  - agent.interrupt: if you believe it's stuck")
            } else if cpu == .deadlocked {
                lines.append("  - agent.interrupt: agent appears deadlocked")
                lines.append("  - agent.answer: check if there's a hidden prompt")
            } else {
                lines.append("  - Wait and check again later")
                lines.append("  - agent.interrupt: if silence is unexpected")
                lines.append("  - agent.tail: check recent output")
            }

        case .processGone(let lastLine):
            lines.append("Verdict: PROCESS GONE")
            lines.append("Confidence: high (no agent process in foreground)")

            lines.append("Evidence:")
            lines.append("  - Status: \(agent.status.rawValue) (non-idle)")
            lines.append("  - No agent process detected in pane foreground")
            if let lastLine {
                lines.append("  - Last foreground: \(lastLine)")
            }

            lines.append("Suggested actions:")
            lines.append("  - agent.stop: clean up the dead pane")
            lines.append("  - session.spawn: start a new agent")

        case .unclassifiable(let reason):
            lines.append("Verdict: UNCLASSIFIABLE")
            lines.append("Confidence: low")
            lines.append("Reason: \(reason)")
            lines.append("")
            lines.append("Suggested actions:")
            lines.append("  - agent.tail: check recent output manually")
            lines.append("  - agent.inspect: get full details")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting Helpers

    nonisolated private static func statusGlyph(_ agent: Agent) -> String {
        switch agent.status {
        case .blocked: return "🔴"
        case .done: return "🔵"
        case .working:
            if agent.verdict.isSilent { return "🟠" }
            return "🟡"
        case .idle: return "🟢"
        case .unknown: return "⚪"
        }
    }

    nonisolated private static func statusPriority(_ agent: Agent) -> Int {
        switch agent.status {
        case .blocked: return 0
        case .done: return 1
        case .working:
            if agent.verdict.isSilent { return 2 }
            return 4
        case .idle: return 5
        case .unknown: return 6
        }
    }

    nonisolated private static func verdictName(_ verdict: Verdict) -> String {
        switch verdict {
        case .healthy: return "HEALTHY"
        case .awaitingInput: return "AWAITING INPUT"
        case .silent: return "SILENT"
        case .processGone: return "PROCESS GONE"
        case .unclassifiable: return "UNCLASSIFIABLE"
        }
    }

    nonisolated private static func agentKindString(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        case .aider: return "aider"
        case .gemini: return "gemini"
        case .custom(let s): return s
        }
    }

    nonisolated private static func formatDwell(enteredAt: Date) -> String {
        formatElapsed(since: enteredAt)
    }

    nonisolated private static func formatElapsed(since date: Date) -> String {
        let totalSeconds = Int(Date().timeIntervalSince(date))
        guard totalSeconds > 0 else { return "0s" }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "\(totalSeconds)s"
        }
    }

    nonisolated private static func truncate(_ s: String, _ maxLen: Int) -> String {
        if s.count <= maxLen { return s }
        return String(s.prefix(maxLen - 1)) + "…"
    }

    nonisolated private static func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }

    // MARK: - JSON-RPC Response Builders

    nonisolated private func writeResponse(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let line = String(data: data, encoding: .utf8) else { return }
        writeRaw(line)
    }

    nonisolated private func writeRaw(_ line: String) {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        if let data = (line + "\n").data(using: .utf8) {
            FileHandle.standardOutput.write(data)
            fflush(stdout)
        }
    }

    // MARK: - Tool Definitions

    nonisolated(unsafe) static let toolDefinitions: [[String: Any]] = [
        [
            "name": "herd.overview",
            "description": "Overview of all AI agents in the herdr multiplexer, grouped by workspace. Shows counts by status and which agents need attention.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any]()
            ] as [String: Any]
        ] as [String: Any],
        [
            "name": "agent.list",
            "description": "List all agents with their current status. Optionally filter by status or workspace.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "status": [
                        "type": "string",
                        "enum": ["blocked", "working", "idle", "done", "unknown"],
                        "description": "Filter by agent status"
                    ],
                    "workspace": [
                        "type": "string",
                        "description": "Filter by workspace name or ID (substring match)"
                    ],
                    "query": [
                        "type": "string",
                        "description": "Filter by human-facing agent title/name, kind, workspace, tab, cwd, or pane ID"
                    ]
                ] as [String: Any]
            ] as [String: Any]
        ] as [String: Any],
        [
            "name": "agent.inspect",
            "description": "Detailed status for one agent, including location, terminal output, process info, and diagnosis. Pass an exact agent_id or a human query; a query must resolve uniquely.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "agent_id": [
                        "type": "string",
                        "description": "Agent ID in workspace:pane format (e.g. 'w5:p2')"
                    ],
                    "query": [
                        "type": "string",
                        "description": "Human-facing title/name, workspace, tab, cwd, kind, or pane ID; must match exactly one agent"
                    ]
                ] as [String: Any]
            ] as [String: Any]
        ] as [String: Any],
        [
            "name": "agent.tail",
            "description": "Read the last N lines of one agent's terminal output. Pass agent_id or a unique human query. The read is bounded at the source and secret-scrubbed.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "agent_id": [
                        "type": "string",
                        "description": "Agent ID in workspace:pane format (e.g. 'w5:p2')"
                    ],
                    "query": [
                        "type": "string",
                        "description": "Human-facing title/name, workspace, tab, cwd, kind, or pane ID; must match exactly one agent"
                    ],
                    "lines": [
                        "type": "integer",
                        "description": "Number of lines to return (default 50, max 200)",
                        "default": 50
                    ],
                    "source": [
                        "type": "string",
                        "enum": ["visible", "recent", "recent_unwrapped", "detection"],
                        "description": "Pane read source (default: detection)",
                        "default": "detection"
                    ]
                ] as [String: Any]
            ] as [String: Any]
        ] as [String: Any],
        [
            "name": "agent.diagnose",
            "description": "Run full stuck-diagnosis on one agent. Pass agent_id or a unique human query. Returns verdict, confidence, what it is waiting on, evidence, and suggested actions.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "agent_id": [
                        "type": "string",
                        "description": "Agent ID in workspace:pane format (e.g. 'w5:p2')"
                    ],
                    "query": [
                        "type": "string",
                        "description": "Human-facing title/name, workspace, tab, cwd, kind, or pane ID; must match exactly one agent"
                    ]
                ] as [String: Any]
            ] as [String: Any]
        ] as [String: Any],
        // MARK: Write Tools
        [
            "name": "agent.answer",
            "description": "Reply to a blocked agent's prompt with a bounded choice. Requires status=blocked. Maps choice to key sequences: approve→enter, deny→esc, accept_once→down+enter, select→arrows+enter, cancel→esc. Max 3 consecutive answers without status change.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "agent_id": [
                        "type": "string",
                        "description": "Agent ID in workspace:pane format (e.g. 'w5:p2')"
                    ],
                    "choice": [
                        "type": "string",
                        "enum": ["approve", "deny", "accept_once", "select", "cancel"],
                        "description": "Bounded choice to send"
                    ],
                    "index": [
                        "type": "integer",
                        "description": "Menu index for 'select' choice (0-based, must be 0...20)"
                    ],
                    "state_change_seq": [
                        "type": "integer",
                        "description": "REQUIRED: state_change_seq from diagnosis. Rejects stale answers if seq has advanced."
                    ]
                ] as [String: Any],
                "required": ["agent_id", "choice", "state_change_seq"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "name": "agent.say",
            "description": "Send free-text prompt to an agent via agent.prompt (atomic, bracketed-paste aware). Auto-allowed when idle/done; requires confirmation when working/blocked. Max 2000 chars.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "agent_id": [
                        "type": "string",
                        "description": "Agent ID in workspace:pane format (e.g. 'w5:p2')"
                    ],
                    "text": [
                        "type": "string",
                        "description": "Text to send (max 2000 characters)"
                    ],
                    "wait_for": [
                        "type": "string",
                        "enum": ["idle", "done", "blocked"],
                        "description": "Optional: wait for agent to reach this status"
                    ],
                    "timeout_ms": [
                        "type": "integer",
                        "description": "Timeout for wait_for in milliseconds (default 30000)"
                    ]
                ] as [String: Any],
                "required": ["agent_id", "text"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "name": "agent.interrupt",
            "description": "Interrupt a running agent. escape sends Esc, sigint sends Ctrl+C. Always requires confirmation.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "agent_id": [
                        "type": "string",
                        "description": "Agent ID in workspace:pane format (e.g. 'w5:p2')"
                    ],
                    "level": [
                        "type": "string",
                        "enum": ["escape", "sigint"],
                        "description": "Interrupt level (default: escape)"
                    ]
                ] as [String: Any],
                "required": ["agent_id"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "name": "agent.stop",
            "description": "Close an agent's pane. Always requires confirmation. Never accepts a list — one confirmation per agent.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "agent_id": [
                        "type": "string",
                        "description": "Agent ID in workspace:pane format (e.g. 'w5:p2')"
                    ],
                    "reason": [
                        "type": "string",
                        "description": "Reason for stopping (recorded in journal)"
                    ]
                ] as [String: Any],
                "required": ["agent_id"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "name": "session.spawn",
            "description": "Start an agent in a new workspace, a new tab in an existing workspace, or a split beside an existing agent. Always requires confirmation. Use placement=new_workspace with repo_path, new_tab with workspace_id, or split with target_agent_id.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "placement": [
                        "type": "string",
                        "enum": ["new_workspace", "new_tab", "split"],
                        "description": "Where to start the agent (default: new_workspace)",
                        "default": "new_workspace"
                    ],
                    "repo_path": [
                        "type": "string",
                        "description": "Absolute repository path; required for new_workspace and restricted to allowed roots"
                    ],
                    "workspace_id": [
                        "type": "string",
                        "description": "Existing workspace ID; required for new_tab"
                    ],
                    "target_agent_id": [
                        "type": "string",
                        "description": "Exact existing agent ID to split beside; required for split"
                    ],
                    "kind": [
                        "type": "string",
                        "description": "Agent kind (e.g. 'claude', 'codex', 'opencode')"
                    ],
                    "name": [
                        "type": "string",
                        "description": "Name for the agent session"
                    ],
                    "brief": [
                        "type": "string",
                        "description": "Optional initial prompt to send after starting"
                    ],
                    "space_label": [
                        "type": "string",
                        "description": "Optional label for the workspace"
                    ]
                ] as [String: Any],
                "required": ["kind", "name"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "name": "action.status",
            "description": "Check the status of a pending confirmation action. Returns state: pending, approved, denied, expired, executed, or failed.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action_id": [
                        "type": "string",
                        "description": "Action ID returned by a write tool (e.g. 'a_7f31')"
                    ]
                ] as [String: Any],
                "required": ["action_id"]
            ] as [String: Any]
        ] as [String: Any],
    ]
}

// MARK: - JSON-RPC Helpers (free functions, nonisolated)

private func makeResult(id: Any, result: [String: Any]) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "result": result
    ]
}

private func makeError(id: Any, code: Int, message: String) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "error": [
            "code": code,
            "message": message
        ]
    ]
}

private func makeToolResult(_ text: String) -> [String: Any] {
    [
        "content": [
            [
                "type": "text",
                "text": text
            ]
        ]
    ]
}

private func makeToolError(_ message: String) -> [String: Any] {
    [
        "content": [
            [
                "type": "text",
                "text": message
            ]
        ],
        "isError": true
    ]
}
