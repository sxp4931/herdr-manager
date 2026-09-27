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

private enum LiveWake: Sendable {
    case event(HerdrEvent)
    case tick
    case ended
}

// MARK: - CLI Command

@main
struct HerdmgrCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "herdmgr",
        abstract: "Herdr Manager CLI — monitor AI coding agents",
        discussion: """
            Without --socket, the herdr socket is resolved from HERDR_SOCKET_PATH, \
            then HERDR_SESSION, then $XDG_CONFIG_HOME/herdr/herdr.sock, \
            then ~/.config/herdr/herdr.sock.
            """
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
            FileHandle.standardError.write(
                Data(LiveHerdrAdapter.missingSocketMessage(resolvedPath: socketPath).utf8)
            )
            FileHandle.standardError.write(Data("\n".utf8))
            throw ExitCode.failure
        }

        let adapter = LiveHerdrAdapter(socketPath: socketPath)

        do {
            try await adapter.connect()
        } catch {
            FileHandle.standardError.write("Error connecting to herdr: \(error)\n".data(using: .utf8)!)
            FileHandle.standardError.write(Data(LiveHerdrAdapter.socketHint(resolvedPath: socketPath).utf8))
            FileHandle.standardError.write(Data("\n".utf8))
            throw ExitCode.failure
        }

        // Take initial snapshot from agent.list (authoritative agents + seq)
        // merged with session.snapshot labels — not session.snapshot panes,
        // which omit seq and can include plain shells.
        let herd: HerdSnapshot
        do {
            herd = try await adapter.herdSnapshot()
        } catch {
            FileHandle.standardError.write("Error taking snapshot: \(error)\n".data(using: .utf8)!)
            FileHandle.standardError.write(Data(LiveHerdrAdapter.socketHint(resolvedPath: socketPath).utf8))
            FileHandle.standardError.write(Data("\n".utf8))
            throw ExitCode.failure
        }

        if let protocolLine = LiveHerdrAdapter.protocolStatusLine(for: adapter.health()) {
            FileHandle.standardError.write(Data("\(protocolLine)\n".utf8))
        }

        var live = HerdLiveTable(herd: herd, agents: herd.displayAgents())
        let diagnoser = Diagnoser()
        // herdr keeps the last status after a process dies. The table's
        // crash mark comes from the process list, not from that status.
        let initialRead = await processGoneObservations(
            for: live.agents, adapter: adapter, diagnoser: diagnoser
        )
        live.applyProcessGone(initialRead)

        if json {
            let output = live.agents.map { agent in
                [
                    "id": agent.id.raw,
                    "status": agent.status.rawValue,
                    "kind": agentKindString(agent.kind),
                    "name": agent.name,
                    "workspace": agent.workspaceName,
                    "tab": agent.tabName,
                    "needs_you": AttentionTriage.needsYou(agent) ? "true" : "false",
                    "attention": AttentionTriage.kind(for: agent).rawValue,
                    "priority": String(AttentionTriage.priority(agent)),
                    "state_change_seq": String(agent.stateChangeSeq),
                ] as [String: String]
            }
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        // Live table mode
        printTable(live.agents, showAll: showAll)

        // Set up signal handling for graceful exit
        signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler {
            print("\nExiting...")
            Darwin.exit(0)
        }
        signalSource.resume()

        await watchLiveTable(
            startingFrom: live, adapter: adapter, diagnoser: diagnoser, socketPath: socketPath
        )
    }

    /// Subscribe, and re-read the process list on a 15s tick — the same
    /// cadence as the menu bar's diagnosis pass. A dead process often emits
    /// nothing, so the table cannot wait for the next pane event.
    ///
    /// Silence is not classified here. A full diagnose would time it from
    /// `enteredAt`, and this table has no output clock, so a busy agent
    /// would read as quiet once the episode outlasted the threshold.
    private func watchLiveTable(
        startingFrom initial: HerdLiveTable,
        adapter: LiveHerdrAdapter,
        diagnoser: Diagnoser,
        socketPath: String
    ) async {
        var live = initial
        let eventStream = adapter.events()
        let (wakes, continuation) = AsyncStream.makeStream(of: LiveWake.self)
        let eventsTask = Task {
            for await event in eventStream {
                continuation.yield(.event(event))
            }
            continuation.yield(.ended)
            continuation.finish()
        }
        // 15s. Same cadence as Shepherd's diagnosis pass.
        let refreshEvery: UInt64 = 15_000_000_000
        let ticksTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: refreshEvery)
                if Task.isCancelled { break }
                continuation.yield(.tick)
            }
        }
        defer {
            eventsTask.cancel()
            ticksTask.cancel()
            continuation.finish()
        }

        for await wake in wakes {
            switch wake {
            case .ended:
                FileHandle.standardError.write(
                    Data("Event stream ended. \(LiveHerdrAdapter.socketHint(resolvedPath: socketPath))\n".utf8)
                )
                return
            case .tick:
                break
            case .event(let event):
                if case .workspacesChanged = event {
                    // Label churn (tab focus, rename) refetches so names stay
                    // current, and same-id episodes keep their dwell. A move
                    // also arrives as one of these events, before pane.moved
                    // and already under the new pane id. Remembering the
                    // pre-refetch rows lets that move put the dwell back.
                    let refreshed = try? await adapter.herdSnapshot()
                    live.noteLayoutRefresh(refreshed)
                } else {
                    live.apply(event)
                }
            }
            let observations = await processGoneObservations(
                for: live.agents, adapter: adapter, diagnoser: diagnoser
            )
            live.applyProcessGone(observations)
            print("\u{001B}[2J\u{001B}[H")
            printTable(live.agents, showAll: showAll)
        }
    }

    private func processGoneObservations(
        for agents: [Agent],
        adapter: HerdrAdapter,
        diagnoser: Diagnoser
    ) async -> [AgentID: ProcessGoneObservation] {
        var observations: [AgentID: ProcessGoneObservation] = [:]
        for agent in agents {
            observations[agent.id] = await diagnoser.observeProcessGone(agent: agent, adapter: adapter)
        }
        return observations
    }

    private func resolveSocketPath() -> String {
        if let socket { return socket }
        return LiveHerdrAdapter.resolveSocketPath()
    }

    // MARK: - Display

    private func printTable(_ agents: [Agent], showAll: Bool) {
        let list: [Agent]
        if showAll {
            list = agents.sorted { $0.id.raw < $1.id.raw }
        } else {
            list = agents.filter { AttentionTriage.attentionWorthy($0) }
                .sorted(by: AttentionTriage.ranksBefore)
        }

        if list.isEmpty {
            print("No agents requiring attention. Use --show-all to see all agents.")
            return
        }

        // Header
        print("\(pad("STATUS", to: 8)) \(pad("DWELL", to: 10)) \(pad("KIND", to: 12)) \(pad("NAME", to: 20)) \(pad("WORKSPACE/TAB", to: 20))")
        print(String(repeating: "-", count: 72))

        for agent in list {
            let glyph = AttentionTriage.statusMark(for: agent)
            let dwell = formatDwell(Date().timeIntervalSince(agent.enteredAt))
            let kind = agentKindString(agent.kind)
            let name = truncate(agent.displayName.isEmpty ? agent.name : agent.displayName, 20)
            let location = "\(agent.workspaceName)/\(agent.tabName)"

            print("\(pad(glyph, to: 8)) \(pad(dwell, to: 10)) \(pad(kind, to: 12)) \(pad(name, to: 20)) \(pad(location, to: 20))")
        }

        print()
        print(AttentionTriage.statusFooter(
            agentCount: agents.count,
            counts: AttentionTriage.counts(agents)
        ))
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
