import Foundation

// MARK: - Process-gone observation

/// What one process-list read says about a pane that is supposed to be
/// alive. `.unknown` means the read failed or came back empty; it is not
/// evidence the agent is running.
public enum ProcessGoneObservation: Sendable, Equatable {
    case gone(lastLine: String?)
    case running
    case unknown

    /// Stamp these reads onto rows. A crash replaces the row's verdict.
    /// A running read clears a crash back to the status verdict and leaves
    /// every other verdict alone. An unknown read, or an id that was not
    /// checked, changes nothing.
    public static func apply(
        _ observations: [AgentID: ProcessGoneObservation],
        to agents: [Agent],
        now: Date = Date()
    ) -> [Agent] {
        agents.map { agent in
            guard let observation = observations[agent.id] else { return agent }
            switch observation {
            case .gone(let lastLine):
                var updated = agent
                updated.verdict = .processGone(lastLine: lastLine)
                return updated
            case .running:
                guard agent.verdict.isProcessGone else { return agent }
                var updated = agent
                updated.verdict = HerdSnapshot.displayVerdict(for: agent.status, now: now)
                return updated
            case .unknown:
                return agent
            }
        }
    }
}

// MARK: - Diagnoser

/// The S1-S4 classifier. Precedence: S3 → S1 → S2 → S4.
///
/// - S3: Process gone — pane.process_info shows a bare shell while the agent
///       is supposed to be alive (working/blocked/unknown).
/// - S1: Awaiting input — status==blocked + agent.explain → matched_rule.id → BlockKind
/// - S2: Silent — status==working ∧ now−max(lastOutputAt, enteredAt) > threshold, enriched with CPU via `ps`
/// - S4: Unclassifiable — unknown status, or blocked with screen_detection_skipped → degraded classification.
///       Working (not silent), done, and idle are healthy and never reach S4.
public actor Diagnoser {

    public init() {}

    /// Diagnose a single agent. Returns a Verdict.
    /// - Parameters:
    ///   - agent: The agent to diagnose.
    ///   - adapter: The HerdrAdapter to use for herdr API calls.
    ///   - silentThreshold: Optional per-agent override (seconds) for the S2
    ///     silent threshold. When nil, falls back to `Self.silentThreshold(for:)`
    ///     (the kind-based default). Callers with a SettingsStore pass the
    ///     per-pane override here.
    /// - Returns: A Verdict describing the agent's current state.
    public func diagnose(
        agent: Agent,
        adapter: HerdrAdapter,
        silentThreshold: TimeInterval? = nil
    ) async -> Verdict {
        let paneId = agent.id.raw  // herdr uses full session-qualified IDs (e.g. "w5:p2")

        // S3: Process gone — check first, highest priority.
        // An unreadable process list is not proof the agent is alive, so
        // only a confirmed bare shell returns here. Anything else falls
        // through to the status checks.
        if case .gone(let lastLine) = await checkProcessGone(agent: agent, paneId: paneId, adapter: adapter) {
            return .processGone(lastLine: lastLine)
        }

        // S1: Awaiting input — blocked + explain
        if let s1 = await checkAwaitingInput(agent: agent, paneId: paneId, adapter: adapter) {
            return s1
        }

        // S2: Silent — working but no output for too long
        if let s2 = await checkSilent(
            agent: agent,
            paneId: paneId,
            adapter: adapter,
            silentThreshold: silentThreshold
        ) {
            return s2
        }

        // Working (and not silent, not gone), finished, and idle are known
        // states with nothing left to classify. They must not fall through
        // to S4, which stamped every active agent with "state: working" or
        // "working but unclassifiable" on each diagnosis pass.
        switch agent.status {
        case .working, .done, .idle:
            return .healthy
        case .blocked, .unknown:
            break
        }

        // S4: Unclassifiable — unknown status, or a blocked pane whose
        // screen detection was skipped so S1 could not classify it.
        return await checkUnclassifiable(agent: agent, paneId: paneId, adapter: adapter)
    }

    // MARK: - S3: Process Gone

    /// One process-list read for callers that stamp the crash onto a row
    /// and leave every other verdict alone. `.unknown` is not "alive":
    /// a failed or empty read must not clear a crash already on the row.
    public func observeProcessGone(agent: Agent, adapter: HerdrAdapter) async -> ProcessGoneObservation {
        await checkProcessGone(agent: agent, paneId: agent.id.raw, adapter: adapter)
    }

    /// Check if the agent's process is gone.
    ///
    /// A *finished* (`done`) or `idle` agent has legitimately returned to the
    /// shell — that is the expected end state, NOT a crash, so we never flag it.
    /// We only consider agents that are supposed to be alive (working/blocked/
    /// unknown), and even then we corroborate: the foreground must be a bare
    /// shell. If a non-shell process (e.g. `node`/`bun` hosting the agent) is
    /// in the foreground, the read says the agent is still running. An empty
    /// list or a failed read is `.unknown` — not proof either way.
    private func checkProcessGone(agent: Agent, paneId: String, adapter: HerdrAdapter) async -> ProcessGoneObservation {
        guard agent.status == .working || agent.status == .blocked || agent.status == .unknown else {
            return .running
        }

        do {
            let procInfo = try await adapter.processInfo(paneId: paneId)
            let procs = procInfo.foregroundProcesses

            // Empty foreground = we couldn't read it; inconclusive, don't alarm.
            guard !procs.isEmpty else { return .unknown }

            // Corroborate: only a bare shell in the foreground means the agent's
            // process group vanished. Anything else (a runtime hosting it, or a
            // shell whose argv is launching that agent) means the agent is still
            // there. `name` and `argv0` are that one process; either one naming
            // the shell is enough.
            let foregroundIsBareShell = procs.allSatisfy { Self.isBareShell($0) }
            guard foregroundIsBareShell else { return .running }

            let lastLine = procs.last.map { "\($0.name) (pid \($0.pid))" }
            return .gone(lastLine: lastLine)
        } catch {
            // If we can't get process info, we can't determine S3.
            return .unknown
        }
    }

    // MARK: - S1: Awaiting Input

    /// Check if the agent is blocked and classify the block kind.
    private func checkAwaitingInput(agent: Agent, paneId: String, adapter: HerdrAdapter) async -> Verdict? {
        guard agent.status == .blocked else { return nil }

        do {
            let explain = try await adapter.explain(paneId: paneId)

            // If screen_detection_skipped, this falls to S4 (e.g., OpenCode hook-reported panes)
            if explain.screenDetectionSkipped {
                return nil // fall through to S4
            }

            let ruleId = explain.matchedRuleId ?? ""
            let kind = BlockKind.from(ruleId: ruleId)
            let since = agent.enteredAt
            let summary = kind.summary

            // If we have a more specific summary from the explain state, use it
            let detailSummary: String
            if let state = explain.state, !state.isEmpty {
                detailSummary = summary
            } else {
                detailSummary = summary
            }

            let classification = BlockClassification(
                kind: kind,
                since: since,
                summary: detailSummary
            )
            return .awaitingInput(classification)
        } catch {
            // If explain fails, return a generic awaitingInput with unknownBlock
            let classification = BlockClassification(
                kind: .unknownBlock,
                since: agent.enteredAt,
                summary: "blocked (explain failed)"
            )
            return .awaitingInput(classification)
        }
    }

    // MARK: - S2: Silent

    /// Check if the agent is working but silent (no output for too long).
    /// - Parameter silentThreshold: Per-agent override (seconds). When nil,
    ///   falls back to the kind-based default.
    private func checkSilent(
        agent: Agent,
        paneId: String,
        adapter: HerdrAdapter,
        silentThreshold: TimeInterval? = nil
    ) async -> Verdict? {
        guard agent.status == .working else { return nil }

        let threshold = silentThreshold ?? Self.silentThreshold(for: agent.kind)
        let lastOutput = Self.silentClockStart(for: agent)
        let elapsed = Date().timeIntervalSince(lastOutput)

        guard elapsed > threshold else { return nil }

        // Enrich with CPU state
        let cpu = await cpuState(for: agent, paneId: paneId, adapter: adapter)

        return .silent(since: lastOutput, cpu: cpu)
    }

    /// Silence is counted from the later of the last output change and the
    /// start of the current status episode. `lastOutputAt` survives status
    /// changes, so a pane approved after a 20-minute prompt would otherwise
    /// read as 20 minutes silent the moment it went back to working — and
    /// the working transition triggers an immediate diagnosis + notification.
    static func silentClockStart(for agent: Agent) -> Date {
        guard let lastOutput = agent.lastOutputAt else { return agent.enteredAt }
        return max(lastOutput, agent.enteredAt)
    }

    // MARK: - S4: Unclassifiable

    /// Return an unclassifiable verdict with whatever info we have.
    private func checkUnclassifiable(agent: Agent, paneId: String, adapter: HerdrAdapter) async -> Verdict {
        // Try to get explain info for a better reason
        do {
            let explain = try await adapter.explain(paneId: paneId)
            if explain.screenDetectionSkipped {
                return .unclassifiable(reason: "screen detection skipped (hook-reported agent)")
            }
            if let state = explain.state, !state.isEmpty {
                return .unclassifiable(reason: "state: \(state)")
            }
        } catch {
            // fall through
        }

        switch agent.status {
        case .unknown:
            return .unclassifiable(reason: "unknown status")
        default:
            return .unclassifiable(reason: "status: \(agent.status.rawValue)")
        }
    }

    // MARK: - CPU State

    /// Get the CPU state for an agent by running `ps -o %cpu= -p <pid>`.
    ///
    /// Measures the FOREGROUND agent process (the topmost runtime like
    /// `node`/`bun` hosting the agent), NOT the pane's shell. The shell
    /// (zsh/bash) is idle by design while the agent runs — measuring it
    /// mislabels a busy agent as stalled and an idle shell as healthy.
    ///
    /// When `foregroundProcesses` is empty (unreadable / no foreground
    /// process reported), we return `.unknown` rather than falling back
    /// to `shellPid`, because the shell's CPU is not a signal of agent
    /// activity.
    private func cpuState(for agent: Agent, paneId: String, adapter: HerdrAdapter) async -> CPUState {
        let pid: Int32?
        do {
            let procInfo = try await adapter.processInfo(paneId: paneId)
            // Topmost foreground process = the agent runtime (node/bun/etc.).
            pid = procInfo.foregroundProcesses.last?.pid
        } catch {
            return .unknown
        }

        guard let pid, pid > 0 else { return .unknown }

        // Run ps to get CPU usage
        return await cpuPercent(pid: pid)
    }

    /// Run `ps -o %cpu= -p <pid>` and classify the result.
    private func cpuPercent(pid: Int32) async -> CPUState {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/ps")
                process.arguments = ["-o", "%cpu=", "-p", String(pid)]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if let cpuPercent = Double(output) {
                        continuation.resume(returning: CPUState.from(cpuPercent: cpuPercent))
                    } else {
                        continuation.resume(returning: .unknown)
                    }
                } catch {
                    continuation.resume(returning: .unknown)
                }
            }
        }
    }

    // MARK: - Helpers

    /// True when this foreground process is the pane's own shell and is
    /// not the program that is launching the agent. See `ShellForeground`.
    private static func isBareShell(_ process: ForegroundProcess) -> Bool {
        ShellForeground.isBare(process)
    }

    /// Silent threshold for an agent kind.
    /// Coding agents: 5 minutes. Build/test agents: 15 minutes.
    public static func silentThreshold(for kind: AgentKind) -> TimeInterval {
        // All known coding agents use 5 minutes
        switch kind {
        case .claude, .codex, .opencode, .aider, .gemini:
            return 5 * 60 // 5 minutes
        case .custom:
            return 5 * 60 // default to 5 minutes
        }
    }
}

/// Whether one foreground process is the shell a dead agent leaves.
///
/// herdr starts a pane with `$SHELL`, or with `[terminal] default_shell`.
/// The documented example of that setting is `nu`. PowerShell is `pwsh`
/// or `powershell`, including the `.exe` a remote pane reports. `csh` is
/// the shell beside `tcsh`. A login shell's argv0 is `-nu` or a path, and
/// the comm name can be the other spelling of the same binary, so either
/// field counts. A runtime (`node`, `tmux`) does not: the agent may still
/// be the program that name is running.
///
/// A shell is not bare when its argument vector is launching an agent.
/// herdr identifies `sh /path/to/pi` as Pi and `powershell -File claude.ps1`
/// as Claude. The comm on both is the shell, so a name-only check marked
/// a live agent gone. `argv` is that vector. `cmdline` is used only when
/// `argv` was not sent. `dash`, `ksh`, `csh`, and `tcsh` run a script the
/// same way `sh` does, and they are already the shells a dead agent can
/// leave, so a path after the flags is the program. `bash -o` and `bash
/// -O` take the next word as the option name; `bash --rcfile` takes a
/// file. Treating that word as the program marked `bash -o errexit
/// claude` gone, and treated the rcfile as the program when claude was
/// the next word. `sh -c` stays bare, including when a later argument
/// names an agent: that flag's operand is a script, not a program path,
/// and herdr does not treat it as the agent either. `nu` is not unwrapped.
/// `cmd` is a shell only when an argument vector is present, so a payload
/// that omits `argv` and `cmdline` does not start calling every `cmd.exe`
/// a crash. One non-shell in the group keeps the row alive; the caller
/// applies that.
private enum ShellForeground {
    private enum Kind {
        case posix
        case powershell
        case cmd
    }

    static func isBare(_ process: ForegroundProcess) -> Bool {
        if isNamedShell(process.name) || isNamedShell(process.argv0) {
            return !launchesKnownAgent(process)
        }
        // `cmd` is the Windows prompt a crashed agent leaves, and it is
        // also the wrapper `cmd /C codex.cmd`. Without the argument vector
        // those two are the same name, so the old payload stays "running".
        if isCmd(process), launchArguments(process) != nil {
            return !launchesKnownAgent(process)
        }
        return false
    }

    private static func isNamedShell(_ name: String?) -> Bool {
        guard let name else { return false }
        return [
            "zsh", "bash", "sh", "fish", "tcsh", "ksh", "dash", "csh",
            "nu", "pwsh", "powershell", "login",
        ].contains(shellBase(name))
    }

    private static func isCmd(_ process: ForegroundProcess) -> Bool {
        shellBase(process.name) == "cmd" || shellBase(process.argv0 ?? "") == "cmd"
    }

    /// Basename herdr's agent lookup accepts as one token, after a path
    /// and one of `.exe`, `.cmd`, `.bat`, `.ps1`, `.js`. A leading `-` is
    /// a login shell's argv0, not a program. `muse-bin-<version>` is the
    /// launcher herdr matches separately. Names with a space are not a
    /// basename.
    private static let knownAgentPrograms: Set<String> = [
        "pi", "claude", "claude-code", "codex", "gemini", "cursor", "cursor-agent",
        "devin", "devin-cli", "agy", "antigravity", "antigravity-cli",
        "cline", ".cline", "omp", "mastracode", "mastra-code",
        "opencode", "opencode2", "open-code", "copilot", "github-copilot", "ghcs",
        "kimi", "kimi-code", "kiro", "kiro-cli", "droid", "amp", "amp-local",
        "grok", "grok-build", "hermes", "hermes-agent", "kilo", "kilo-code",
        "qodercli", "qoderclicn", "qoder", "qodercn", "qwen", "qwen-code",
        "letta", "letta-code", "maki", "muse", "muse-code", "muse-cli",
    ]

    private static func launchesKnownAgent(_ process: ForegroundProcess) -> Bool {
        guard let kind = unwrappingKind(process), let args = launchArguments(process) else {
            return false
        }
        switch kind {
        case .posix:
            return posixLaunchesAgent(args)
        case .powershell:
            return powershellLaunchesAgent(args)
        case .cmd:
            return cmdLaunchesAgent(args)
        }
    }

    /// The shell whose rules apply. `argv[0]` wins over the comm name,
    /// because a login argv0 can be `-zsh` while the comm is `MainThread`.
    /// `dash`, `ksh`, `csh`, and `tcsh` use the same script rule as `sh`:
    /// the first word that is not a flag is the program. `nu` is not here.
    /// A later path is not how that pane is still an agent.
    private static func unwrappingKind(_ process: ForegroundProcess) -> Kind? {
        let args = launchArguments(process)
        let candidates = [args?.first, process.argv0, process.name]
        for candidate in candidates {
            guard let candidate else { continue }
            switch shellBase(candidate) {
            case "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh":
                return .posix
            case "powershell", "pwsh":
                return .powershell
            case "cmd":
                return .cmd
            default:
                break
            }
        }
        return nil
    }

    /// `argv` when herdr sent it. Otherwise the words of `cmdline`.
    /// A present `argv` is the whole vector, so a cmdline that disagrees
    /// with it is not a second source.
    private static func launchArguments(_ process: ForegroundProcess) -> [String]? {
        if let argv = process.argv, !argv.isEmpty {
            return argv
        }
        guard let cmdline = process.cmdline?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !cmdline.isEmpty else {
            return nil
        }
        let parts = cmdline.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return parts.isEmpty ? nil : parts
    }

    /// Skip the shell itself. `-c` (and a short cluster that starts with
    /// it, such as `-cl`) is an eval, so the next word is not a program.
    /// `--` ends the flags. `-o` and `-O` on bash, zsh, ksh, and sh take
    /// the next word as an option name; dash and fish do the same for
    /// `-o`. `--rcfile` and `--init-file` on bash and sh take a file.
    /// Any other flag is skipped and does not consume the following word.
    /// The first word that is not a flag is the program. csh and tcsh
    /// have no option flag that takes a value, so `-o` there is only a
    /// flag and the next word can still be the program.
    private static func posixLaunchesAgent(_ args: [String]) -> Bool {
        let shell = args.first.map { shellBase($0) } ?? ""
        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                guard index + 1 < args.count else { return false }
                return isKnownAgentProgram(args[index + 1])
            }
            if isPosixEval(arg) { return false }
            if posixOptionTakesValue(arg, shell: shell) {
                index += 2
                continue
            }
            if arg.hasPrefix("-") {
                index += 1
                continue
            }
            return isKnownAgentProgram(arg)
        }
        return false
    }

    /// A flag whose next word is not the program. The set is the shell
    /// that is actually in `argv[0]`, so `csh -o` does not swallow a path
    /// and `dash` does not treat `-O` as an option name.
    private static func posixOptionTakesValue(_ arg: String, shell: String) -> Bool {
        switch arg {
        case "-o":
            return shell == "sh" || shell == "bash" || shell == "zsh"
                || shell == "ksh" || shell == "dash" || shell == "fish"
        case "-O":
            return shell == "sh" || shell == "bash" || shell == "zsh" || shell == "ksh"
        case "--rcfile", "--init-file":
            return shell == "sh" || shell == "bash"
        default:
            return false
        }
    }

    private static func isPosixEval(_ arg: String) -> Bool {
        if arg == "-c" { return true }
        return arg.hasPrefix("-c") && !arg.hasPrefix("--") && arg.count > 2
    }

    /// `-File` is the script. `-Command` / `-c` is a command line, and the
    /// first program token of that line is the agent. `-EncodedCommand`
    /// stays a shell: the blob is not decoded. A flag herdr treats as
    /// taking a value consumes the next word, so the directory is not the
    /// program. A path that is already an agent program counts before a
    /// leading `/` is treated as a switch.
    private static func powershellLaunchesAgent(_ args: [String]) -> Bool {
        let valueFlags: Set<String> = [
            "-configurationname", "-executionpolicy", "-outputformat",
            "-psconsolefile", "-version", "-windowstyle", "-workingdirectory",
        ]
        var index = 1
        while index < args.count {
            let raw = trimQuotes(args[index])
            if isKnownAgentProgram(raw) { return true }
            let flag = raw.lowercased()
            switch flag {
            case "-file", "-f", "/file":
                guard index + 1 < args.count else { return false }
                return isKnownAgentProgram(args[index + 1])
            case "-command", "-c", "/command", "/c":
                guard index + 1 < args.count else { return false }
                return commandTextIsAgent(args[index + 1])
            case "-encodedcommand", "-enc", "/encodedcommand", "/enc":
                return false
            default:
                if valueFlags.contains(flag) {
                    index += 2
                    continue
                }
                if flag.hasPrefix("-") || flag.hasPrefix("/") {
                    index += 1
                    continue
                }
                return false
            }
        }
        return false
    }

    /// `/C` and `/K` are the command. The other switches herdr skips are
    /// not a program. A word that is neither is not an agent either:
    /// `cmd` does not take a positional script path.
    private static func cmdLaunchesAgent(_ args: [String]) -> Bool {
        let skipped: Set<String> = [
            "/d", "/s", "/q", "/a", "/u",
            "/e:on", "/e:off", "/f:on", "/f:off", "/v:on", "/v:off",
        ]
        var index = 1
        while index < args.count {
            let flag = trimQuotes(args[index]).lowercased()
            if flag == "/c" || flag == "/k" {
                guard index + 1 < args.count else { return false }
                return commandTextIsAgent(args[index + 1])
            }
            if skipped.contains(flag) {
                index += 1
                continue
            }
            index += 1
        }
        return false
    }

    /// The first program word of a `-Command` or `/C` string. `&`, `.`,
    /// and `call` are invocation noise. A quoted word stays one token.
    private static func commandTextIsAgent(_ command: String) -> Bool {
        var rest = command.trimmingCharacters(in: .whitespacesAndNewlines)
        while !rest.isEmpty {
            let (token, next) = commandToken(rest)
            if token.isEmpty { return false }
            let bare = trimQuotes(token)
            if bare.caseInsensitiveCompare("&") == .orderedSame
                || bare == "."
                || bare.caseInsensitiveCompare("call") == .orderedSame {
                let trimmedNext = next.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedNext == rest { return false }
                rest = trimmedNext
                continue
            }
            return isKnownAgentProgram(bare)
        }
        return false
    }

    private static func commandToken(_ input: String) -> (String, String) {
        guard let first = input.first else { return ("", "") }
        if first == "\"" || first == "'" {
            let start = input.index(after: input.startIndex)
            if let end = input[start...].firstIndex(of: first) {
                let token = String(input[start..<end])
                let after = input.index(after: end)
                return (token, String(input[after...]))
            }
            return (String(input[start...]), "")
        }
        if let end = input.firstIndex(where: { $0.isWhitespace }) {
            return (String(input[..<end]), String(input[end...]))
        }
        return (input, "")
    }

    private static func isKnownAgentProgram(_ token: String) -> Bool {
        let trimmed = trimQuotes(token).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return false }
        let base = agentBase(trimmed)
        if knownAgentPrograms.contains(base) { return true }
        guard base.hasPrefix("muse-bin-") else { return false }
        let rest = base.dropFirst("muse-bin-".count)
        guard let scalar = rest.unicodeScalars.first else { return false }
        return scalar.value >= 48 && scalar.value <= 57
    }

    private static func trimQuotes(_ token: String) -> String {
        guard token.count >= 2,
              let first = token.first, let last = token.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return token
        }
        return String(token.dropFirst().dropLast())
    }

    /// Shell basename. One leading `-` is a login argv0. Only `.exe` is
    /// removed: pass 71 matched `powershell.exe` and `Pwsh.EXE`, and a
    /// `.ps1` or `.cmd` name is not that binary.
    private static func shellBase(_ name: String) -> String {
        var base = pathBase(name)
        if base.hasPrefix("-") { base.removeFirst() }
        base = base.lowercased()
        if base.hasSuffix(".exe"), base.count > 4 {
            base.removeLast(4)
        }
        return base
    }

    /// Program basename for an agent herdr would recognize. No login
    /// dash: a token that starts with `-` is a flag and was already
    /// refused. One of the suffixes herdr strips, and only that one.
    private static func agentBase(_ name: String) -> String {
        var base = pathBase(name).lowercased()
        for suffix in [".exe", ".cmd", ".bat", ".ps1", ".js"] {
            if base.hasSuffix(suffix), base.count > suffix.count {
                base.removeLast(suffix.count)
                break
            }
        }
        return base
    }

    private static func pathBase(_ name: String) -> String {
        let afterSlash = name.split(separator: Character("/")).last.map(String.init) ?? name
        return afterSlash.split(separator: Character("\\")).last.map(String.init) ?? afterSlash
    }
}
