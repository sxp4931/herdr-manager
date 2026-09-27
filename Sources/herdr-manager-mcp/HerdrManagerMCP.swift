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

private enum MCPRevalidationError: Error, CustomStringConvertible, LocalizedError {
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

    var errorDescription: String? { description }
}

private struct AgentResolutionError: Error, CustomStringConvertible, LocalizedError {
    let description: String
    var errorDescription: String? { description }
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

    /// Capture ids for herd reads and write-gate refreshes. Taken before
    /// the read starts, so a slower earlier read keeps the lower id and
    /// cannot move the protocol gate.
    private var nextHerdReadSerial: UInt64 = 0

    /// Clocks for "blocked since" and silence. A fresh agent on every
    /// tool call would start both at that call.
    private var episodes = DiagnosisEpisodeLedger()
    private let outputPoller = HeartbeatPoller()
    /// When each working pane's detection screen was last read. Inside
    /// `outputPollInterval` the stored hash is reused.
    private var lastOutputPoll: [AgentID: Date] = [:]
    /// Same cadence as Shepherd's heartbeat.
    private let outputPollInterval: TimeInterval = 10

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

    /// Agents for one diagnosis, with clocks this process already recorded.
    ///
    /// `buildAgents` stamps `enteredAt` at the call. A blocked agent then
    /// reads as newly blocked on every overview, and a working agent can
    /// never go quiet. The ledger keeps the episode. The detection hash
    /// moves with a session so a cross-workspace move does not make the
    /// next read a first look. A working pane with no baseline is treated
    /// as having just produced output: a failed screen read is not silence.
    ///
    /// `readSerial` is the id captured before this herd request. Tool calls
    /// overlap, and the slower response is often the earlier herd. A serial
    /// that loses does not observe, poll, or prune: observing would rewind
    /// the episode, and pruning would delete the detection baseline the
    /// later read just stored. That call still reports a clock the ledger
    /// already has for the same status and seq.
    private func agentsForDiagnosis(
        from herd: HerdSnapshot,
        readSerial: UInt64
    ) async -> [AgentID: Agent] {
        let now = Date()
        guard let observed = episodes.observeIfCurrent(herd.agents, readSerial: readSerial, now: now) else {
            return await agentsKeepingClocks(from: herd)
        }
        // Note the serial on the poller before any later await returns an
        // older pane.read into it. A move does that inside the retarget.
        // A herd with no move still has to note it, or a poll that is
        // already waiting stores the earlier screen over this one.
        if !observed.moves.isEmpty {
            _ = await outputPoller.retarget(replacing: observed.moves, herdSerial: readSerial)
        } else {
            await outputPoller.noteHerdSerial(readSerial)
        }
        var agents = buildAgents(from: herd)
        for (id, enteredAt) in observed.enteredAt {
            agents[id]?.enteredAt = enteredAt
        }

        // The retarget await can let a newer serial adopt. Polling this
        // snapshot then hashes panes that read already replaced, and the
        // prune below would drop the baseline it stored.
        if episodes.isLatestHerd(readSerial) {
            let due = agents.values.filter { agent in
                guard agent.status == .working else { return false }
                if let last = lastOutputPoll[agent.id], now.timeIntervalSince(last) < outputPollInterval {
                    return false
                }
                return true
            }
            if !due.isEmpty {
                _ = await outputPoller.poll(agents: due, adapter: adapter, herdSerial: readSerial)
                // After the read. A newer serial noted during it drops
                // these bytes, and stamping the cadence beforehand would
                // make that newer herd skip the screen for ten seconds.
                if episodes.isLatestHerd(readSerial) {
                    let polledAt = Date()
                    for agent in due {
                        lastOutputPoll[agent.id] = polledAt
                    }
                }
            }
        }
        agents = await stampDetectionOutput(agents)

        if episodes.isLatestHerd(readSerial) {
            let live = Set(agents.keys)
            lastOutputPoll = lastOutputPoll.filter { live.contains($0.key) }
            await outputPoller.prune(keeping: live)
        }
        return agents
    }

    /// The herd read lost the serial race. Report clocks already stored
    /// for the same episode, and do not move the ledger or the poller.
    private func agentsKeepingClocks(from herd: HerdSnapshot) async -> [AgentID: Agent] {
        var agents = buildAgents(from: herd)
        for id in Array(agents.keys) {
            guard var agent = agents[id],
                  let enteredAt = episodes.enteredAt(matching: agent) else { continue }
            agent.enteredAt = enteredAt
            agents[id] = agent
        }
        return await stampDetectionOutput(agents)
    }

    /// `lastOutputAt` from the detection baseline. The dictionary is copied
    /// back after the reads: writing it while it is being iterated, and
    /// holding that write across an await, is a trap.
    private func stampDetectionOutput(_ agents: [AgentID: Agent]) async -> [AgentID: Agent] {
        let stamped = Date()
        var outputs: [AgentID: Date] = [:]
        for (id, agent) in agents {
            let baseline = await outputPoller.lastOutputDate(for: id)
            if let output = DiagnosisEpisodeLedger.outputDate(
                for: agent.status,
                baseline: baseline,
                now: stamped
            ) {
                outputs[id] = output
            }
        }
        var stampedAgents = agents
        for (id, output) in outputs {
            stampedAgents[id]?.lastOutputAt = output
        }
        return stampedAgents
    }

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

            let kind = AgentKind.resolved(sessionAgent: info.agentSession?.agent, detected: agentKind)

            let name = AgentLabel.preferred(
                title: info.title,
                displayAgent: info.displayAgent,
                name: info.name,
                terminalTitleStripped: info.terminalTitleStripped,
                paneLabel: herd.paneLabels[info.paneId]
            ) ?? agentKind

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
                cwd: AgentLabel.nonempty(info.foregroundCwd) ?? AgentLabel.nonempty(info.cwd) ?? "",
                sessionIdentity: info.sessionIdentity
            )
            agents[agentId] = agent
        }

        return agents
    }

    /// Resolve a stable pane ID or a human description such as an agent title,
    /// workspace, tab, or repository directory. Used by the read tools.
    /// A unique local suffix (`p1` of `w1:p1`) is accepted because that is
    /// what an older overview printed. Write tools still require the full id.
    private func resolveAgent(
        arguments: [String: Any],
        herd: HerdSnapshot
    ) -> Result<HerdrAgentInfo, AgentResolutionError> {
        switch herd.resolveAgent(
            agentId: arguments["agent_id"] as? String,
            query: arguments["query"] as? String
        ) {
        case .found(let info):
            return .success(info)
        case .failure(let description):
            return .failure(AgentResolutionError(description: description))
        }
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
            let (herd, herdSerial) = try await readNumberedHerd()
            var agents = await agentsForDiagnosis(from: herd, readSerial: herdSerial)

            // Diagnose non-idle agents. The episode clock and the detection
            // baseline come from earlier calls in this process.
            for agent in agents.values where agent.status != .idle {
                let verdict = await diagnoser.diagnose(agent: agent, adapter: adapter)
                if var current = agents[agent.id] {
                    current.verdict = verdict
                    agents[agent.id] = current
                }
            }

            let text = HerdReport.overview(
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
            let (herd, herdSerial) = try await readNumberedHerd()
            var agents = await agentsForDiagnosis(from: herd, readSerial: herdSerial)

            // Diagnose non-idle agents. The episode clock and the detection
            // baseline come from earlier calls in this process.
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
                        HerdReport.kindText(agent.kind)
                    ].contains { $0.lowercased().contains(needle) }
                }
            }

            let text = HerdReport.agentList(
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
            let (herd, herdSerial) = try await readNumberedHerd()
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

            var agents = await agentsForDiagnosis(from: herd, readSerial: herdSerial)

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
                // Inspect only prints the last 10 lines. Cap the herdr read
                // so a detection buffer cannot land whole in RSS.
                readResult = try await adapter.read(
                    paneId: paneId,
                    source: .detection,
                    lines: HeartbeatPoller.detectionReadLines
                )
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
                tabNames: herd.tabNames,
                paneLabel: herd.paneLabels[info.paneId]
            )
            let redacted = redactor.redact(text)
            return makeToolResult(redacted.redactedText)
        } catch {
            return makeToolError("Failed to inspect agent: \(error.localizedDescription)")
        }
    }

    // MARK: - agent.tail

    private func handleAgentTail(arguments: [String: Any]) async -> [String: Any] {
        let lineCount = min(max(JSONNumber.int(arguments["lines"]) ?? 50, 1), 200)

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
            let herd = try await readHerd()
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
            let (herd, herdSerial) = try await readNumberedHerd()
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

            let agents = await agentsForDiagnosis(from: herd, readSerial: herdSerial)
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
        guard let providedSeq = JSONNumber.uint64(arguments["state_change_seq"]) else {
            return makeToolError("Missing required parameter: state_change_seq (mandatory for agent.answer)")
        }

        if choice == "select" {
            guard let index = JSONNumber.int(arguments["index"]) else {
                return makeToolError("choice 'select' requires an 'index' parameter (integer)")
            }
            // Index bounds: 0...20
            guard SpawnPathPolicy.isValidSelectIndex(index) else {
                return makeToolError("Index out of bounds: \(index). Must be 0...20.")
            }
        }

        do {
            try await ensureConnected()
            // Before the await, so two answers in flight keep capture order
            // even when the slower read returns last.
            let readSerial = captureHerdReadSerial()
            let herd = try await adapter.herdSnapshot(readSerial: readSerial)
            let paneId = agentIdStr

            guard let paneInfo = herd.agents.first(where: { $0.paneId == paneId }) else {
                return makeToolError("Agent not found: \(agentIdStr)")
            }

            guard paneInfo.agentStatus == "blocked" else {
                return makeToolError("Agent \(agentIdStr) is not blocked (status: \(paneInfo.agentStatus)). agent.answer requires status=blocked.")
            }

            // Verify state_change_seq matches current
            let currentSeq = paneInfo.stateChangeSeq
            if providedSeq != currentSeq {
                return makeToolError("Stale state_change_seq: provided \(providedSeq), current \(currentSeq). Re-diagnose and retry.")
            }

            // Record the observed episode so the consecutive-answer cap
            // resets when it actually changes. A newer read whose seq went
            // backwards is a herdr restart: that resets too, or the cap
            // stays stuck for the life of the process. An older in-flight
            // read cannot clear it. The session is the budget, so a move
            // to a new pane id is still this episode's cap.
            await policy.recordStatusChange(
                agentId: agentIdStr,
                newSeq: currentSeq,
                observationSerial: readSerial,
                occupantFingerprint: paneInfo.occupantFingerprint,
                sessionIdentity: paneInfo.sessionIdentity
            )

            // Check policy. The session has to travel with the pane id:
            // the cap and the cooldown are stored on it.
            // Does not take the slot. explain is still ahead, and a
            // refusal here has not sent anything.
            let policyResult = await policy.checkWriteAllowed(
                agentId: agentIdStr,
                tier: .gated,
                sessionIdentity: paneInfo.sessionIdentity
            )
            if let error = policyDenial(policyResult) { return error }

            // Detect the block kind so we only answer RECOGNIZED prompts.
            // Unknown or merely-probable blocks stay read-only — we never send
            // keystrokes we cannot justify for the detected prompt shape.
            let explain = try await adapter.explain(paneId: paneId)
            let blockKind = explain.matchedRuleId.map { BlockKind.from(ruleId: $0) } ?? .unknownBlock

            guard let resolvedKeys = Self.keys(forChoice: choice, index: JSONNumber.int(arguments["index"]), blockKind: blockKind) else {
                return makeToolError("Cannot answer: detected block kind '\(blockKind.rawValue)' does not permit choice '\(choice)'. Recognized prompts only; unknown/weak blocks stay read-only.")
            }

            if let error = await checkWritesEnabled() { return error }

            // explain and the protocol re-read are awaits. The prompt we
            // checked can be answered or replaced before the keys go out.
            let confirmSerial = captureHerdReadSerial()
            let confirmed = try await adapter.herdSnapshot(readSerial: confirmSerial)
            if let refusal = AnswerSendCheck.refusal(sendingTo: paneInfo, in: confirmed) {
                return refusedAnswer(refusal, agentId: agentIdStr, providedSeq: providedSeq)
            }
            // The confirm read is the protocol reading too. A downgrade it
            // just recorded has writes off; don't send on the earlier gate.
            let health = adapter.health()
            if !health.writesEnabled {
                return makeToolError("Writes not enabled: \(health.reason ?? "herdr protocol not verified for writes")")
            }
            // The check before explain did not take the slot. Another
            // write can land in that gap. Take it now, before the keys.
            let reserved = await policy.reserveWrite(
                agentId: agentIdStr,
                tier: .gated,
                sessionIdentity: paneInfo.sessionIdentity
            )
            if let error = policyDenial(reserved) { return error }
            try await adapter.sendKeys(paneId: paneId, keys: resolvedKeys)

            await policy.recordAnswer(agentId: agentIdStr, sessionIdentity: paneInfo.sessionIdentity)

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
            let herd = try await readHerd()
            let paneId = agentIdStr

            guard let paneInfo = herd.agents.first(where: { $0.paneId == paneId }) else {
                return makeToolError("Agent not found: \(agentIdStr)")
            }

            let status = paneInfo.agentStatus
            // Idle and done auto-send. The gated path re-reads before the
            // text, because `prompt` also submits Enter.
            let tier: AuthorityTier = GatedSayFollow.acceptsAutoSend(status: status) ? .gated : .confirm

            // Does not take the slot. A confirm-tier say still has the
            // approval wait ahead of it; the send reserves.
            let policyResult = await policy.checkWriteAllowed(
                agentId: agentIdStr,
                tier: tier,
                sessionIdentity: paneInfo.sessionIdentity
            )
            if let error = policyDenial(policyResult) { return error }

            // Capture fingerprint info for revalidation after confirmation wait
            let fpOccupant = occupantFingerprint(from: paneInfo)
            let fpStatus = paneInfo.agentStatus
            let fpSeq = paneInfo.stateChangeSeq

            // Confirm tier: create pending action and wait for UI approval
            if case .confirm = tier {
                var params: [String: String] = [
                    "agent_id": agentIdStr,
                    "text": redactor.redact(String(text.prefix(100))).redactedText
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
                    if let error = await rejectIfWritesDisabled(
                        actionId: actionId,
                        detail: "writes disabled after confirmation"
                    ) {
                        return error
                    }

                    // Revalidate pane occupant + status episode after the wait.
                    // A move during the wait addresses the session's new pane.
                    let current: HerdrAgentInfo
                    do {
                        current = try await revalidate(action: claimed, paneId: paneId)
                    } catch {
                        try? await sharedActionStore.markFailed(actionId, detail: "revalidation failed: \(error)")
                        return makeToolError("Revalidation failed: \(error). No input sent.")
                    }

                    let addressed = Self.addressedParams(
                        requested: agentIdStr,
                        resolved: current.paneId,
                        extra: ["text_length": "\(text.count)"]
                    )
                    // The check that opened this dialog is minutes old.
                    // Reserve the pane the write will actually address.
                    if let error = await rejectIfSendOverBudget(
                        actionId: actionId,
                        tool: "agent.say",
                        agentId: current.paneId,
                        tier: .confirm,
                        sessionIdentity: current.sessionIdentity,
                        params: addressed,
                        preState: "status=\(status)"
                    ) {
                        return error
                    }
                    do {
                        try await adapter.prompt(paneId: current.paneId, text: text)
                    } catch {
                        return await failClaimedWrite(
                            actionId: actionId, tool: "agent.say",
                            params: addressed,
                            preState: "status=\(status)", error: error
                        )
                    }
                    try? await sharedActionStore.markExecuted(actionId)

                    await journal.record(JournalEntry(
                        actionId: actionId, tool: "agent.say",
                        params: addressed,
                        caller: "mcp", preState: "status=\(status)",
                        postState: "sent", outcome: "executed"
                    ))

                    if let waitFor = arguments["wait_for"] as? String {
                        let timeoutMs = JSONNumber.int(arguments["timeout_ms"]) ?? 30000
                        let settled = try await adapter.waitStatus(paneId: current.paneId, until: [waitFor], timeoutMs: timeoutMs)
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

            // Gated tier: auto-allowed for idle and done. The check above
            // did not take the slot, and it awaited the policy actor.
            // `prompt` submits Enter, so address a list taken after that
            // await. A move follows the session. A status that left idle
            // or done, or a different occupant, sends nothing and does not
            // take a slot. This list records the protocol, and the gate is
            // read from it before the slot is taken.
            let fresh = try await readHerd()
            let confirmed: HerdrAgentInfo
            switch GatedSayFollow.resolve(previous: paneInfo, in: fresh.agents) {
            case .success(let info):
                let health = adapter.health()
                if !health.writesEnabled {
                    return makeToolError(
                        "Writes not enabled: \(health.reason ?? "herdr protocol not verified for writes"). No input sent."
                    )
                }
                confirmed = info
            case .failure(.agentGone):
                return makeToolError("Agent not found: \(agentIdStr). No input sent.")
            case .failure(.occupantChanged):
                return makeToolError("Pane occupant changed before send. No input sent.")
            case .failure(.noLongerAuto(let pane, let now)):
                return makeToolError(
                    "Agent \(pane) is \(now), so this say needs confirmation. No input sent."
                )
            }
            let reserved = await policy.reserveWrite(
                agentId: confirmed.paneId,
                tier: .gated,
                sessionIdentity: confirmed.sessionIdentity
            )
            if let error = policyDenial(reserved) { return error }
            try await adapter.prompt(paneId: confirmed.paneId, text: text)

            let addressed = Self.addressedParams(
                requested: agentIdStr,
                resolved: confirmed.paneId,
                extra: ["text_length": "\(text.count)"]
            )
            var params: [String: String] = [
                "agent_id": agentIdStr,
                "text": redactor.redact(String(text.prefix(100))).redactedText
            ]
            if confirmed.paneId != agentIdStr {
                params["resolved_agent_id"] = confirmed.paneId
            }
            params["_fp_occupant"] = occupantFingerprint(from: confirmed)
            params["_fp_status"] = confirmed.agentStatus
            params["_fp_seq"] = "\(confirmed.stateChangeSeq)"

            let actionId = await actionStore.create(tool: "agent.say", params: params)
            await actionStore.markExecuted(actionId)

            await journal.record(JournalEntry(
                actionId: actionId, tool: "agent.say",
                params: addressed,
                caller: "mcp",
                preState: "status=\(confirmed.agentStatus), seq=\(confirmed.stateChangeSeq)",
                postState: "sent", outcome: "executed"
            ))

            let resolvedField = confirmed.paneId == agentIdStr
                ? ""
                : ",\"resolvedAgentId\":\"\(confirmed.paneId)\""
            if let waitFor = arguments["wait_for"] as? String {
                let timeoutMs = JSONNumber.int(arguments["timeout_ms"]) ?? 30000
                let settled = try await adapter.waitStatus(
                    paneId: confirmed.paneId, until: [waitFor], timeoutMs: timeoutMs
                )
                return makeToolResult(
                    "{\"sent\":true,\"actionId\":\"\(actionId)\",\"outcome\":\"\(settled ? "settled" : "timeout")\"\(resolvedField)}"
                )
            }
            return makeToolResult(
                "{\"sent\":true,\"actionId\":\"\(actionId)\",\"outcome\":\"sent\"\(resolvedField)}"
            )
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
            let herd = try await readHerd()
            let paneId = agentIdStr

            guard let paneInfo = herd.agents.first(where: { $0.paneId == paneId }) else {
                return makeToolError("Agent not found: \(agentIdStr)")
            }

            // Refuse before asking when the budget is already spent.
            // The send reserves again: the approval wait is long enough
            // for another write to take the slot.
            let budget = await policy.checkWriteAllowed(
                agentId: agentIdStr,
                tier: .confirm,
                sessionIdentity: paneInfo.sessionIdentity
            )
            if let error = policyDenial(budget) { return error }

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
                if let error = await rejectIfWritesDisabled(
                    actionId: actionId,
                    detail: "writes disabled after confirmation"
                ) {
                    return error
                }

                // Revalidate pane occupant + status episode after the wait.
                // A move during the wait addresses the session's new pane.
                let current: HerdrAgentInfo
                do {
                    current = try await revalidate(action: claimed, paneId: paneId)
                } catch {
                    try? await sharedActionStore.markFailed(actionId, detail: "revalidation failed: \(error)")
                    return makeToolError("Revalidation failed: \(error). No input sent.")
                }

                let keys: [String] = level == "escape" ? ["esc"] : ["ctrl+c"]
                let addressed = Self.addressedParams(
                    requested: agentIdStr,
                    resolved: current.paneId,
                    extra: ["level": level]
                )
                if let error = await rejectIfSendOverBudget(
                    actionId: actionId,
                    tool: "agent.interrupt",
                    agentId: current.paneId,
                    tier: .confirm,
                    sessionIdentity: current.sessionIdentity,
                    params: addressed,
                    preState: "status=\(paneInfo.agentStatus)"
                ) {
                    return error
                }
                do {
                    try await adapter.sendKeys(paneId: current.paneId, keys: keys)
                } catch {
                    return await failClaimedWrite(
                        actionId: actionId, tool: "agent.interrupt",
                        params: addressed,
                        preState: "status=\(paneInfo.agentStatus)", error: error
                    )
                }
                try? await sharedActionStore.markExecuted(actionId)

                await journal.record(JournalEntry(
                    actionId: actionId, tool: "agent.interrupt",
                    params: addressed,
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
            let herd = try await readHerd()
            let paneId = agentIdStr

            guard let paneInfo = herd.agents.first(where: { $0.paneId == paneId }) else {
                return makeToolError("Agent not found: \(agentIdStr)")
            }

            // Same budget as interrupt. A stop is a write, and the
            // approval wait does not hold the slot.
            let budget = await policy.checkWriteAllowed(
                agentId: agentIdStr,
                tier: .confirm,
                sessionIdentity: paneInfo.sessionIdentity
            )
            if let error = policyDenial(budget) { return error }

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
                if let error = await rejectIfWritesDisabled(
                    actionId: actionId,
                    detail: "writes disabled after confirmation"
                ) {
                    return error
                }

                // Revalidate pane occupant + status episode after the wait.
                // A move during the wait closes the session's new pane.
                let current: HerdrAgentInfo
                do {
                    current = try await revalidate(action: claimed, paneId: paneId)
                } catch {
                    try? await sharedActionStore.markFailed(actionId, detail: "revalidation failed: \(error)")
                    return makeToolError("Revalidation failed: \(error). No input sent.")
                }

                let addressed = Self.addressedParams(
                    requested: agentIdStr,
                    resolved: current.paneId,
                    extra: ["reason": reason]
                )
                if let error = await rejectIfSendOverBudget(
                    actionId: actionId,
                    tool: "agent.stop",
                    agentId: current.paneId,
                    tier: .confirm,
                    sessionIdentity: current.sessionIdentity,
                    params: addressed,
                    preState: "status=\(paneInfo.agentStatus)",
                    keepForever: true
                ) {
                    return error
                }
                do {
                    try await adapter.closePane(paneId: current.paneId)
                } catch {
                    return await failClaimedWrite(
                        actionId: actionId, tool: "agent.stop",
                        params: addressed,
                        preState: "status=\(paneInfo.agentStatus)", error: error,
                        keepForever: true
                    )
                }
                try? await sharedActionStore.markExecuted(actionId)

                await journal.record(JournalEntry(
                    actionId: actionId, tool: "agent.stop",
                    params: addressed,
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
        let agentKind = kind.lowercased()
        let agentName = SpawnPathPolicy.canonicalAgentName(name, fallback: agentKind)

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
                let herd = try await readHerd()

                if placement == "new_tab" {
                    guard let requestedWorkspace = workspaceId, !requestedWorkspace.isEmpty else {
                        return makeToolError("placement=new_tab requires workspace_id")
                    }
                    guard herd.workspaceNames[requestedWorkspace] != nil else {
                        return makeToolError("Workspace not found: \(requestedWorkspace)")
                    }
                    cwdHint = herd.agents.first(where: {
                        $0.workspaceId == requestedWorkspace
                    })?.workingDirectory
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
                    cwdHint = target.workingDirectory
                }
            } catch {
                return makeToolError("Failed to resolve placement: \(error.localizedDescription)")
            }
        }

        let brief = arguments["brief"] as? String
        let spaceLabel = arguments["space_label"] as? String

        var params: [String: String] = [
            "placement": placement,
            "kind": agentKind,
            "name": agentName
        ]
        if agentName != name {
            params["requested_name"] = name
        }
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

        let actionId: String
        do {
            actionId = try await sharedActionStore.create(tool: "session.spawn", params: params)
        } catch {
            return makeToolError("Failed to record spawn action: \(error)")
        }

        // MCP session creation is explicitly auto-allowed. Keep the action in
        // the shared store for audit/status visibility, but claim it directly
        // instead of waiting for a menu-bar approval that the MCP caller may
        // not be able to observe.
        guard let claimed = try? await sharedActionStore.claimAutoExecuting(actionId: actionId) else {
            try? await sharedActionStore.markFailed(actionId, detail: "auto-allowed action no longer claimable")
            return makeToolError("Auto-allowed spawn action no longer claimable (actionId: \(actionId))")
        }
        if let error = await rejectIfWritesDisabled(
            actionId: actionId,
            detail: "writes disabled after claim"
        ) {
            return error
        }
        // Before any mutation. Concurrent spawns share the 6/min cap.
        // A spawn that then fails still holds the slot. The new pane's
        // cooldown is stamped only after it has started, and that stamp
        // does not count a second time.
        if let error = await rejectIfGlobalSpawnOverBudget(
            actionId: actionId,
            params: params.filter { !$0.key.hasPrefix("_fp_") },
            preState: "pending"
        ) {
            return error
        }

        await journal.record(JournalEntry(
            actionId: actionId, tool: "session.spawn",
            params: params.filter { !$0.key.hasPrefix("_fp_") },
            caller: "mcp", preState: "pending", postState: "executing",
            outcome: "auto_allowed", keepForever: true
        ))

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
                let freshHerd = try await readHerd()
                guard freshHerd.workspaceNames[workspaceId] != nil else {
                    throw AgentResolutionError(description: "workspace disappeared before execution")
                }
                // The placement read may have recorded a downgrade the
                // claim-time gate did not see.
                try throwIfWritesDisabled()
                let creation = try await adapter.createTab(
                    workspaceId: workspaceId,
                    cwd: cwdHint,
                    label: agentKind.capitalized,
                    focus: true
                )
                finalWorkspaceId = workspaceId
                tabId = creation.tabId
                paneId = creation.rootPaneId

            case "split":
                guard let targetInfo else {
                    throw AgentResolutionError(description: "split target missing")
                }
                // The target can move while the claim is in flight. Split
                // the pane that still has that occupant.
                let current = try await revalidate(action: claimed, paneId: targetInfo.paneId)
                finalWorkspaceId = current.workspaceId
                paneId = try await adapter.splitPane(
                    targetPaneId: current.paneId,
                    cwd: current.workingDirectory ?? cwdHint
                )

            default:
                throw AgentResolutionError(description: "invalid placement")
            }

            let shellReady = try await adapter.waitForShell(paneId: paneId)
            guard shellReady else {
                throw AgentResolutionError(description: "agent target pane \(paneId) did not become an available shell")
            }
            // A not-ready pane fails the shell read. A connect failure in
            // that retry clears the gate, and a later read can still see
            // the shell. Re-read before launching, or the start is refused
            // on a gate herdr has already come back from. A restart onto
            // an older protocol stays closed.
            try await requireFreshWrites()
            try await adapter.startAgent(
                paneId: paneId,
                kind: agentKind,
                name: agentName,
                timeoutMs: 30_000
            )

            if let brief, !brief.isEmpty {
                let ready = try await adapter.waitStatus(
                    paneId: paneId,
                    until: ["idle", "working", "blocked", "done"],
                    timeoutMs: 30_000
                )
                guard ready else {
                    throw AgentResolutionError(description: "agent \(paneId) did not become ready before the brief timeout")
                }
                try await requireFreshWrites()
                try await adapter.prompt(paneId: paneId, text: brief)
            }

            // The global slot was taken before the mutation. This only
            // starts the new pane's cooldown, so the spawn is one write.
            await policy.noteAgentCooldown(agentId: paneId)
            try? await sharedActionStore.markExecuted(actionId)

            await journal.record(JournalEntry(
                actionId: actionId, tool: "session.spawn",
                params: [
                    "placement": placement,
                    "kind": agentKind,
                    "name": agentName,
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
            let detail = String(describing: error)
            try? await sharedActionStore.markFailed(actionId, detail: detail)
            return makeToolError("session.spawn execution failed: \(detail)")
        }
    }

    // MARK: - action.status

    private func handleActionStatus(arguments: [String: Any]) async -> [String: Any] {
        guard let actionId = arguments["action_id"] as? String, !actionId.isEmpty else {
            return makeToolError("Missing required parameter: action_id")
        }

        try? await sharedActionStore.expireStale()

        if let state = await sharedActionStore.status(actionId) {
            var payload: [String: String] = ["state": state.rawValue]
            if let action = await sharedActionStore.get(actionId), let detail = action.failDetail {
                payload["detail"] = detail
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                return makeToolError("Action status encoding failed")
            }
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

    private func captureHerdReadSerial() -> UInt64 {
        nextHerdReadSerial += 1
        return nextHerdReadSerial
    }

    /// One herd read, ordered against every other MCP herd read and against
    /// `checkWritesEnabled`. The serial is captured here, with no await
    /// before the request. `agent.answer` captures its own serials because
    /// the answer cap records the same id. Diagnosing tools keep the serial
    /// (`readNumberedHerd`) so a slower earlier snapshot does not rewind
    /// the episode clock.
    private func readHerd() async throws -> HerdSnapshot {
        let (snapshot, _) = try await readNumberedHerd()
        return snapshot
    }

    private func readNumberedHerd() async throws -> (HerdSnapshot, UInt64) {
        let readSerial = captureHerdReadSerial()
        let snapshot = try await adapter.herdSnapshot(readSerial: readSerial)
        return (snapshot, readSerial)
    }

    // MARK: - Write-Gate Helper

    /// Returns a tool error dict if writes are disabled, or nil if writes are
    /// allowed. Every gate takes a fresh protocol reading. Re-reading only at
    /// protocol 0 let a herdr restarted between calls, or while a write sat
    /// in its confirmation wait, receive the write on the old build's
    /// reading (`session.spawn` new_workspace never re-read at all). The
    /// refresh carries a herd-read serial so a slow earlier gate cannot put
    /// the protocol back after a later read has recorded a newer one.
    private func checkWritesEnabled() async -> [String: Any]? {
        let readSerial = captureHerdReadSerial()
        let health = await adapter.refreshHealth(readSerial: readSerial)
        if !health.writesEnabled {
            return makeToolError("Writes not enabled: \(health.reason ?? "herdr protocol not verified for writes")")
        }
        return nil
    }

    /// After UI confirmation, refuse to send input if the protocol gate
    /// flipped to read-only during the wait.
    private func rejectIfWritesDisabled(actionId: String, detail: String) async -> [String: Any]? {
        guard let error = await checkWritesEnabled() else { return nil }
        try? await sharedActionStore.markFailed(actionId, detail: detail)
        return error
    }

    /// The tool error for a budget result that is already decided.
    /// Does not record a write.
    private func policyDenial(_ result: PolicyResult) -> [String: Any]? {
        guard !result.allowed else { return nil }
        return makeToolError("Policy denied: \(result.reason ?? "unknown")")
    }

    /// Reserve the slot and, when the budget refuses, fail the claimed
    /// action without sending. The reservation has already consumed the
    /// slot when this returns nil.
    private func rejectIfSendOverBudget(
        actionId: String,
        tool: String,
        agentId: String,
        tier: AuthorityTier,
        sessionIdentity: String?,
        params: [String: String],
        preState: String,
        keepForever: Bool = false
    ) async -> [String: Any]? {
        let result = await policy.reserveWrite(
            agentId: agentId,
            tier: tier,
            sessionIdentity: sessionIdentity
        )
        return await failClosedBudget(
            result,
            actionId: actionId,
            tool: tool,
            params: params,
            preState: preState,
            keepForever: keepForever
        )
    }

    /// One global slot for a spawn, which has no pane id yet.
    private func rejectIfGlobalSpawnOverBudget(
        actionId: String,
        params: [String: String],
        preState: String
    ) async -> [String: Any]? {
        let result = await policy.reserveGlobalWrite()
        return await failClosedBudget(
            result,
            actionId: actionId,
            tool: "session.spawn",
            params: params,
            preState: preState,
            keepForever: true
        )
    }

    private func failClosedBudget(
        _ result: PolicyResult,
        actionId: String,
        tool: String,
        params: [String: String],
        preState: String,
        keepForever: Bool
    ) async -> [String: Any]? {
        guard !result.allowed else { return nil }
        let reason = result.reason ?? "rate limit"
        try? await sharedActionStore.markFailed(actionId, detail: "policy denied: \(reason)")
        await journal.record(JournalEntry(
            actionId: actionId, tool: tool,
            params: params,
            caller: "mcp", preState: preState,
            outcome: "policy_denied",
            keepForever: keepForever
        ))
        return makeToolError("Policy denied: \(reason) (actionId: \(actionId))")
    }

    /// A claimed, approved write threw. Record the failure on the shared
    /// action and in the journal. Without this the row sat in `.executing`
    /// until the deadline reaper relabelled it "expired while executing",
    /// so `action.status` misreported a herdr rejection for up to two minutes.
    private func failClaimedWrite(
        actionId: String,
        tool: String,
        params: [String: String],
        preState: String,
        error: Error,
        keepForever: Bool = false
    ) async -> [String: Any] {
        try? await sharedActionStore.markFailed(actionId, detail: "write failed: \(error)")
        await journal.record(JournalEntry(
            actionId: actionId, tool: tool,
            params: params,
            caller: "mcp", preState: preState,
            outcome: "failed",
            keepForever: keepForever
        ))
        return makeToolError("\(tool) failed after approval: \(error) (actionId: \(actionId))")
    }

    // MARK: - Answer Key Mapping

    /// Map an answer choice to keystrokes, gated on the detected block kind.
    /// Returns nil when the choice is not valid for the kind (or the kind is
    /// unknown or only probable), so those prompts stay read-only.
    private static func keys(forChoice choice: String, index: Int?, blockKind: BlockKind) -> [String]? {
        blockKind.answerKeys(forChoice: choice, index: index)
    }

    // MARK: - Occupant Fingerprint & Revalidation

    /// Same identity `AnswerSendCheck` compares and pending actions store.
    private func occupantFingerprint(from info: HerdrAgentInfo) -> String {
        info.occupantFingerprint
    }

    private func refusedAnswer(
        _ refusal: AnswerSendCheck.Refusal,
        agentId: String,
        providedSeq: UInt64
    ) -> [String: Any] {
        switch refusal {
        case .agentGone:
            return makeToolError("Agent not found: \(agentId)")
        case .notBlocked(let now):
            return makeToolError("Agent \(agentId) is not blocked (status: \(now)). agent.answer requires status=blocked.")
        case .promptChanged(let currentSeq):
            return makeToolError("Stale state_change_seq: provided \(providedSeq), current \(currentSeq). Re-diagnose and retry.")
        case .occupantChanged:
            return makeToolError("Pane occupant changed before send. Re-diagnose and retry.")
        }
    }

    /// Revalidate that the approved occupant is still on the same status
    /// episode, and return the pane to address.
    ///
    /// The pane id from approval wins when it still runs an agent. A
    /// cross-workspace move drops that id. The session stored in
    /// `_fp_occupant` then has to name exactly one other agent, on the
    /// same status and seq. Anything else throws, and the caller sends
    /// nothing. Reads fingerprint info from action.params["_fp_*"] keys.
    private func revalidate(action: PendingAction, paneId: String) async throws -> HerdrAgentInfo {
        let herd = try await readHerd()
        let expectedFingerprint = action.params["_fp_occupant"]
        let expectedStatus = action.params["_fp_status"]
        let expectedSeq = action.params["_fp_seq"].flatMap { UInt64($0) }
        switch ConfirmedPaneFollow.resolve(
            previousPaneId: paneId,
            occupantFingerprint: expectedFingerprint,
            expectedStatus: expectedStatus,
            expectedSeq: expectedSeq,
            in: herd.agents
        ) {
        case .success(let info):
            // The herd read is a newer protocol observation than the refresh
            // that opened the gate. A downgrade it just recorded must fail
            // here, before prompt / keys / close, with no input sent.
            try throwIfWritesDisabled()
            return info
        case .failure(.paneGone):
            throw MCPRevalidationError.paneGone(paneId)
        case .failure(.occupantChanged(let expected, let current)):
            throw MCPRevalidationError.occupantChanged(expected: expected, current: current)
        case .failure(.seqAdvanced(let expected, let current)):
            throw MCPRevalidationError.seqAdvanced(expected: expected, current: current)
        case .failure(.statusChanged(let expected, let current)):
            throw MCPRevalidationError.statusChanged(expected: expected, current: current)
        }
    }

    /// Journal and failure params for a write. `resolved_agent_id` is set
    /// when a move sent the write to a pane other than the one approved.
    nonisolated private static func addressedParams(
        requested agentId: String,
        resolved paneId: String,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var params = extra
        params["agent_id"] = agentId
        if paneId != agentId {
            params["resolved_agent_id"] = paneId
        }
        return params
    }

    /// The protocol currently on the gate. Call after the read that should
    /// have recorded it. Does not take another snapshot.
    private func throwIfWritesDisabled() throws {
        let health = adapter.health()
        if !health.writesEnabled {
            throw MCPRevalidationError.writesDisabled(
                health.reason ?? "herdr protocol not verified for writes"
            )
        }
    }

    /// Snapshot the protocol and refuse when that reading cannot take a
    /// write. Used where the previous read does not report a protocol
    /// (`waitForShell`, `agent.wait`) and may have cleared the gate.
    private func requireFreshWrites() async throws {
        let readSerial = captureHerdReadSerial()
        let health = await adapter.refreshHealth(readSerial: readSerial)
        if !health.writesEnabled {
            throw MCPRevalidationError.writesDisabled(
                health.reason ?? "herdr protocol not verified for writes"
            )
        }
    }

    // MARK: - Formatting (nonisolated — pure functions on Sendable inputs)

    nonisolated private static func formatInspect(
        info: HerdrAgentInfo,
        verdict: Verdict,
        explain: AgentExplainResult?,
        procInfo: ProcessInfoResult?,
        recentOutput: String?,
        workspaceNames: [String: String],
        tabNames: [String: String],
        paneLabel: String? = nil
    ) -> String {
        var lines: [String] = []
        let agentId = AgentID(info.paneId)
        let wsName = workspaceNames[info.workspaceId] ?? info.workspaceId
        let tabName = tabNames[info.tabId] ?? info.tabId
        let title = AgentLabel.preferred(
            title: info.title,
            displayAgent: info.displayAgent,
            name: info.name,
            terminalTitleStripped: info.terminalTitleStripped,
            paneLabel: paneLabel
        ) ?? info.agent ?? "unknown"

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
        if let detected = AgentLabel.nonempty(info.agent) {
            // Same rule as the row. An empty session agent is not a kind,
            // and an empty session value is not a reason to hide the
            // detected one behind a blank source.
            let name = AgentLabel.nonempty(info.agentSession?.agent) ?? detected
            let namesSession = info.agentSession?.identity != nil
                || AgentLabel.nonempty(info.agentSession?.agent) != nil
            if namesSession, let source = info.agentSession.flatMap({ AgentLabel.nonempty($0.source) }) {
                lines.append("Kind: \(name) (source: \(source))")
            } else {
                lines.append("Kind: \(name)")
            }
        }
        if let cwd = AgentLabel.nonempty(info.cwd) {
            lines.append("CWD: \(cwd)")
        }
        if let foregroundCwd = AgentLabel.nonempty(info.foregroundCwd),
           foregroundCwd != AgentLabel.nonempty(info.cwd) {
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

    nonisolated private static func verdictName(_ verdict: Verdict) -> String {
        switch verdict {
        case .healthy: return "HEALTHY"
        case .awaitingInput: return "AWAITING INPUT"
        case .silent: return "SILENT"
        case .processGone: return "PROCESS GONE"
        case .unclassifiable: return "UNCLASSIFIABLE"
        }
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
            "description": "Overview of all AI agents in the herdr multiplexer, grouped by workspace. Shows counts by status and which agents need attention. Each agent line includes its agent_id in brackets, in workspace:pane form (for example w5:p2); that is the id other tools accept. Quiet is reported once this server has seen the same detection screen past the silence threshold.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any]()
            ] as [String: Any]
        ] as [String: Any],
        [
            "name": "agent.list",
            "description": "List all agents with their current status. The ID column is the agent_id other tools accept, in workspace:pane form (for example w5:p2), not the bare pane suffix. Optionally filter by status or workspace.",
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
            "description": "Run full stuck-diagnosis on one agent. Pass agent_id or a unique human query. Returns verdict, confidence, what it is waiting on, evidence, and suggested actions. Blocked and quiet durations start when this server first sees that episode. Quiet also requires the detection screen to stay unchanged across calls.",
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
            "description": "Reply to a blocked agent's prompt with a bounded choice. Requires status=blocked. approve sends Enter and deny or cancel sends Esc. accept_once (Down, then Enter) is only for a yes / don't-ask-again / no stack. select sends that many Downs, then Enter, on a menu or a highlighted confirmation. Unknown and probable blocks stay read-only. Max 3 consecutive answers without a status change. The same agent session keeps that cap when its pane id changes.",
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
            "description": "Start an agent in a new workspace, a new tab in an existing workspace, or a split beside an existing agent. MCP callers are auto-allowed without menu-bar confirmation; other destructive writes remain confirmation-gated. Use placement=new_workspace with repo_path, new_tab with workspace_id, or split with target_agent_id.",
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
            "message": outboundRedactor.redact(message).redactedText
        ]
    ]
}

private let outboundRedactor = SecretRedactor()

private func makeToolResult(_ text: String) -> [String: Any] {
    [
        "content": [
            [
                "type": "text",
                "text": outboundRedactor.redact(text).redactedText
            ]
        ]
    ]
}

private func makeToolError(_ message: String) -> [String: Any] {
    [
        "content": [
            [
                "type": "text",
                "text": outboundRedactor.redact(message).redactedText
            ]
        ],
        "isError": true
    ]
}
