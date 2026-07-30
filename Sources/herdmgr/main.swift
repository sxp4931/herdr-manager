import Foundation
import ArgumentParser
import HerdrManagerCore

// MARK: - Helpers

/// Safe string padding that works with emoji/multi-byte characters.
/// `String(format: "%-8s")` crashes with emoji because %s expects a C string
/// and Swift's String bridging fails on multi-byte UTF-8 sequences.
func pad(_ s: String, to width: Int) -> String {
    let count = s.count
    if count >= width { return s }
    return s + String(repeating: " ", count: width - count)
}

// MARK: - CLI Command

@main
struct HerdmgrCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "herdmgr",
        abstract: "Herdr Manager CLI — monitor AI coding agents"
    )

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Flag(name: .long, help: "Show all agents, not just attention-worthy ones")
    var showAll = false

    @Option(name: .long, help: "Path to herdr socket")
    var socket: String?

    func run() async throws {
        // Ignore SIGPIPE — herdr uses one-shot sockets that close after each
        // request/response. Without this, the second connection (event stream)
        // triggers SIGPIPE when writing to the already-closed socket.
        signal(SIGPIPE, SIG_IGN)

        let socketPath = resolveSocketPath()

        // Check socket exists
        let fm = FileManager.default
        guard fm.fileExists(atPath: socketPath) else {
            FileHandle.standardError.write("Error: herdr socket not found at \(socketPath)\n".data(using: .utf8)!)
            FileHandle.standardError.write("Is herdr running?\n".data(using: .utf8)!)
            throw ExitCode.failure
        }

        let adapter = LiveHerdrAdapter(socketPath: socketPath)

        do {
            try await adapter.connect()
        } catch {
            FileHandle.standardError.write("Error connecting to herdr: \(error)\n".data(using: .utf8)!)
            throw ExitCode.failure
        }

        // Take initial snapshot
        let snapshot: HerdrSnapshot
        do {
            snapshot = try await adapter.snapshot()
        } catch {
            FileHandle.standardError.write("Error taking snapshot: \(error)\n".data(using: .utf8)!)
            throw ExitCode.failure
        }

        // Build agent list from snapshot
        var agents = buildAgentList(from: snapshot)

        if json {
            let output = agents.map { agent in
                [
                    "id": agent.id.raw,
                    "status": agent.status.rawValue,
                    "kind": agentKindString(agent.kind),
                    "name": agent.name,
                    "workspace": agent.workspaceName,
                    "tab": agent.tabName,
                ] as [String: String]
            }
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        // Live table mode
        printTable(agents, showAll: showAll)

        // Set up signal handling for graceful exit
        signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler {
            print("\nExiting...")
            Darwin.exit(0)
        }
        signalSource.resume()

        // Subscribe to events
        let eventStream = adapter.events()
        for await event in eventStream {
            applyEvent(event, to: &agents)
            // Clear screen and redraw
            print("\u{001B}[2J\u{001B}[H")
            printTable(agents, showAll: showAll)
        }
    }

    private func resolveSocketPath() -> String {
        if let socket { return socket }
        return LiveHerdrAdapter.resolveSocketPath()
    }

    // MARK: - Agent list building (non-@MainActor version for CLI)

    private func buildAgentList(from snapshot: HerdrSnapshot) -> [Agent] {
        let wsMap = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceId, $0.name) })
        let tabMap = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.tabId, $0.name) })

        var agents: [Agent] = []
        for pane in snapshot.panes {
            guard pane.agent != nil || pane.agentStatus != "unknown" else { continue }
            let agentId = AgentID(pane.paneId)
            let status = AgentStatus(rawValue: pane.agentStatus) ?? .unknown
            let wsName = wsMap[pane.workspaceId] ?? ""
            let tabName = tabMap[pane.tabId] ?? ""
            let kind: AgentKind = {
                if let session = pane.agentSession {
                    return AgentKind.custom(session.agent)
                } else if let agentName = pane.agent {
                    return AgentKind.custom(agentName)
                }
                return .custom("unknown")
            }()
            let name = pane.agent ?? pane.terminalTitleStripped ?? ""

            agents.append(Agent(
                id: agentId,
                kind: kind,
                name: name,
                displayName: name,
                status: status,
                stateChangeSeq: pane.stateChangeSeq ?? 0,
                enteredAt: Date(),
                verdict: verdict(for: status),
                workspaceName: wsName,
                tabName: tabName
            ))
        }
        return agents
    }

    private func applyEvent(_ event: HerdrEvent, to agents: inout [Agent]) {
        switch event {
        case .agentStatusChanged(let paneId, let agentStatus, let seq):
            if let idx = agents.firstIndex(where: { $0.id.raw == paneId }) {
                let newStatus = AgentStatus(rawValue: agentStatus) ?? .unknown
                if let seq, seq < agents[idx].stateChangeSeq { return }
                if newStatus != agents[idx].status {
                    agents[idx].enteredAt = Date()
                }
                agents[idx].status = newStatus
                if let seq { agents[idx].stateChangeSeq = seq }
                agents[idx].verdict = verdict(for: newStatus)
            }
        case .paneCreated(let paneId, let workspaceId, let tabId):
            if !agents.contains(where: { $0.id.raw == paneId }) {
                agents.append(Agent(
                    id: AgentID(paneId),
                    status: .unknown,
                    workspaceName: workspaceId,
                    tabName: tabId
                ))
            }
        case .paneClosed(let paneId):
            agents.removeAll { $0.id.raw == paneId }
        case .paneMoved(let paneId, let workspaceId, let tabId):
            if let idx = agents.firstIndex(where: { $0.id.raw == paneId }) {
                if let ws = workspaceId { agents[idx].workspaceName = ws }
                if let tab = tabId { agents[idx].tabName = tab }
            }
        case .paneUpdated(let info):
            // Full pane state from the real `pane_updated` event. herdmgr's
            // status table only tracks the fields buildAgentList/printTable
            // use, so just keep status/seq in sync for an existing row.
            guard let idx = agents.firstIndex(where: { $0.id.raw == info.paneId }) else { return }
            let newStatus = AgentStatus(rawValue: info.agentStatus) ?? .unknown
            if newStatus != agents[idx].status {
                agents[idx].enteredAt = Date()
            }
            agents[idx].status = newStatus
            agents[idx].stateChangeSeq = info.stateChangeSeq
            agents[idx].verdict = verdict(for: newStatus)
        case .paneFocused:
            // herdmgr's plain table doesn't track focus — nothing to update.
            break
        case .paneExited(let paneId):
            agents.removeAll { $0.id.raw == paneId }
        case .workspacesChanged:
            // Labels changed; herdmgr's live loop doesn't re-fetch a full
            // snapshot mid-stream, so just note it happened.
            print("(workspace/tab labels changed)")
        case .connected, .disconnected, .ignored:
            break
        }
    }

    private func verdict(for status: AgentStatus) -> Verdict {
        switch status {
        case .blocked:
            return .awaitingInput(BlockClassification(
                kind: .unknownBlock, since: Date(), summary: "blocked"
            ))
        case .idle, .working: return .healthy
        case .done: return .healthy
        case .unknown: return .unclassifiable(reason: "unknown status")
        }
    }

    // MARK: - Display

    private func printTable(_ agents: [Agent], showAll: Bool) {
        let list: [Agent]
        if showAll {
            list = agents.sorted { $0.id.raw < $1.id.raw }
        } else {
            list = agents.filter {
                $0.status == .blocked || $0.verdict.isSilent || $0.status == .done
            }.sorted { $0.enteredAt < $1.enteredAt }
        }

        if list.isEmpty {
            print("No agents requiring attention. Use --show-all to see all agents.")
            return
        }

        // Header
        print("\(pad("STATUS", to: 8)) \(pad("DWELL", to: 10)) \(pad("KIND", to: 12)) \(pad("NAME", to: 20)) \(pad("WORKSPACE/TAB", to: 20))")
        print(String(repeating: "-", count: 72))

        for agent in list {
            let glyph = statusGlyph(agent.status, verdict: agent.verdict)
            let dwell = formatDwell(Date().timeIntervalSince(agent.enteredAt))
            let kind = agentKindString(agent.kind)
            let name = truncate(agent.displayName.isEmpty ? agent.name : agent.displayName, 20)
            let location = "\(agent.workspaceName)/\(agent.tabName)"

            print("\(pad(glyph, to: 8)) \(pad(dwell, to: 10)) \(pad(kind, to: 12)) \(pad(name, to: 20)) \(pad(location, to: 20))")
        }

        print()
        let total = agents.count
        let blocked = agents.filter { $0.status == .blocked }.count
        let done = agents.filter { $0.status == .done }.count
        print("\(total) agents | \(blocked) blocked | \(done) done")
    }

    private func statusGlyph(_ status: AgentStatus, verdict: Verdict) -> String {
        switch status {
        case .blocked: return "🔴"
        case .done: return "🔵"
        case .idle: return "🟢"
        case .working:
            if verdict.isSilent { return "🟠" }
            return "🟢"
        case .unknown: return "⚪"
        }
    }

    private func formatDwell(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return "\(hours)h\(minutes % 60)m"
    }

    private func agentKindString(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        case .aider: return "aider"
        case .gemini: return "gemini"
        case .custom(let s): return String(s.prefix(12))
        }
    }

    private func truncate(_ s: String, _ maxLen: Int) -> String {
        if s.count <= maxLen { return s }
        return String(s.prefix(maxLen - 1)) + "…"
    }
}
