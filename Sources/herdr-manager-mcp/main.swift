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
        let configHome: String
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configHome = xdg
        } else if let home = ProcessInfo.processInfo.environment["HOME"] {
            configHome = home + "/.config"
        } else {
            configHome = "/tmp"
        }
        let socketPath = configHome + "/herdr/herdr.sock"

        let adapter = LiveHerdrAdapter(socketPath: socketPath)
        let server = MCPServer(adapter: adapter)
        await server.run()
    }
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

        // Process each JSON-RPC line
        for await line in stream {
            await handleLine(line)
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

    // MARK: - Snapshot → Agent Builder

    /// Build agents dictionary from a snapshot (mirrors AgentStore.applySnapshot logic).
    private func buildAgents(from snapshot: HerdrSnapshot) -> [AgentID: Agent] {
        let wsMap = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceId, $0.name) })
        let tabMap = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.tabId, $0.name) })
        var agents: [AgentID: Agent] = [:]

        for pane in snapshot.panes {
            guard pane.agent != nil || pane.agentStatus != "unknown" else { continue }

            let agentId = AgentID(pane.paneId)
            let status = AgentStatus(rawValue: pane.agentStatus) ?? .unknown
            let wsName = wsMap[pane.workspaceId] ?? ""
            let tabName = tabMap[pane.tabId] ?? ""

            let kind: AgentKind
            if let session = pane.agentSession {
                kind = AgentKind.custom(session.agent)
            } else if let agentName = pane.agent {
                kind = AgentKind.custom(agentName)
            } else {
                kind = .custom("unknown")
            }

            let name = pane.agent ?? pane.terminalTitleStripped ?? ""
            let enteredAt = Date()

            let agent = Agent(
                id: agentId,
                kind: kind,
                name: name,
                displayName: name,
                status: status,
                stateChangeSeq: pane.stateChangeSeq ?? 0,
                enteredAt: enteredAt,
                lastOutputAt: nil,
                verdict: Self.initialVerdict(for: status),
                workspaceName: wsName,
                tabName: tabName
            )
            agents[agentId] = agent
        }

        return agents
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
            let snapshot = try await adapter.snapshot()
            var agents = buildAgents(from: snapshot)
            let wsMap = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceId, $0.name) })

            // Diagnose non-idle agents
            for agent in agents.values where agent.status != .idle {
                let verdict = await diagnoser.diagnose(agent: agent, adapter: adapter)
                if var current = agents[agent.id] {
                    current.verdict = verdict
                    agents[agent.id] = current
                }
            }

            let text = Self.formatOverview(agents: Array(agents.values), workspaceNames: wsMap)
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
            let snapshot = try await adapter.snapshot()
            var agents = buildAgents(from: snapshot)
            let wsMap = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceId, $0.name) })

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
                    let wsName = wsMap[agent.id.workspaceId] ?? agent.id.workspaceId
                    return wsName.lowercased().contains(workspace.lowercased()) ||
                           agent.id.workspaceId.lowercased().contains(workspace.lowercased())
                }
            }

            let text = Self.formatAgentList(agents: agentList, workspaceNames: wsMap)
            let redacted = redactor.redact(text)
            return makeToolResult(redacted.redactedText)
        } catch {
            return makeToolError("Failed to list agents: \(error.localizedDescription)")
        }
    }

    // MARK: - agent.inspect

    private func handleAgentInspect(arguments: [String: Any]) async -> [String: Any] {
        guard let agentIdStr = arguments["agent_id"] as? String, !agentIdStr.isEmpty else {
            return makeToolError("Missing required parameter: agent_id")
        }

        let (allowed, retry) = await rateLimiter.check(agentId: agentIdStr)
        guard allowed else {
            return makeToolError("Rate limit exceeded. Try again in \(retry) seconds.")
        }

        do {
            try await ensureConnected()
            let snapshot = try await adapter.snapshot()
            var agents = buildAgents(from: snapshot)
            let wsMap = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceId, $0.name) })

            let agentId = AgentID(agentIdStr)
            let paneId = agentIdStr  // herdr uses full session-qualified IDs (e.g. "w5:p2")

            // Find agent in snapshot
            guard let paneInfo = snapshot.panes.first(where: { $0.paneId == paneId }) else {
                return makeToolError("Agent not found: \(agentIdStr)")
            }

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
                paneInfo: paneInfo,
                verdict: verdict,
                explain: explain,
                procInfo: procInfo,
                recentOutput: readResult?.text,
                workspaceNames: wsMap
            )
            let redacted = redactor.redact(text)
            return makeToolResult(redacted.redactedText)
        } catch {
            return makeToolError("Failed to inspect agent: \(error.localizedDescription)")
        }
    }

    // MARK: - agent.tail

    private func handleAgentTail(arguments: [String: Any]) async -> [String: Any] {
        guard let agentIdStr = arguments["agent_id"] as? String, !agentIdStr.isEmpty else {
            return makeToolError("Missing required parameter: agent_id")
        }

        let (allowed, retry) = await rateLimiter.check(agentId: agentIdStr)
        guard allowed else {
            return makeToolError("Rate limit exceeded. Try again in \(retry) seconds.")
        }

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

            // Verify agent exists
            let snapshot = try await adapter.snapshot()
            let agentId = AgentID(agentIdStr)
            let paneId = agentIdStr  // herdr uses full session-qualified IDs
            guard snapshot.panes.contains(where: { $0.paneId == paneId }) else {
                return makeToolError("Agent not found: \(agentIdStr)")
            }

            let result = try await adapter.read(paneId: paneId, source: source)
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
        guard let agentIdStr = arguments["agent_id"] as? String, !agentIdStr.isEmpty else {
            return makeToolError("Missing required parameter: agent_id")
        }

        let (allowed, retry) = await rateLimiter.check(agentId: agentIdStr)
        guard allowed else {
            return makeToolError("Rate limit exceeded. Try again in \(retry) seconds.")
        }

        do {
            try await ensureConnected()
            let snapshot = try await adapter.snapshot()
            let agents = buildAgents(from: snapshot)

            let agentId = AgentID(agentIdStr)
            guard let agent = agents[agentId] else {
                return makeToolError("Agent not found: \(agentIdStr)")
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

        if choice == "select" {
            guard arguments["index"] is Int else {
                return makeToolError("choice 'select' requires an 'index' parameter (integer)")
            }
        }

        do {
            try await ensureConnected()
            let snapshot = try await adapter.snapshot()
            let paneId = agentIdStr

            guard let paneInfo = snapshot.panes.first(where: { $0.paneId == paneId }) else {
                return makeToolError("Agent not found: \(agentIdStr)")
            }

            guard paneInfo.agentStatus == "blocked" else {
                return makeToolError("Agent \(agentIdStr) is not blocked (status: \(paneInfo.agentStatus)). agent.answer requires status=blocked.")
            }

            // Verify state_change_seq if provided
            if let providedSeq = arguments["state_change_seq"] as? Int {
                let currentSeq = paneInfo.stateChangeSeq ?? 0
                if UInt64(providedSeq) != currentSeq {
                    return makeToolError("Stale state_change_seq: provided \(providedSeq), current \(currentSeq). Re-diagnose and retry.")
                }
            }

            // Check policy
            let policyResult = await policy.checkWriteAllowed(agentId: agentIdStr, tier: .gated)
            guard policyResult.allowed else {
                return makeToolError("Policy denied: \(policyResult.reason ?? "unknown")")
            }

            // Map choice to keys
            let resolvedKeys: [String]
            switch choice {
            case "approve": resolvedKeys = ["enter"]
            case "deny": resolvedKeys = ["esc"]
            case "accept_once": resolvedKeys = ["down", "enter"]
            case "select":
                let index = arguments["index"] as? Int ?? 0
                resolvedKeys = Array(repeating: "down", count: index) + ["enter"]
            case "cancel": resolvedKeys = ["esc"]
            default: resolvedKeys = ["esc"]
            }

            try await adapter.sendKeys(paneId: paneId, keys: resolvedKeys)

            await policy.recordWrite(agentId: agentIdStr)
            await policy.recordAnswer(agentId: agentIdStr)

            let actionId = await actionStore.create(tool: "agent.answer", params: [
                "agent_id": agentIdStr, "choice": choice
            ])
            await actionStore.markExecuted(actionId)

            await journal.record(JournalEntry(
                actionId: actionId,
                tool: "agent.answer",
                params: ["agent_id": agentIdStr, "choice": choice, "keys": resolvedKeys.joined(separator: ",")],
                caller: "mcp",
                preState: "status=blocked, seq=\(paneInfo.stateChangeSeq ?? 0)",
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
            let snapshot = try await adapter.snapshot()
            let paneId = agentIdStr

            guard let paneInfo = snapshot.panes.first(where: { $0.paneId == paneId }) else {
                return makeToolError("Agent not found: \(agentIdStr)")
            }

            let status = paneInfo.agentStatus
            let tier: AuthorityTier = (status == "idle" || status == "done") ? .gated : .confirm

            let policyResult = await policy.checkWriteAllowed(agentId: agentIdStr, tier: tier)
            guard policyResult.allowed else {
                return makeToolError("Policy denied: \(policyResult.reason ?? "unknown")")
            }

            // Confirm tier: create pending action and wait for UI approval
            if case .confirm = tier {
                let actionId = await sharedActionStore.create(tool: "agent.say", params: [
                    "agent_id": agentIdStr, "text": String(text.prefix(100))
                ])

                await journal.record(JournalEntry(
                    actionId: actionId, tool: "agent.say",
                    params: ["agent_id": agentIdStr, "text_length": "\(text.count)"],
                    caller: "mcp", preState: "status=\(status), seq=\(paneInfo.stateChangeSeq ?? 0)",
                    outcome: "pending_confirmation"
                ))

                // Poll for approval from menu-bar UI
                let finalState = await waitForConfirmation(actionId: actionId)

                if finalState == .approved {
                    try await adapter.prompt(paneId: paneId, text: text)
                    await policy.recordWrite(agentId: agentIdStr)
                    await sharedActionStore.markExecuted(actionId)

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

            let actionId = await actionStore.create(tool: "agent.say", params: [
                "agent_id": agentIdStr, "text": String(text.prefix(100))
            ])
            await actionStore.markExecuted(actionId)

            await journal.record(JournalEntry(
                actionId: actionId, tool: "agent.say",
                params: ["agent_id": agentIdStr, "text_length": "\(text.count)"],
                caller: "mcp", preState: "status=\(status), seq=\(paneInfo.stateChangeSeq ?? 0)",
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
        guard let agentIdStr = arguments["agent_id"] as? String, !agentIdStr.isEmpty else {
            return makeToolError("Missing required parameter: agent_id")
        }
        let level = arguments["level"] as? String ?? "escape"
        guard level == "escape" || level == "sigint" else {
            return makeToolError("Invalid level '\(level)'. Must be 'escape' or 'sigint'.")
        }

        do {
            try await ensureConnected()
            let snapshot = try await adapter.snapshot()
            let paneId = agentIdStr

            guard let paneInfo = snapshot.panes.first(where: { $0.paneId == paneId }) else {
                return makeToolError("Agent not found: \(agentIdStr)")
            }

            let actionId = await sharedActionStore.create(tool: "agent.interrupt", params: [
                "agent_id": agentIdStr, "level": level
            ])

            await journal.record(JournalEntry(
                actionId: actionId, tool: "agent.interrupt",
                params: ["agent_id": agentIdStr, "level": level],
                caller: "mcp", preState: "status=\(paneInfo.agentStatus), seq=\(paneInfo.stateChangeSeq ?? 0)",
                outcome: "pending_confirmation"
            ))

            // Poll for approval from menu-bar UI
            let finalState = await waitForConfirmation(actionId: actionId)

            if finalState == .approved {
                let keys: [String] = level == "escape" ? ["esc"] : ["ctrl+c"]
                try await adapter.sendKeys(paneId: paneId, keys: keys)
                await policy.recordWrite(agentId: agentIdStr)
                await sharedActionStore.markExecuted(actionId)

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
        guard let agentIdStr = arguments["agent_id"] as? String, !agentIdStr.isEmpty else {
            return makeToolError("Missing required parameter: agent_id")
        }
        let reason = arguments["reason"] as? String ?? "user requested"

        do {
            try await ensureConnected()
            let snapshot = try await adapter.snapshot()
            let paneId = agentIdStr

            guard let paneInfo = snapshot.panes.first(where: { $0.paneId == paneId }) else {
                return makeToolError("Agent not found: \(agentIdStr)")
            }

            let actionId = await sharedActionStore.create(tool: "agent.stop", params: [
                "agent_id": agentIdStr, "reason": reason
            ])

            await journal.record(JournalEntry(
                actionId: actionId, tool: "agent.stop",
                params: ["agent_id": agentIdStr, "reason": reason],
                caller: "mcp", preState: "status=\(paneInfo.agentStatus), seq=\(paneInfo.stateChangeSeq ?? 0)",
                outcome: "pending_confirmation",
                keepForever: true
            ))

            // Poll for approval from menu-bar UI
            let finalState = await waitForConfirmation(actionId: actionId)

            if finalState == .approved {
                try await adapter.closePane(paneId: paneId)
                await policy.recordWrite(agentId: agentIdStr)
                await sharedActionStore.markExecuted(actionId)

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
        guard let repoPath = arguments["repo_path"] as? String, !repoPath.isEmpty else {
            return makeToolError("Missing required parameter: repo_path")
        }
        guard let kind = arguments["kind"] as? String, !kind.isEmpty else {
            return makeToolError("Missing required parameter: kind")
        }
        guard let name = arguments["name"] as? String, !name.isEmpty else {
            return makeToolError("Missing required parameter: name")
        }

        // Canonicalize path
        let expandedPath = NSString(string: repoPath).expandingTildeInPath
        let canonicalPath = (expandedPath as NSString).standardizingPath

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalPath, isDirectory: &isDir), isDir.boolValue else {
            return makeToolError("repo_path does not exist or is not a directory: \(canonicalPath)")
        }

        // Validate allowlist
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let allowedRoots = [homeDir + "/Documents", homeDir + "/Developer", homeDir + "/Projects"]
        guard allowedRoots.contains(where: { canonicalPath.hasPrefix($0) }) else {
            return makeToolError("repo_path '\(canonicalPath)' is outside allowed roots: \(allowedRoots.joined(separator: ", "))")
        }

        let brief = arguments["brief"] as? String
        let spaceLabel = arguments["space_label"] as? String

        let actionId = await sharedActionStore.create(tool: "session.spawn", params: [
            "repo_path": canonicalPath, "kind": kind, "name": name
        ])

        await journal.record(JournalEntry(
            actionId: actionId, tool: "session.spawn",
            params: ["repo_path": canonicalPath, "kind": kind, "name": name],
            caller: "mcp", preState: "new_session", outcome: "pending_confirmation",
            keepForever: true
        ))

        // Poll for approval from menu-bar UI
        let finalState = await waitForConfirmation(actionId: actionId)

        if finalState == .approved {
            do {
                try await ensureConnected()
                let workspaceId = try await adapter.createWorkspace(cwd: canonicalPath, label: spaceLabel)
                let paneId = "\(workspaceId):p1"
                try await adapter.startAgent(paneId: paneId, kind: kind, name: name)

                if let brief, !brief.isEmpty {
                    try await adapter.prompt(paneId: paneId, text: brief)
                }

                await policy.recordWrite(agentId: paneId)
                await sharedActionStore.markExecuted(actionId)

                await journal.record(JournalEntry(
                    actionId: actionId, tool: "session.spawn",
                    params: ["repo_path": canonicalPath, "kind": kind, "name": name, "workspace_id": workspaceId],
                    caller: "mcp", preState: "new_session", postState: "started", outcome: "executed",
                    keepForever: true
                ))
                return makeToolResult("{\"agentId\":\"\(paneId)\",\"space\":\"\(workspaceId)\",\"started\":true,\"actionId\":\"\(actionId)\"}")
            } catch {
                await sharedActionStore.markFailed(actionId, detail: error.localizedDescription)
                return makeToolError("session.spawn execution failed: \(error.localizedDescription)")
            }
        } else if finalState == .denied {
            await journal.record(JournalEntry(
                actionId: actionId, tool: "session.spawn",
                params: ["repo_path": canonicalPath],
                caller: "mcp", preState: "new_session", outcome: "denied",
                keepForever: true
            ))
            return makeToolError("Action denied by user (actionId: \(actionId))")
        } else {
            await journal.record(JournalEntry(
                actionId: actionId, tool: "session.spawn",
                params: ["repo_path": canonicalPath],
                caller: "mcp", preState: "new_session", outcome: "expired",
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

        await sharedActionStore.expireStale()

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
            await sharedActionStore.expireStale()
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
                case .pending:
                    continue
                }
            } else {
                return nil
            }
        }
        // Timeout — expire stale and return expired
        await sharedActionStore.expireStale()
        return await sharedActionStore.status(actionId) ?? .expired
    }

    // MARK: - Connection Helper

    private func ensureConnected() async throws {
        if adapter.connectionState != .connected {
            try await adapter.connect()
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
        paneInfo: HerdrSnapshot.PaneInfo,
        verdict: Verdict,
        explain: AgentExplainResult?,
        procInfo: ProcessInfoResult?,
        recentOutput: String?,
        workspaceNames: [String: String]
    ) -> String {
        var lines: [String] = []
        let agentId = AgentID(paneInfo.paneId)
        let wsName = workspaceNames[paneInfo.workspaceId] ?? paneInfo.workspaceId

        lines.append("Agent: \(paneInfo.agent ?? "unknown") (\(agentId.raw))")
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        lines.append("Workspace: \(wsName)")
        lines.append("Status: \(paneInfo.agentStatus)")
        if let session = paneInfo.agentSession {
            lines.append("Kind: \(session.agent) (source: \(session.source))")
        }
        if let cwd = paneInfo.cwd {
            lines.append("CWD: \(cwd)")
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
                    ]
                ] as [String: Any]
            ] as [String: Any]
        ] as [String: Any],
        [
            "name": "agent.inspect",
            "description": "Detailed information about a specific agent, including its terminal output, process info, and diagnosis.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "agent_id": [
                        "type": "string",
                        "description": "Agent ID in workspace:pane format (e.g. 'w5:p2')"
                    ]
                ] as [String: Any],
                "required": ["agent_id"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "name": "agent.tail",
            "description": "Read the last N lines of an agent's terminal output. Output is secret-scrubbed. Default source is 'detection' (same bytes herdr classifies on).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "agent_id": [
                        "type": "string",
                        "description": "Agent ID in workspace:pane format (e.g. 'w5:p2')"
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
                ] as [String: Any],
                "required": ["agent_id"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "name": "agent.diagnose",
            "description": "Run full stuck-diagnosis on an agent. Returns verdict, confidence, what it's waiting on, evidence, and suggested actions. This is THE product — the answer to 'is this agent stuck and why?'",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "agent_id": [
                        "type": "string",
                        "description": "Agent ID in workspace:pane format (e.g. 'w5:p2')"
                    ]
                ] as [String: Any],
                "required": ["agent_id"]
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
                        "description": "Menu index for 'select' choice (0-based)"
                    ],
                    "state_change_seq": [
                        "type": "integer",
                        "description": "Expected state_change_seq from diagnosis (rejects stale answers)"
                    ]
                ] as [String: Any],
                "required": ["agent_id", "choice"]
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
            "description": "Spawn a new agent session in a repository. Creates workspace, starts agent, optionally sends initial brief. Requires confirmation. repo_path must be under allowed roots (~/Documents, ~/Developer, ~/Projects).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "repo_path": [
                        "type": "string",
                        "description": "Absolute path to the repository"
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
                "required": ["repo_path", "kind", "name"]
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
