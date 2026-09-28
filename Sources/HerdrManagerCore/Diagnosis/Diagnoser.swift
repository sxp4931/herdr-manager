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
    /// Measures the foreground agent, not the pane's shell. The shell is
    /// idle while `node` or `bun` runs the agent, and herdr's process list
    /// is not ordered so the agent is last. Measuring the shell mislabels
    /// a busy agent as stalled. `cpuSamplePid` picks the pid. An empty
    /// list, a failed read, or a group that is only a bare shell is
    /// `.unknown`: the shell's CPU is not a signal of agent activity, and
    /// `shellPid` is that same idle process.
    private func cpuState(for agent: Agent, paneId: String, adapter: HerdrAdapter) async -> CPUState {
        let pid: Int32?
        do {
            let procInfo = try await adapter.processInfo(paneId: paneId)
            pid = Self.cpuSamplePid(
                procInfo.foregroundProcesses,
                foregroundProcessGroupId: procInfo.foregroundProcessGroupId
            )
        } catch {
            return .unknown
        }

        guard let pid else { return .unknown }

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

    /// Pid whose CPU a silence reading should trust. Nil when the group
    /// is empty or only a bare shell. `foregroundProcessGroupId` is
    /// `pane.process_info`'s leader, when herdr sent one. See
    /// `ShellForeground.cpuSamplePid`.
    static func cpuSamplePid(
        _ processes: [ForegroundProcess],
        foregroundProcessGroupId: Int32? = nil
    ) -> Int32? {
        ShellForeground.cpuSamplePid(
            processes,
            foregroundProcessGroupId: foregroundProcessGroupId
        )
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
/// the shell beside `tcsh`. herdr's login-shell list also names `ash` and
/// `mksh`, beside `dash` and `ksh`. herdr's pane-shell check also names
/// `elvish` and `xonsh`: a dead agent leaves that process in the foreground.
/// A login shell's argv0 is `-nu` or a path, and the comm name can be the
/// other spelling of the same binary, so either field counts. A runtime
/// (`node`, `tmux`) does not: the agent may still be the program that
/// name is running.
///
/// A shell is not bare when its argument vector is launching an agent.
/// herdr identifies `sh /path/to/pi` as Pi and `powershell -File claude.ps1`
/// as Claude. The comm on both is the shell, so a name-only check marked
/// a live agent gone. `pwsh -InputFormat Text -File claude.ps1` is that
/// same launch: `Text` is the format, not the program, and so are
/// `-ep Bypass`, `-o XML`, and `-wd C:\repo`. `argv` is that vector.
/// `cmdline` is used only when `argv` was not sent. `dash`, `ksh`, `csh`, `tcsh`, `ash`, and `mksh`
/// run a script the same way `sh` does. `bash -o` and `bash -O` take the
/// next word as the option name, including inside `-euo pipefail`, and
/// `bash --rcfile` takes a file. Treating that word as the program marked
/// `bash -euo pipefail claude` gone. fish's `-d`, `-p`, and `--profile`
/// take a value the same way. `sh -c` stays bare, including a cluster
/// that starts with `-c`, even when a later argument names an agent:
/// that flag's operand is a script, not a program path, and herdr does
/// not treat it as the agent either. A `c` later in the cluster does
/// not hide the program (`-xco pipefail claude` is still claude). `nu`,
/// `elvish`, and `xonsh` are not unwrapped: herdr does not read a script
/// path on those shells, so a later argument stays the prompt. A shell
/// whose program is an npm entrypoint herdr names (`dist/cli.js` for Pi,
/// omp, and Mastracode, `dist/index.js` for Qwen, `dist/main.mjs` for
/// Kimi) is that agent. Any other `cli.js` stays the prompt. An absolute
/// path whose own basename is not an agent is still that agent when the
/// file is a symlink to one: herdr canonicalizes it, and a `#!/bin/sh`
/// wrapper stays `sh` in the foreground with the link as its program.
/// A relative path is resolved from that process's `cwd`, which
/// `pane.process_info` reports, so `sh ./agent` is the same link.
/// `cmd` is a shell only when an argument vector is present, so a payload that
/// omits `argv` and `cmdline` does not start calling every `cmd.exe` a
/// crash. One
/// non-shell in the group keeps the row alive; the caller applies that.
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
            "zsh", "bash", "sh", "fish", "tcsh", "ksh", "dash", "ash", "mksh", "csh",
            "nu", "elvish", "xonsh", "pwsh", "powershell", "login",
        ].contains(shellBase(name))
    }

    private static func isCmd(_ process: ForegroundProcess) -> Bool {
        shellBase(process.name) == "cmd" || shellBase(process.argv0 ?? "") == "cmd"
    }

    /// Basename herdr's agent lookup accepts as one token, after a path
    /// and one of `.exe`, `.cmd`, `.bat`, `.ps1`, `.js`. A leading `-` is
    /// a login shell's argv0, not a program. `muse-bin-<version>` is the
    /// launcher herdr matches separately. The spaced names are the same
    /// lookup: `Kimi Code.exe` is Kimi, and so are `Qwen Code`, `Letta
    /// Code`, `Kilo Code`, `Mastra Code`, and `Devin CLI`. A longer
    /// basename is not one of those. `cli.js` is not one of these names.
    /// The npm entrypoints herdr still calls an agent are
    /// `isKnownPackageEntrypoint`.
    private static let knownAgentPrograms: Set<String> = [
        "pi", "claude", "claude-code", "codex", "gemini", "cursor", "cursor-agent",
        "devin", "devin-cli", "devin cli", "agy", "antigravity", "antigravity-cli",
        "cline", ".cline", "omp", "mastracode", "mastra-code", "mastra code",
        "opencode", "opencode2", "open-code", "copilot", "github-copilot", "ghcs",
        "kimi", "kimi-code", "kimi code", "kiro", "kiro-cli", "droid", "amp", "amp-local",
        "grok", "grok-build", "hermes", "hermes-agent", "kilo", "kilo-code", "kilo code",
        "qodercli", "qoderclicn", "qoder", "qodercn", "qwen", "qwen-code", "qwen code",
        "letta", "letta-code", "letta code", "maki", "muse", "muse-code", "muse-cli",
    ]

    private static func launchesKnownAgent(_ process: ForegroundProcess) -> Bool {
        guard let kind = unwrappingKind(process), let args = launchArguments(process) else {
            return false
        }
        let cwd = process.cwd
        switch kind {
        case .posix:
            return posixLaunchesAgent(args, cwd: cwd)
        case .powershell:
            return powershellLaunchesAgent(args, cwd: cwd)
        case .cmd:
            return cmdLaunchesAgent(args, cwd: cwd)
        }
    }

    /// The shell whose rules apply. `argv[0]` wins over the comm name,
    /// because a login argv0 can be `-zsh` while the comm is `MainThread`.
    /// `dash`, `ksh`, `csh`, `tcsh`, `ash`, and `mksh` use the same script
    /// rule as `sh`: the first word that is not a flag is the program.
    /// `nu`, `elvish`, and `xonsh` are not here. A later path is not how
    /// that pane is still an agent.
    private static func unwrappingKind(_ process: ForegroundProcess) -> Kind? {
        let args = launchArguments(process)
        let candidates = [args?.first, process.argv0, process.name]
        for candidate in candidates {
            guard let candidate else { continue }
            switch shellBase(candidate) {
            case "sh", "bash", "zsh", "fish", "dash", "ksh", "ash", "mksh", "csh", "tcsh":
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
    /// A `c` that is not the first letter (`-lc`, `-xco`) does not do
    /// that: `-lc claude` runs claude, and `-xco pipefail claude` uses
    /// `pipefail` as the `-o` name. `--` ends the flags. `-o` and `-O`
    /// take the next word on the shells that have that flag, even when
    /// more letters follow (`-euo pipefail`, `-oeu pipefail`). bash's
    /// `-oerrexit` is those letters plus the next word, not a glued name,
    /// and that next word is not the program. fish keeps an attached
    /// value in the cluster (`-d3`) and takes the next word only when
    /// the letter ends it.
    /// `--rcfile` and `--init-file` on bash and sh take a file. fish's
    /// debug, profile, and init-command flags take a value; `--debug=3`
    /// keeps its value in the same word. Any other flag is skipped. The
    /// first word that is not a flag is the program. csh and tcsh have
    /// no option flag that takes a value, so `-o` there is only a flag
    /// and the next word can still be the program. `ash` and `mksh` take
    /// `-o` and `+o`, and not `-O`.
    private static func posixLaunchesAgent(_ args: [String], cwd: String?) -> Bool {
        let shell = args.first.map { shellBase($0) } ?? ""
        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                guard index + 1 < args.count else { return false }
                return isKnownAgentProgram(args[index + 1], cwd: cwd)
            }
            if isPosixEval(arg) { return false }
            if posixOptionTakesValue(arg, shell: shell) {
                index += 2
                continue
            }
            if isOptionCluster(arg, shell: shell) {
                index += shortClusterConsumesNext(arg, shell: shell) ? 2 : 1
                continue
            }
            if arg.hasPrefix("-") {
                index += 1
                continue
            }
            return isKnownAgentProgram(arg, cwd: cwd)
        }
        return false
    }

    /// A flag whose next word is not the program. The set is the shell
    /// that is actually in `argv[0]`, so `csh -o` does not swallow a path
    /// and `dash` does not treat `-O` as an option name. `+o` turns the
    /// same option off on the POSIX shells. fish's `-o` is a debug file,
    /// not `+o`.
    private static func posixOptionTakesValue(_ arg: String, shell: String) -> Bool {
        switch arg {
        case "-o":
            return shellTakesMinusO(shell)
        case "+o":
            return shellTakesPlusO(shell)
        case "-O", "+O":
            return shellTakesCapitalO(shell)
        case "--rcfile", "--init-file":
            return shell == "sh" || shell == "bash"
        default:
            break
        }
        if shell == "fish" {
            switch arg {
            case "-C", "-p", "-d", "-f", "-D",
                 "--init-command", "--profile", "--profile-startup",
                 "--debug", "--debug-output", "--features", "--debug-stack-frames":
                return true
            default:
                break
            }
        }
        return false
    }

    /// `-o` / fish's debug-output file. `ash` and `mksh` are the POSIX
    /// shells beside `dash`: they take `-o` and do not take bash's `-O`.
    private static func shellTakesMinusO(_ shell: String) -> Bool {
        shell == "sh" || shell == "bash" || shell == "zsh"
            || shell == "ksh" || shell == "dash" || shell == "ash"
            || shell == "mksh" || shell == "fish"
    }

    /// `set +o` on the same shells, except fish. fish's `-o` is not that flag.
    private static func shellTakesPlusO(_ shell: String) -> Bool {
        shell == "sh" || shell == "bash" || shell == "zsh"
            || shell == "ksh" || shell == "dash" || shell == "ash"
            || shell == "mksh"
    }

    /// bash `-O` / `+O` shopt. dash, ash, mksh, fish, csh, and tcsh do not.
    private static func shellTakesCapitalO(_ shell: String) -> Bool {
        shell == "sh" || shell == "bash" || shell == "zsh" || shell == "ksh"
    }

    /// A short cluster of more than one letter: `-euo`, `+euo`, `-oerrexit`.
    /// A single `-o` is `posixOptionTakesValue`. A `+` cluster is only
    /// recognized on a shell that has `+o` or `+O`, so `csh +o` stays a
    /// plain word.
    private static func isOptionCluster(_ arg: String, shell: String) -> Bool {
        if arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 2 {
            return true
        }
        guard shellTakesPlusO(shell) || shellTakesCapitalO(shell) else { return false }
        guard arg.count > 2, arg.first == "+" else { return false }
        return arg.dropFirst().allSatisfy { isASCIILetter($0) }
    }

    /// True when the next argv is an option value.
    ///
    /// bash, dash, and the other `-o` shells take that value from the
    /// next word even when flag letters follow (`-oeu pipefail`, and
    /// `-oerrexit` does not glue the name on). fish's getopt keeps an
    /// attached value in the cluster (`-d3`), and takes the next word
    /// only when the letter ends it (`-d 3`, `-io file`).
    private static func shortClusterConsumesNext(_ arg: String, shell: String) -> Bool {
        guard let prefix = arg.first else { return false }
        let letters = arg.dropFirst()
        var index = letters.startIndex
        var consume = false
        while index < letters.endIndex {
            let letter = letters[index]
            let next = letters.index(after: index)
            if clusterLetterTakesValue(letter, prefix: prefix, shell: shell) {
                if shell == "fish" {
                    return next == letters.endIndex
                }
                consume = true
            }
            index = next
        }
        return consume
    }

    private static func clusterLetterTakesValue(
        _ letter: Character,
        prefix: Character,
        shell: String
    ) -> Bool {
        switch letter {
        case "o":
            return prefix == "-" ? shellTakesMinusO(shell) : shellTakesPlusO(shell)
        case "O":
            return shellTakesCapitalO(shell)
        case "C", "p", "d", "f", "D":
            return prefix == "-" && shell == "fish"
        default:
            return false
        }
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
    }

    private static func isPosixEval(_ arg: String) -> Bool {
        if arg == "-c" { return true }
        return arg.hasPrefix("-c") && !arg.hasPrefix("--") && arg.count > 2
    }

    /// `-File` is the script. `-Command` / `-c` is a command line, and the
    /// first program token of that line is the agent. `-CommandWithArgs`
    /// (`-cwa`) is that command: the words after it are arguments, not a
    /// second program. `-EncodedCommand` stays a shell, including `-e` and
    /// `-ec`: the blob is not decoded. A parameter that takes a value
    /// consumes the next word, so `Text`, `Bypass`, `XML`, and a directory
    /// are not the program. That includes `-InputFormat` (`-if`, `-inp`),
    /// `-OutputFormat` (`-o`, `-of`), `-ExecutionPolicy` (`-ep`, `-ex`),
    /// `-WindowStyle` (`-w`), `-WorkingDirectory` (`-wd`, `-wo`),
    /// `-SettingsFile` (`-settings`), `-ConfigurationName` (`-config`),
    /// `-ConfigurationFile`, and `-CustomPipeName`. A colon attaches the
    /// value to the flag (`-InputFormat:Text`, `-File:claude.ps1`). A
    /// `/File` from cmd.exe is the same flag as `-File`. A path that is
    /// already an agent program counts before a leading `/` is treated
    /// as a switch.
    private static func powershellLaunchesAgent(_ args: [String], cwd: String?) -> Bool {
        let valueFlags: Set<String> = [
            "-configurationname", "-config",
            "-configurationfile",
            "-custompipename",
            "-encodedarguments",
            "-executionpolicy", "-ex", "-ep",
            "-inputformat", "-inp", "-if",
            "-outputformat", "-o", "-of",
            "-psconsolefile",
            "-settingsfile", "-settings",
            "-version",
            "-windowstyle", "-w",
            "-workingdirectory", "-wd", "-wo",
        ]
        var index = 1
        while index < args.count {
            let raw = trimQuotes(args[index])
            if isKnownAgentProgram(raw, cwd: cwd) { return true }
            let (name, attached) = powershellParameter(raw)
            switch name {
            case "-file", "-f":
                if let attached {
                    return isKnownAgentProgram(attached, cwd: cwd)
                }
                guard index + 1 < args.count else { return false }
                return isKnownAgentProgram(args[index + 1], cwd: cwd)
            case "-command", "-c", "-commandwithargs", "-cwa":
                if let attached {
                    return commandTextIsAgent(attached, cwd: cwd)
                }
                guard index + 1 < args.count else { return false }
                return commandTextIsAgent(args[index + 1], cwd: cwd)
            case "-encodedcommand", "-enc", "-e", "-ec":
                return false
            default:
                if valueFlags.contains(name) {
                    index += attached == nil ? 2 : 1
                    continue
                }
                if name.hasPrefix("-") || raw.hasPrefix("/") {
                    index += 1
                    continue
                }
                return false
            }
        }
        return false
    }

    /// Host parameter name, and a value glued on with `:`.
    ///
    /// cmd.exe accepts `/File` as `-File`. A token with another separator
    /// (`/usr/bin/claude`, `C:\claude.ps1`) is a path, so the slash stays.
    /// The name and a colon-attached value are compared in lowercase.
    /// `isKnownAgentProgram` folds case again, so the fold does not hide a path.
    private static func powershellParameter(_ token: String) -> (name: String, attached: String?) {
        let trimmed = trimQuotes(token)
        let flag = powershellSwitch(trimmed)
        guard flag.hasPrefix("-"), let colon = flag.firstIndex(of: ":") else {
            return (flag, nil)
        }
        let name = String(flag[..<colon])
        guard name.count > 1 else { return (flag, nil) }
        // The value is sliced from `flag`, which is the same characters as
        // `trimmed` with case folded and a cmd `/` rewritten to `-`.
        // Agent matching folds case again, so the fold does not hide a path.
        let value = String(flag[flag.index(after: colon)...])
        return (name, value)
    }

    /// `-File` and `/File` share a name. A path does not.
    private static func powershellSwitch(_ token: String) -> String {
        guard let first = token.first else { return token.lowercased() }
        if first == "-" {
            return token.lowercased()
        }
        guard first == "/" else { return token.lowercased() }
        let rest = token.dropFirst()
        let name = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { String($0) } ?? String(rest)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else {
            return token.lowercased()
        }
        return "-" + token.dropFirst().lowercased()
    }

    /// `/C` and `/K` are the command. The other switches herdr skips are
    /// not a program. A word that is neither is not an agent either:
    /// `cmd` does not take a positional script path.
    private static func cmdLaunchesAgent(_ args: [String], cwd: String?) -> Bool {
        let skipped: Set<String> = [
            "/d", "/s", "/q", "/a", "/u",
            "/e:on", "/e:off", "/f:on", "/f:off", "/v:on", "/v:off",
        ]
        var index = 1
        while index < args.count {
            let flag = trimQuotes(args[index]).lowercased()
            if flag == "/c" || flag == "/k" {
                guard index + 1 < args.count else { return false }
                return commandTextIsAgent(args[index + 1], cwd: cwd)
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
    private static func commandTextIsAgent(_ command: String, cwd: String?) -> Bool {
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
            return isKnownAgentProgram(bare, cwd: cwd)
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

    private static func isKnownAgentProgram(_ token: String, cwd: String?) -> Bool {
        let trimmed = trimQuotes(token).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return false }
        if isKnownAgentBasename(agentBase(trimmed)) { return true }
        if isKnownPackageEntrypoint(trimmed) { return true }
        return isCanonicalAgentBasename(trimmed, cwd: cwd)
    }

    /// Basename herdr's lookup accepts, including `muse-bin-<version>`.
    private static func isKnownAgentBasename(_ base: String) -> Bool {
        if knownAgentPrograms.contains(base) { return true }
        guard base.hasPrefix("muse-bin-") else { return false }
        let rest = base.dropFirst("muse-bin-".count)
        guard let scalar = rest.unicodeScalars.first else { return false }
        return scalar.value >= 48 && scalar.value <= 57
    }

    /// Path herdr would `canonicalize` before the basename check.
    ///
    /// The link's own name is not the agent (`agent` → `cursor-agent`).
    /// A shebang script stays the shell in `pane.process_info`, with the
    /// link as the program argument, so the basename check alone called
    /// that pane a crash. An absolute path is that file. A relative path
    /// with a slash (`./agent`, `bin/agent`) is joined to this process's
    /// `cwd`, which is the directory herdr read for that pid, not
    /// Shepherd's. A bare name is a `PATH` lookup and is left alone. A
    /// missing path does not change its basename, and that name was
    /// already refused. The package-path check stays on the path herdr
    /// sent; canonicalizing does not search `node_modules` in the target.
    private static func isCanonicalAgentBasename(_ token: String, cwd: String?) -> Bool {
        guard let path = canonicalPath(token, cwd: cwd) else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let base = agentBase(resolved)
        guard base != agentBase(token) else { return false }
        return isKnownAgentBasename(base)
    }

    /// Absolute path, or a relative path joined to an absolute process
    /// cwd. A Windows path is not a file on this Mac. A name with no
    /// slash is not joined: `sh claude` is the basename check, and
    /// `cwd/claude` would be a different file.
    private static func canonicalPath(_ token: String, cwd: String?) -> String? {
        if token.hasPrefix("/") { return token }
        guard token.contains("/"), let cwd, cwd.hasPrefix("/") else { return nil }
        if token.contains(":") { return nil }
        var relative = token
        while relative.hasSuffix("/") { relative.removeLast() }
        let leaf = pathBase(relative)
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return nil }
        let prefix = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return prefix + "/" + relative
    }

    /// npm entrypoints whose basename is not the agent name.
    ///
    /// herdr's package-path check names these and no other `cli.js`:
    /// Pi is `@earendil-works/pi-coding-agent` `dist/cli.js` and
    /// `dist/bundle/cli.js`. omp is `@oh-my-pi/pi-coding-agent`
    /// `dist/cli.js`. Kimi is `@moonshot-ai/kimi-code` `dist/main.mjs`.
    /// Those four have to end the path. Qwen
    /// (`@qwen-code/qwen-code/dist/index.js`), Mastracode
    /// (`mastracode/dist/cli.js`), and Letta
    /// (`@letta-ai/letta-code/letta`) match anywhere in the path, after
    /// one of `.exe`, `.cmd`, `.bat`, `.ps1`, `.js` is removed from each
    /// component. `sh /tmp/cli.js` and `dist/cli.exe` are not any of them.
    private static func isKnownPackageEntrypoint(_ token: String) -> Bool {
        let components = token.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard !components.isEmpty else { return false }
        let suffixes: [[String]] = [
            ["node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js"],
            ["node_modules", "@earendil-works", "pi-coding-agent", "dist", "bundle", "cli.js"],
            ["node_modules", "@oh-my-pi", "pi-coding-agent", "dist", "cli.js"],
            ["node_modules", "@moonshot-ai", "kimi-code", "dist", "main.mjs"],
        ]
        if suffixes.contains(where: { packageSuffix(components, $0) }) {
            return true
        }
        let normalized = components.map { normalizedPathComponent($0) }
        let windows: [[String]] = [
            ["node_modules", "@qwen-code", "qwen-code", "dist", "index"],
            ["node_modules", "mastracode", "dist", "cli"],
            ["node_modules", "@letta-ai", "letta-code", "letta"],
        ]
        return windows.contains { packageWindow(normalized, $0) }
    }

    /// The path ends with these components. Comparison is case-insensitive,
    /// and the components are not rewritten: `cli.js` is not `cli.exe`.
    private static func packageSuffix(_ components: [String], _ suffix: [String]) -> Bool {
        guard components.count >= suffix.count else { return false }
        let start = components.count - suffix.count
        for offset in 0..<suffix.count {
            if components[start + offset].caseInsensitiveCompare(suffix[offset]) != .orderedSame {
                return false
            }
        }
        return true
    }

    /// A run of components equal to `window`. The caller already folded
    /// case and stripped one executable suffix.
    private static func packageWindow(_ components: [String], _ window: [String]) -> Bool {
        guard components.count >= window.count else { return false }
        let last = components.count - window.count
        for start in 0...last {
            var matches = true
            for offset in 0..<window.count where components[start + offset] != window[offset] {
                matches = false
                break
            }
            if matches { return true }
        }
        return false
    }

    /// One path component, folded and with one suffix removed. The suffix
    /// list is the one `agentBase` uses, so `index.js` is `index` and
    /// `main.mjs` stays `main.mjs`.
    private static func normalizedPathComponent(_ component: String) -> String {
        var base = component.lowercased()
        for suffix in [".exe", ".cmd", ".bat", ".ps1", ".js"] {
            if base.hasSuffix(suffix), base.count > suffix.count {
                base.removeLast(suffix.count)
                break
            }
        }
        return base
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

    /// Which foreground pid a silence reading should measure.
    ///
    /// `pane.process_info` lists the foreground group in the order
    /// `proc_listpids` or the procfs walk returned. That is not "the
    /// agent is last". The old sample was `.last`, so a shell that
    /// happened to be last was the pid `ps` read, and the shell is idle
    /// while the agent runs. A bare shell is not a sample. The process
    /// herdr already calls the agent outranks that shell and a helper
    /// runtime: a `node` or `bun` whose script is an agent, the Windows
    /// Cursor bundle (`node.exe` and `index.js` in the same
    /// `cursor-agent/versions/<version>` directory), or a process whose
    /// name, argv0, or argv[0] is the agent. The last of those is a nix
    /// wrapper whose comm name is `.codex-wrapped`. `bun run`, `bun x`,
    /// `deno run`, and `deno serve` are subcommands, so the script is the
    /// program after them; a path, or the word after `--`, is still that
    /// program when its name is `run`. A shell that is only launching the
    /// agent stays
    /// below those, so its idle CPU is not the reading while the agent
    /// is in the group. A plain runtime still outranks any other helper.
    /// The same rank prefers a runtime over a process that is not one,
    /// then the lower pid, so a helper spawned later does not hide the
    /// process that started the group.
    ///
    /// That tie is wrong when herdr has already named the leader.
    /// `foreground_process_group_id` is the pid herdr's job walk checks
    /// first. When that process is the agent, it is the sample even if
    /// an MCP `node …/codex` beside it is also rank 4 and has the lower
    /// pid. A shell leader is not that process: the child is. A Letta
    /// one-shot or server is not the interactive agent, so it is not the
    /// leader herdr returns and it does not take rank 4. Two plain
    /// runtimes still tie on the lower pid. The group id is omitted on
    /// a herdr that does not send it, and the rank walk is unchanged.
    static func cpuSamplePid(
        _ processes: [ForegroundProcess],
        foregroundProcessGroupId: Int32? = nil
    ) -> Int32? {
        if let leader = rankedAgentLeader(processes, groupId: foregroundProcessGroupId) {
            return leader
        }
        var best: (key: SampleKey, pid: Int32)?
        for process in processes {
            guard process.pid > 0, let key = sampleKey(process) else { continue }
            if let current = best, !key.beats(current.key) { continue }
            best = (key, process.pid)
        }
        return best?.pid
    }

    /// The group leader when herdr's job walk would return that process
    /// as the agent. Nil when the id is missing, not in the list, or the
    /// leader is a shell or a Letta one-shot: the rank walk then picks
    /// the child, and it does not treat the shell's idle CPU as the agent.
    private static func rankedAgentLeader(
        _ processes: [ForegroundProcess],
        groupId: Int32?
    ) -> Int32? {
        guard let groupId, groupId > 0,
              let leader = processes.first(where: { $0.pid == groupId }) else {
            return nil
        }
        guard isRankedAgent(leader, runtime: isGenericRuntime(leader)) else { return nil }
        return leader.pid
    }

    private struct SampleKey {
        let rank: Int
        let runtime: Bool
        let pid: Int32

        func beats(_ other: SampleKey) -> Bool {
            if rank != other.rank { return rank > other.rank }
            if runtime != other.runtime { return runtime }
            return pid < other.pid
        }
    }

    private static func sampleKey(_ process: ForegroundProcess) -> SampleKey? {
        let runtime = isGenericRuntime(process)
        let rank: Int
        if isRankedAgent(process, runtime: runtime) {
            rank = 4
        } else if isKnownAgentProcess(process) {
            rank = 3
        } else if runtime {
            rank = 2
        } else if !isBare(process) {
            rank = 1
        } else {
            return nil
        }
        return SampleKey(rank: rank, runtime: runtime, pid: process.pid)
    }

    /// Rank 4: the process herdr's job walk can return as the agent.
    /// A runtime whose script is an agent, the Windows Cursor bundle, or
    /// a process whose name, argv0, or argv[0] is the agent. A Letta
    /// one-shot is the same binary and is not this rank: herdr skips it
    /// and keeps looking. The shell that launched the agent stays at
    /// rank 3, so this predicate is not the crash check.
    private static func isRankedAgent(_ process: ForegroundProcess, runtime: Bool) -> Bool {
        if isNonInteractiveLetta(process) { return false }
        if runtime && (runtimeScriptIsAgent(process) || isCursorBundledNode(process)) {
            return true
        }
        return isDirectAgentProcess(process)
    }

    /// The comm name, the argv0 field, or argv[0] is an agent program.
    ///
    /// herdr reads argv[0] after the comm name fails. A nix wrapper's
    /// comm name is `.codex-wrapped` and the agent path is that first
    /// word; `MainThread` with `opencode.exe` there is the same shape.
    /// A runtime's argv[0] is `node` or `python`, which is not an agent,
    /// so the script check stays the one that ranks those. A shell's
    /// argv[0] is the shell, so the interpreter stays at the lower rank.
    private static func isDirectAgentProcess(_ process: ForegroundProcess) -> Bool {
        if isKnownAgentProgram(process.name, cwd: process.cwd) { return true }
        if let argv0 = process.argv0, isKnownAgentProgram(argv0, cwd: process.cwd) { return true }
        if let program = launchArguments(process)?.first,
           isKnownAgentProgram(program, cwd: process.cwd) {
            return true
        }
        return false
    }

    /// Letta's binary is also the one-shot CLI and the server. herdr
    /// names only the interactive TUI: no one-shot flag, and no
    /// positional after `--backend`. A `node`, `nodejs`, or `bun` script
    /// is that entrypoint. `python` and `deno` are not, so a file named
    /// `letta` under them is not rank 4. A shell whose program is
    /// `letta` is not a runtime and not a direct agent, so it stays at
    /// rank 3. The crash rule still uses `launchesKnownAgent`.
    private enum LettaInvocation: Equatable {
        case interactive
        case noninteractive
        case notLetta
    }

    private static func isNonInteractiveLetta(_ process: ForegroundProcess) -> Bool {
        lettaInvocation(process) == .noninteractive
    }

    private static func lettaInvocation(_ process: ForegroundProcess) -> LettaInvocation {
        guard let argv = launchArguments(process), !argv.isEmpty else {
            if isLettaProgram(process.name) || process.argv0.map({ isLettaProgram($0) }) == true {
                return .interactive
            }
            return .notLetta
        }
        // The builder in `--build-snapshot-config` is the program.
        // The positional is an argument of that script, so a Letta
        // path there is not the TUI. The words after `node` are what
        // the builder receives once Node has inserted the script.
        if let runtime = argv.first, isNodeRuntime(shellBase(runtime)) {
            let prefix = nodePrefixFlags(argv)
            if prefix.seaConfig || prefix.conflicts || prefix.snapshotConfigExits {
                return .notLetta
            }
            if prefix.snapshotConfigSkipsScript, let path = prefix.snapshotConfigPath {
                if let script = snapshotBuilderScript(configPath: path, cwd: process.cwd),
                   isLettaProgram(script) {
                    let cli = Array(argv.dropFirst())
                    return lettaArgsAreInteractive(cli) ? .interactive : .noninteractive
                }
                return .notLetta
            }
        }
        if let index = lettaEntrypointIndex(argv) {
            let cli = Array(argv.dropFirst(index + 1))
            return lettaArgsAreInteractive(cli) ? .interactive : .noninteractive
        }
        // Identified as Letta without the node/bun entrypoint: a python
        // or deno script, or a comm name that is Letta while argv[0] is
        // not. herdr then judges the whole vector, and a runtime in
        // argv[0] fails the "starts with -" check.
        if runtimeScriptIsLetta(argv, cwd: process.cwd)
            || isLettaProgram(process.name)
            || process.argv0.map({ isLettaProgram($0) }) == true {
            return lettaArgsAreInteractive(argv) ? .interactive : .noninteractive
        }
        return .notLetta
    }

    /// argv index of the Letta program. Zero when argv[0] is Letta.
    /// Otherwise the script of `node` or `bun`, which is the walker
    /// herdr uses. Eval, including `-e` glued to its code, is not a script.
    /// `bun run` and `bun x` are subcommands, so the entrypoint is the
    /// word after them. `node run` is a program named `run`.
    private static func lettaEntrypointIndex(_ argv: [String]) -> Int? {
        if let first = argv.first, isLettaProgram(first) {
            return 0
        }
        guard let runtime = argv.first, isNodeOrBunRuntime(runtime) else { return nil }
        let runtimeName = shellBase(runtime)
        // The same pairs that make `runtimeScript` return nil. A
        // conflict exits before the file. A `--test=` whose child
        // still has the runner on never executes the file body, so
        // that path is not Letta either. `--no-test` and isolation
        // `none` do run it, and the walk below still finds the path.
        // A non-empty `--experimental-sea-config` writes the blob
        // and returns before the positional, so that path is not
        // Letta either. A non-empty `--build-snapshot-config` while
        // snapshot building is still on runs the builder in that
        // JSON, not the positional. `--run` is not this check: the
        // package script still runs, and `runtimeScript` names it.
        if isNodeRuntime(runtimeName) {
            let prefix = nodePrefixFlags(argv)
            if prefix.seaConfig || prefix.conflicts || prefix.snapshotConfigExits
                || prefix.snapshotConfigSkipsScript || prefix.testEqualsSkipsScript {
                return nil
            }
        }
        var index = 1
        var skippedSubcommand = false
        while index < argv.count {
            let arg = argv[index]
            if arg == "--" {
                guard index + 1 < argv.count, isLettaProgram(argv[index + 1]) else { return nil }
                return index + 1
            }
            if lettaEvalFlag(arg) { return nil }
            if arg.hasPrefix("-") {
                // Bun's `-c` and space-separated `--config` do not take a
                // separate word, so the next word can be Letta.
                // `--config=file` stays one word. Node still consumes
                // `--config` here; that process exits, and `runtimeScript`
                // does not treat the following path as the script.
                // `--experimental-loader` and space-separated
                // `--inspect-port` are the same shape on Bun 1.4.2.
                // `--loader` without a colon makes bun exit, so the
                // next word is not Letta. A space-separated `--inspect`
                // address does too: bun looks that word up as the
                // script and exits, so neither it nor the path after
                // it is Letta. A path, and `--inspect=9229`, still are.
                // Node's `--debug-port` consumes a port word. A dash
                // word, or no word, makes that node exit. The same is
                // true of every node value flag. A long option Node
                // 22.23 does not recognize (`--not-a-flag`, `--revision`,
                // `--port`) exits too, so the path after it is not Letta.
                // `--max-old-space-size-percentage nope` exits; `50` and
                // `nan` do not. `--experimental-test-isolation nope`
                // exits only when `--test` is also set. Without it, and
                // with `none` or `process`, the path is still Letta.
                // `--test` with `--interactive`, `-i`, or `--watch-path`
                // exits before the file, so that path is not Letta.
                // `--watch`, and `--watch-path` because it implies
                // `--watch`, with `--interactive`, `-i`, or
                // `--test-force-exit` exits too. `--interactive` alone,
                // and `--watch-path` without those flags or `--test`,
                // still are. `--watch` without a path still runs
                // beside `--test`. A later `--no-watch`,
                // `--no-interactive`, or `--no-test-force-exit` wins.
                // `--secure-heap` of 3, or any negative, exits before
                // the file, and so does a `--secure-heap-min` that is
                // not a power of two once that heap is on. `0`, `1`,
                // and a power of two still are Letta. A negative
                // `--heapsnapshot-near-heap-limit` is not; `0` and
                // `abc` still are. `--test` with a shard, timeout,
                // concurrency, coverage threshold, or reporter list
                // the harness rejects is not Letta. `1/2`, a timeout
                // of `2147483647`, and `--test-reporter spec` still
                // are. A `--test-name-pattern` or `--test-skip-pattern`
                // that Node's regexp parser rejects is not Letta,
                // including a `v` class the unicodeSets grammar rejects.
                // A source scalar above U+FFFF is part of that parse:
                // `u` and `v` read one code point, and a legacy pattern
                // reads the surrogate pair. `/\p{NotAThing}😀/u` and
                // `/[😀-😀]/` are not Letta. `/😀/u` and a legacy
                // `/[😀-U+FFFD]/` still are. A 4-digit `\u` lead and a
                // 4-digit `\u` trail are that same code point when `u`
                // or `v` is set, so `/[\uD83D\uDE00-\uD83D\uDE00]/u`
                // still is Letta. A lone `\uD83D` is a character. A
                // braced `\u{D800}` does not pair, and a legacy class
                // still reads two units. A CR, LF, U+2028, or U+2029
                // in the operand keeps it whole: Node's wrapper does
                // not match across one, so `/*\n/` and `/\c\n/u` still
                // are Letta. `/*/` and `/\c/u` are not. `ok`, `/foo/i`, and
                // `/[a--b]/v` still are. `--no-test` leaves a bad shard
                // and `(` as Letta.
                // Bun rejects `-W`,
                // `-X`, `-S`, `-L`, and `-o`; the path after one is
                // not Letta. A bun value that starts with `-` is not
                // Letta either when that flag rejects it, and neither
                // is a `--define` value with no `:` or `=`.
                if runtimeName == "bun", bunRejectedShort(arg) {
                    return nil
                }
                if runtimeName == "bun",
                   bunConfigFlagWidth(arg) != nil || bunFlagNamesTheScript(arg) {
                    index += 1
                    continue
                }
                if runtimeName == "bun",
                   let loader = bunLoader(
                    arg,
                    following: index + 1 < argv.count ? argv[index + 1] : nil
                   ) {
                    switch loader {
                    case .skip(let width):
                        index += width
                    case .exits:
                        return nil
                    }
                    continue
                }
                if runtimeName == "bun",
                   let inspect = bunInspect(
                    arg,
                    following: index + 1 < argv.count ? argv[index + 1] : nil
                   ) {
                    switch inspect {
                    case .skip(let width):
                        index += width
                    case .exits:
                        return nil
                    }
                    continue
                }
                if isNodeRuntime(runtimeName),
                   let option = nodeOption(
                    arg,
                    following: index + 1 < argv.count ? argv[index + 1] : nil,
                    argv: argv
                   ) {
                    switch option {
                    case .skip(let width):
                        index += width
                    case .exits:
                        return nil
                    }
                    continue
                }
                if runtimeName == "bun" {
                    let following = index + 1 < argv.count ? argv[index + 1] : nil
                    if bunSeparateValueIsTheWordBun(arg, following: following)
                        || bunValueExits(arg, following: following, argv: argv) {
                        return nil
                    }
                }
                if let width = valueFlagWidth(arg, runtime: runtimeName) {
                    index += width
                } else if lettaOptionTakesValue(arg) {
                    index += 2
                } else if let short = runtimeShort(
                    arg,
                    runtime: runtimeName,
                    following: index + 1 < argv.count ? argv[index + 1] : nil
                ) {
                    switch short {
                    case .skip(let width):
                        index += width
                    case .exits:
                        return nil
                    }
                } else {
                    index += 1
                }
                continue
            }
            if !skippedSubcommand, runtimeSubcommand(arg, runtime: runtimeName) {
                skippedSubcommand = true
                index += 1
                continue
            }
            return isLettaProgram(arg) ? index : nil
        }
        return nil
    }

    private static func isNodeOrBunRuntime(_ name: String) -> Bool {
        switch shellBase(name) {
        case "node", "nodejs", "bun":
            return true
        default:
            return false
        }
    }

    /// `-e` / `--eval` / `-p` / `--print`, including a value glued on.
    /// herdr's Letta walker treats that word as eval and stops.
    private static func lettaEvalFlag(_ arg: String) -> Bool {
        let flags = ["-e", "--eval", "-p", "--print"]
        for flag in flags {
            if arg == flag { return true }
            if flag.hasPrefix("--"), arg.hasPrefix(flag + "=") { return true }
            if !flag.hasPrefix("--"), arg.hasPrefix(flag), arg.count > flag.count {
                return true
            }
        }
        return false
    }

    /// The value-taking runtime flags, matched whole. `--require=mod`
    /// keeps its value in the word, so the next word can be the script.
    private static func lettaOptionTakesValue(_ arg: String) -> Bool {
        runtimeValueFlags.contains(arg)
    }

    private static let lettaOneShotFlags: Set<String> = [
        "-p", "--print", "--prompt", "--json", "--stream-json", "--run",
        "--disable-memory-guard", "--output-format", "--input-format",
        "--include-partial-messages", "--from-agent", "--environment", "--env",
        "--pre-load-skills", "--tags", "--ephemeral", "--stateless",
        "--max-turns", "--memfs-startup", "-h", "--help", "-v", "--version",
        "--info", "--update", "--upgrade",
    ]

    /// True when the words after the Letta program are the TUI.
    /// A one-shot flag anywhere says no. `--backend <name>` and
    /// `--backend=<name>` are skipped; a positional after that is the
    /// server or a subcommand, and that is not the TUI either.
    private static func lettaArgsAreInteractive(_ args: [String]) -> Bool {
        for arg in args {
            let option = arg.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first.map(String.init) ?? arg
            if lettaOneShotFlags.contains(option) { return false }
        }
        return lettaFirstArgAfterBackend(args)?.hasPrefix("-") ?? true
    }

    private static func lettaFirstArgAfterBackend(_ args: [String]) -> String? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--backend" {
                index += 2
                continue
            }
            if arg.hasPrefix("--backend=") {
                index += 1
                continue
            }
            return arg
        }
        return nil
    }

    private static func runtimeScriptIsLetta(_ argv: [String], cwd: String?) -> Bool {
        guard let script = runtimeScript(argv, cwd: cwd) else { return false }
        return isLettaProgram(script)
    }

    /// Basename herdr maps to Letta, or the `@letta-ai/letta-code`
    /// package entrypoint. A longer name (`letta-helper`) is not it.
    private static func isLettaProgram(_ token: String) -> Bool {
        let trimmed = trimQuotes(token).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return false }
        if isLettaBasename(agentBase(trimmed)) { return true }
        return isLettaPackage(trimmed)
    }

    private static func isLettaBasename(_ base: String) -> Bool {
        base == "letta" || base == "letta-code" || base == "letta code"
    }

    private static func isLettaPackage(_ token: String) -> Bool {
        let components = token.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard !components.isEmpty else { return false }
        let normalized = components.map { normalizedPathComponent($0) }
        return packageWindow(normalized, ["node_modules", "@letta-ai", "letta-code", "letta"])
    }

    /// Windows Cursor's install is `node.exe` beside `index.js`, under
    /// `cursor-agent/versions/<version>`. The script basename is not an
    /// agent, so the ordinary script check leaves it tied with an MCP
    /// `node`. herdr only accepts `node.exe` for this layout: a plain
    /// `node` plus `index.js` is a different program.
    private static func isCursorBundledNode(_ process: ForegroundProcess) -> Bool {
        guard let argv = launchArguments(process), argv.count >= 2 else { return false }
        guard pathBase(argv[0]).caseInsensitiveCompare("node.exe") == .orderedSame,
              pathBase(argv[1]).caseInsensitiveCompare("index.js") == .orderedSame,
              let runtimeParent = parentPath(argv[0]),
              let scriptParent = parentPath(argv[1]),
              runtimeParent.caseInsensitiveCompare(scriptParent) == .orderedSame else {
            return false
        }
        let parts = pathComponents(runtimeParent)
        guard parts.count >= 3 else { return false }
        let version = parts[parts.count - 1]
        let versions = parts[parts.count - 2]
        let package = parts[parts.count - 3]
        return package.caseInsensitiveCompare("cursor-agent") == .orderedSame
            && versions.caseInsensitiveCompare("versions") == .orderedSame
            && !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Directory containing `path`, with trailing separators removed.
    /// Nil when the path has no directory. Either slash counts: a remote
    /// Windows `pane.process_info` uses backslashes.
    private static func parentPath(_ path: String) -> String? {
        var lastSeparator: String.Index?
        for index in path.indices {
            let character = path[index]
            if character == "/" || character == "\\" {
                lastSeparator = index
            }
        }
        guard let lastSeparator else { return nil }
        let before = path[..<lastSeparator]
        guard let parentEnd = before.lastIndex(where: { $0 != "/" && $0 != "\\" }) else {
            return nil
        }
        let basename = path[path.index(after: lastSeparator)...]
        guard !basename.isEmpty else { return nil }
        return String(path[...parentEnd])
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
    }

    /// `node` / `bun` / `deno` / `python`, including `python3.11` and
    /// `.exe`. A shell is not one of these: `sh ./codex` is the
    /// interpreter, ranked by `isKnownAgentProcess`.
    private static func isGenericRuntime(_ process: ForegroundProcess) -> Bool {
        if isNamedShell(process.name) || isNamedShell(process.argv0) || isCmd(process) {
            return false
        }
        let names = [process.name, process.argv0, process.argv?.first].compactMap { $0 }
        return names.contains { genericRuntimeName($0) }
    }

    private static func genericRuntimeName(_ name: String) -> Bool {
        let base = shellBase(name)
        switch base {
        case "node", "nodejs", "bun", "deno":
            return true
        default:
            break
        }
        guard base.hasPrefix("python") else { return false }
        let rest = base.dropFirst("python".count)
        if rest.isEmpty { return true }
        var sawDigit = false
        for character in rest {
            if character == "." {
                if !sawDigit { return false }
                sawDigit = false
                continue
            }
            guard isASCIIDigit(character) else { return false }
            sawDigit = true
        }
        return sawDigit
    }

    /// The process name, argv0, or a shell wrapper already identifies an
    /// agent. A runtime's script is ranked separately, so `node server.js`
    /// does not become Claude because some other argument says so.
    /// argv[0] on a wrapper whose comm name is not the agent is
    /// `isDirectAgentProcess`: this check is what keeps the shell that
    /// launched the agent above a helper, and below the agent itself.
    private static func isKnownAgentProcess(_ process: ForegroundProcess) -> Bool {
        if isKnownAgentProgram(process.name, cwd: process.cwd) { return true }
        if let argv0 = process.argv0, isKnownAgentProgram(argv0, cwd: process.cwd) { return true }
        return launchesKnownAgent(process)
    }

    /// The script argument of a node-like runtime, when that script is an
    /// agent. Eval and module flags are not a path, including a value
    /// glued onto the flag. A flag that takes a value is not the script
    /// either. `bun run`, `bun x`, `deno run`, and `deno serve` are
    /// subcommands, so they are not the script. Bun's value flags take the
    /// next word, including `--define` / `-d` and the other `bun run`
    /// options that require one, so `bun --define codex server.js` stays a
    /// plain runtime. Node takes its own, including `--title`, so
    /// `node --title codex server.js` stays a plain runtime too.
    /// Deno 2.9.7 takes `--import-map`, `--cert`, `--location`, `--ext`,
    /// and the other flags in `denoRequiredValueFlags`, so
    /// `deno run --import-map codex server.js` stays a plain runtime.
    /// Deno's `--config` still takes the next word. Bun's space-separated
    /// `--config` does not: `bun run --config /tmp/codex` is that script,
    /// and `--config=file` keeps the file in the flag word. Node and
    /// Python reject `--config` and `--config=file` and exit, so a path
    /// after either is not a script. Python's `-S` does not take a value
    /// either: `python3 -S /tmp/codex` runs that file. `--check-hash-based-pycs`
    /// takes `always`, `default`, or `never`, and any other word makes
    /// Python exit. Bun 1.4.2's `--experimental-loader` and a
    /// space-separated `--inspect-port` do not take a word either:
    /// `bun --experimental-loader /tmp/codex.js /tmp/other.js` runs
    /// `codex.js`, and `bun --inspect-port 9229 /tmp/codex` exits with
    /// script not found `9229`. `--flag=value` keeps the value in the
    /// flag word. Node still consumes both, so the script is the word
    /// after the loader or the port. Python rejects both and exits.
    /// Node's `--debug-port` is that same port. A word that does not
    /// start with `-` is the port, and the script is the word after it,
    /// including when the port word is a path. A missing word, a word
    /// that starts with `-`, and an empty `--debug-port=` make node
    /// exit, so nothing after them is a program. `--debug-port=9229`
    /// and `--debug-port=-` keep the port in the flag word. Bun's
    /// space-separated `--debug-port` is the script, the same as
    /// `--inspect-port`: `bun --debug-port 9229 /tmp/codex` tries to
    /// run `9229`. Python rejects `--debug-port`, including the `=`
    /// form, and exits.
    /// Bun's `--loader` and `-l` require a value that contains `:`.
    /// `bun --loader .js:jsx /tmp/codex` and `bun -l.js:jsx /tmp/codex`
    /// run that file. A value with no colon (`/tmp/codex.js`,
    /// `--loader=script.js`, `-lnocolon`) makes bun exit, so the path
    /// after it is not a program. Node's `--loader` is still a module
    /// specifier: the script is the word after the value.
    /// Bun's `--inspect`, `--inspect-wait`, and `--inspect-brk` do not
    /// take a separate address. `bun --inspect ./codex` and
    /// `bun --inspect=9229 ./codex` run that file. `bun --inspect 9229
    /// ./codex` exits with script not found `9229`, so the path after
    /// the address is not a program. Node's and Deno's `--inspect` do
    /// not take that word either: `node --inspect 9229 ./codex` names
    /// `9229`, and `deno run --inspect ./codex` is the script.
    /// Node 22.23 does not take a value that starts with `-`, and an
    /// empty `--flag=` is not a value either: `node --title --watch
    /// /tmp/codex` and `node --title=` exit, so the path is not the
    /// program. Node also rejects `--cwd`, `--filter`, `--preload`,
    /// `--tsconfig-override`, `-W`, `-X`, `-S`, `-L`, `-o`, and `-F`,
    /// including a glued short. Bun still runs `--cwd` and
    /// `--title --watch`. Bun rejects `-W`, `-X`, `-S`, `-L`, and
    /// `-o`. Python's `-W` and `-X` still take the next word.
    /// Python 3.13's only long option that reaches a script is
    /// `--check-hash-based-pycs`. Every other `--` word, including the
    /// shared flags and `--help` / `--version`, exits, so the path after
    /// it is not a script. A short cluster is Python's own `SHORT_OPTS`
    /// (`pythonShort`): an unknown letter, `h`, `V`, `?`, `c`, `m`, or a
    /// lone `-` does not run the path after it, and `-W` / `-X` take a
    /// value. `-qS`, `-bb`, `-OO`, `-vu`, `-R`, and `-t` still name the
    /// file. Node and Bun shorts are `runtimeShort`: an unknown short,
    /// help, version, and stdin do not name the path. `--help` and
    /// `--version` print and exit on Node 22.23, including an attached
    /// `=`, so the path after them is not a script. Bun 1.4.2 prints
    /// those, and `--revision`, only when the invocation is not `run`
    /// or `x`. `bun --version run file` and `bun run --version file`
    /// still run the file. `bun --help run file` does not. `bun --help x`
    /// and `bun --version x` still run the package. A version word that
    /// is the value of `--title` is not a print, and `run` in that slot
    /// is not the subcommand. `--interactive`, `--watch`, `--hot`,
    /// `--bun`, and `bun --not-a-flag` still run the file.
    /// `node --test` with `--interactive`, `-i`, or `--watch-path`
    /// does not: Node 22.23 exits, and the path is not the script.
    /// `--watch`, and `--watch-path` because it implies `--watch`,
    /// with `--interactive`, `-i`, or `--test-force-exit` does not
    /// either. `--watch` without `--watch-path` still runs beside
    /// `--test`. `--interactive` without `--watch`, and `--watch-path`
    /// without `--test`, `--interactive`, or `--test-force-exit`, still
    /// name the file. A later `--no-` wins. `--test-only` is not
    /// `--test`. `--watch-preserve-output` does not imply `--watch`.
    /// Node 22.23 exits on a long option it does not recognize, so
    /// `node --not-a-flag` and `node --revision` are not the script.
    /// A boolean Node or V8 accepts (`--watch`, `--use-strict`,
    /// `-harmony`, `--max-old-space-size=4096`) still names the file.
    /// `--max-old-space-size-percentage` names the file only when Node's
    /// `strtod` reads a number greater than 0 and at most 100, including
    /// `0x10` and `nan`. `nope`, `0`, `101`, and `inf` do not.
    /// Deno still skips an unknown short and was not checked for these
    /// long flags. Node and Bun still consume the long flags they accept.
    /// Bun's own value flags are not that node rule. `--title --watch`
    /// and `--user-agent --watch` run the file. `--port`, `--shell`,
    /// `--install`, and the other flags in `bunDashRejectedFlags` exit
    /// when the next word starts with `-`, and so does an attached
    /// `--port=--watch` or an empty `--port=`. `--define` exits unless
    /// the value contains `:` or `=`, so `KEY` and `--watch` are not a
    /// value and `KEY:1` is. `--elide-lines=` and `--install=` still run.
    /// A non-dash value can exit too. `--port` is 0...65535, `--install`
    /// is `auto`, `fallback`, `force`, or `disable`, `--shell` is
    /// `system` or an attached `bun`, and the enum flags take only the
    /// words Bun 1.4.2 prints. `--console-depth` is 0...65535.
    /// `--elide-lines` and `--max-http-header-size` are non-negative
    /// integers. `--fetch-preconnect` needs an `http` or `https` URL
    /// with a port. A separate word `bun` is not a value: bun prints
    /// the file. `--shell=bun` and `--title=bun` still run.
    /// `--cpu-prof-name` and `--cpu-prof-dir` exit unless `--cpu-prof`
    /// or `--cpu-prof-md` appears before the script, and the heap flags
    /// exit unless `--heap-prof` or `--heap-prof-md` does.
    /// `--cpu-prof-interval` without either flag runs only when the
    /// value is 1000. `--cron-title` and `--cron-period` exit unless
    /// both are set and neither value is empty.
    private static func runtimeScriptIsAgent(_ process: ForegroundProcess) -> Bool {
        guard let argv = launchArguments(process),
              let script = runtimeScript(argv, cwd: process.cwd) else {
            return false
        }
        return isKnownAgentProgram(script, cwd: process.cwd)
    }

    private static let runtimeEvalFlags: Set<String> = [
        "-e", "--eval", "-p", "--print", "-c", "-m",
    ]

    /// Shared flags whose next word is a value, not the script. Bun 1.4.2
    /// does not take a separate word for `--experimental-loader` or
    /// `--inspect-port` (`bunFlagNamesTheScript`); `--config` is
    /// `bunConfigFlagWidth`. Bun's `--loader` is `bunLoader`: a value
    /// with no `:` makes bun exit. Python exits on every long option
    /// except `--check-hash-based-pycs` (`pythonRejectsSharedFlag`).
    /// A Python short cluster is `pythonShort`, so `-S` does not take
    /// the next word and an unknown letter does not either. Deno still
    /// consumes this set, including `--loader`. `--env-file` as its own
    /// word is Deno's boolean, not a separate value.
    /// `-S` is Python's own boolean and Deno's permission flag, handled
    /// before the set. Node rejects `--cwd`, `--filter`, `--preload`,
    /// `--tsconfig-override`, `-W`, `-X`, `-S`, `-L`, `-o`, and `-F`
    /// (`nodeOption`). Bun rejects the same shorts except `-F`, which
    /// is its filter. A node value flag whose next word starts with
    /// `-` exits in `nodeOption` instead of taking that word.
    private static let runtimeValueFlags: Set<String> = [
        "-r", "--require", "--loader", "--import", "--experimental-loader",
        "--inspect-port", "-W", "-X", "-S", "-L", "-o",
        "--cwd", "--env-file", "--filter", "-F", "--preload",
        "--config", "--tsconfig-override",
    ]

    /// `bun run` / `bun x` / `deno run` / `deno serve` are not the program.
    /// The word is exactly that subcommand: `./run`, `run.js`, and the
    /// token after `--` are a program named `run`, and `node` / `python`
    /// have no such subcommand. One subcommand is skipped, so `bun run x`
    /// is a script named `x` and `deno serve server.ts` is that file.
    private static func runtimeSubcommand(_ arg: String, runtime: String) -> Bool {
        switch runtime {
        case "bun":
            return arg == "run" || arg == "x"
        case "deno":
            return arg == "run" || arg == "serve"
        default:
            return false
        }
    }

    /// What `node --run` does with this argv. `.absent` when the option
    /// region has no `--run`, so the positional walk still names the file.
    private enum NodePackageDecision {
        case absent
        case exits
        case program(String)
    }

    /// Node 22.23's `--run` operand is a package.json script. The last
    /// one wins. A missing operand, a word that starts with `-`, an
    /// empty `--run=`, and `--no-run` exit before any file runs. A
    /// file written before `--run` is the program, and `--run` is only
    /// an argument to it. With a real operand, `--help`, `--version`,
    /// and a test-pattern failure still run that script. An unknown
    /// option, a missing value, a `CheckOptions` pair, and `--watch`
    /// without a script file do not. Bun does not use this.
    private static func nodePackageProgram(_ argv: [String]) -> NodePackageDecision {
        guard let runtime = argv.first.map({ shellBase($0) }), isNodeRuntime(runtime) else {
            return .absent
        }
        var index = 1
        var program: String?
        var sawFile = false
        var state = NodePrefix()
        while index < argv.count {
            let arg = argv[index]
            let following = index + 1 < argv.count ? argv[index + 1] : nil
            if arg.hasPrefix("-") {
                if arg == "-i" {
                    state.interactive = true
                }
                if let (flag, on) = nodeBooleanUpdate(arg) {
                    state.set(flag, on: on)
                }
                if arg == "--watch-path" || arg.hasPrefix("--watch-path=") {
                    state.watch = true
                    state.watchPath = true
                }
            }
            if arg == "--" {
                if program == nil { return .absent }
                if index + 1 < argv.count { sawFile = true }
                break
            }
            if program == nil, !arg.hasPrefix("-") {
                return .absent
            }
            if arg == "--no-run" || arg.hasPrefix("--no-run=") {
                return .exits
            }
            if arg == "--run" {
                guard let following, !following.hasPrefix("-") else { return .exits }
                program = following
                index += 2
                continue
            }
            if arg.hasPrefix("--run=") {
                let value = String(arg.dropFirst("--run=".count))
                guard !value.isEmpty else { return .exits }
                program = value
                index += 1
                continue
            }
            if configFlagExits(runtime), arg == "--config" || arg.hasPrefix("--config=") {
                return .exits
            }
            if runtimeAbandonsScript(arg) {
                guard let width = nodePackageAbandonWidth(arg, following: following) else {
                    return program == nil ? .absent : .exits
                }
                index += width
                continue
            }
            // Print flags and the test harness do not stop a package
            // script. A sea config does not either: Node runs `--run`
            // before it builds the blob. Passing that in before `--run`
            // is seen lets `--help --run codex` reach the operand; with
            // no operand the positional walk still applies those exits.
            if let option = nodeOption(
                arg,
                following: following,
                argv: argv,
                packageRun: true
            ) {
                switch option {
                case .skip(let width):
                    index += width
                    continue
                case .exits:
                    return .exits
                }
            }
            if arg.hasPrefix("-"), !arg.hasPrefix("--") {
                switch nodeBareShort(arg) {
                case .skip(let width):
                    index += width
                    continue
                case .exits:
                    return .exits
                }
            }
            if program != nil, !arg.hasPrefix("-") {
                sawFile = true
                break
            }
            if program == nil { return .absent }
            return .exits
        }
        guard let program else { return .absent }
        if state.conflicts || (state.watch && !sawFile) { return .exits }
        return .program(program)
    }

    /// How many words an eval or check flag occupies while looking for
    /// `--run`. Nil when this word is not one of those flags, or when
    /// the flag exits (`-e` with no value, an empty `--eval=`, a glued
    /// `-cfile`). The caller then stops if `--run` was already seen,
    /// and otherwise lets the positional walk decide.
    ///
    /// `-e` and `--eval` require a value that does not start with `-`.
    /// `-p` and `--print` are optional, so a following dash word stays
    /// an option. `-c` alone is `--check` and does not take the next
    /// word.
    private static func nodePackageAbandonWidth(
        _ arg: String,
        following: String?
    ) -> Int? {
        if arg == "-e" || arg == "--eval" {
            guard let following, !following.hasPrefix("-") else { return nil }
            return 2
        }
        if arg.hasPrefix("--eval=") {
            return arg.count > "--eval=".count ? 1 : nil
        }
        if !arg.hasPrefix("--"), arg.hasPrefix("-e"), arg.count > 2 {
            return 1
        }
        // `-p` is optional. A following dash word is the next option,
        // which is how `node -p --run codex` still runs the script.
        if arg == "-p" || arg == "--print" {
            if let following, !following.hasPrefix("-") { return 2 }
            return 1
        }
        if arg.hasPrefix("--print=") { return 1 }
        if !arg.hasPrefix("--"), arg.hasPrefix("-p"), arg.count > 2 {
            return 1
        }
        // `-c` is `--check`. It does not swallow the next word, so
        // `--run` after it is still the package script. A glued `-cfile`
        // is a bad option and falls through.
        if arg == "-c" || arg == "--check" || arg.hasPrefix("--check=") {
            return 1
        }
        return nil
    }

    private static func runtimeScript(_ argv: [String], cwd: String? = nil) -> String? {
        let runtime = argv.first.map { shellBase($0) } ?? ""
        // Node exits before the file when two booleans cannot be set
        // together, when `--test` is combined with `--interactive`
        // (`-i` is the same flag) or with `--watch-path`, and when
        // `--watch` is combined with `--interactive` or
        // `--test-force-exit`. `--watch-path` implies `--watch`. A
        // script written first is already the program: options after
        // it are arguments, and that prefix has no conflict. `--watch`
        // without a path still runs beside `--test`. A later `--no-`
        // wins. A test-runner operand the harness rejects, including
        // a name or skip pattern, is `nodeOption`, and only while the
        // final `--test` state is on.
        // `--run` names a package.json script. That happens before the
        // positional walk: a dash operand exits, and the `=` form is not
        // the file that follows. No `--run` in the option region keeps
        // the walk below. A package script still runs when `--test=`
        // would have skipped a file, and when `--experimental-sea-config`
        // or `--build-snapshot-config` is also set: Node runs the
        // package script before it builds the blob. That is why those
        // decisions are after this switch.
        if isNodeRuntime(runtime) {
            switch nodePackageProgram(argv) {
            case .exits:
                return nil
            case .program(let name):
                return name
            case .absent:
                break
            }
        }
        if isNodeRuntime(runtime) {
            let prefix = nodePrefixFlags(argv)
            // CheckOptions rejects the pairs. A `--test=` form whose
            // child still has the runner on does not execute the file
            // body, so that path is not the program. Isolation `none`
            // and a later `--no-test` do run it. A non-empty
            // `--experimental-sea-config` writes the blob and returns
            // before the positional, whether or not the config file
            // can be read. An empty `=` or a separate dash word is a
            // missing argument and is the walk's exit, not this flag.
            // A non-empty `--build-snapshot-config` while
            // `--build-snapshot` is still on runs the JSON `builder`,
            // or exits when that file cannot be read. The positional
            // is not the program. `--no-build-snapshot` after the
            // config clears the mode and the walk names the file.
            // Sea returns before the snapshot, and CheckOptions
            // rejects the pairs before either runs. A missing
            // `--build-snapshot-config` value is a parser error, so
            // an earlier builder does not run. `--test=` does not
            // stop the builder: the child skip applies only when
            // this process executes the positional.
            if prefix.seaConfig || prefix.conflicts || prefix.snapshotConfigExits {
                return nil
            }
            if prefix.snapshotConfigSkipsScript, let path = prefix.snapshotConfigPath {
                return snapshotBuilderScript(configPath: path, cwd: cwd)
            }
            if prefix.testEqualsSkipsScript {
                return nil
            }
        }
        var index = 1
        var skippedSubcommand = false
        while index < argv.count {
            let arg = argv[index]
            let following = index + 1 < argv.count ? argv[index + 1] : nil
            if arg == "--" {
                guard let following else { return nil }
                return following
            }
            // Deno's `-c` is `--config`, and the next word is that file.
            // Bun's `-c` and space-separated `--config` do not take a
            // separate word: the next word is the script. Both have to
            // run before the eval abandon, which is python's `-c` and
            // still applies to node. `--experimental-loader` and
            // space-separated `--inspect-port` are the same bun shape.
            // `--loader` without a colon exits before any script runs.
            if runtime == "bun",
               bunConfigFlagWidth(arg) != nil || bunFlagNamesTheScript(arg) {
                index += 1
                continue
            }
            if runtime == "bun", let loader = bunLoader(arg, following: following) {
                switch loader {
                case .skip(let width):
                    index += width
                case .exits:
                    return nil
                }
                continue
            }
            // A port or host:port after `--inspect` is the script name
            // bun looks up. That lookup fails, so the path after it is
            // not a program. A path is the script on the next word.
            if runtime == "bun", let inspect = bunInspect(arg, following: following) {
                switch inspect {
                case .skip(let width):
                    index += width
                case .exits:
                    return nil
                }
                continue
            }
            // Bun 1.4.2 has no `-W`, `-X`, `-S`, `-L`, or `-o`. The
            // process exits before the file after the flag runs.
            if runtime == "bun", bunRejectedShort(arg) {
                return nil
            }
            if runtime == "deno", let width = denoFlagWidth(arg, following: following) {
                index += width
                continue
            }
            if runtimeAbandonsScript(arg) {
                return nil
            }
            // Node and Python reject `--config` and `--config=file` and
            // exit. The words after the flag are not a program. A script
            // that already appeared is returned above. Bun's space form
            // was handled as the script, and Deno still consumes it below.
            if configFlagExits(runtime), arg == "--config" || arg.hasPrefix("--config=") {
                return nil
            }
            // Python 3.13 walks a short cluster one letter at a time.
            // An unknown letter, help, version, `-c` / `-m`, or a lone
            // `-` means this process does not run a file. `-W` and `-X`
            // take the rest of the cluster or the next word. Bun, Node,
            // and Deno do not use this set. `--config` already returned.
            if isPythonRuntime(runtime), let short = pythonShort(arg, following: following) {
                switch short {
                case .skip(let width):
                    index += width
                case .exits:
                    return nil
                }
                continue
            }
            // Every other `--` word exits. `--check-hash-based-pycs`
            // is the one long option that still reaches a script, and
            // its mode is `pythonOption` below. Bun, Node, and Deno
            // still consume the long flags they accept.
            if isPythonRuntime(runtime), pythonRejectsSharedFlag(arg) {
                return nil
            }
            // Node 22.23 exits when a value is missing or starts with
            // `-`, and when the flag is one bun or Python owns. The
            // path after that flag is not a program.
            if isNodeRuntime(runtime), let option = nodeOption(arg, following: following, argv: argv) {
                switch option {
                case .skip(let width):
                    index += width
                case .exits:
                    return nil
                }
                continue
            }
            // `--check-hash-based-pycs` takes a mode, or exits. `-S` already
            // advanced in `pythonShort`, so the shared value set cannot
            // swallow that script. `-W` and `-X` did too.
            if isPythonRuntime(runtime), let option = pythonOption(arg, following: following) {
                switch option {
                case .skip(let width):
                    index += width
                case .exits:
                    return nil
                }
                continue
            }
            if runtime == "bun", bunSeparateValueIsTheWordBun(arg, following: following) {
                // A separate argv word `bun` is not the value. Bun prints
                // the file or switches to the bundler and does not run it.
                // `--shell=bun` keeps the word in the flag and still runs.
                return nil
            }
            if runtimeValueFlags.contains(arg) {
                // Deno's `-r` is `--reload` with no separate value, and
                // `-W` / `-S` / `--env-file` are the same shape. Node's
                // `-r` and `--env-file`, and Python's `-W` and `-X`, still
                // take the next word. Node and bun already returned on
                // the shorts they reject, so this consume is not that exit.
                if runtime == "deno", denoBooleanFlags.contains(arg) {
                    index += 1
                    continue
                }
                index += 2
                continue
            }
            if runtimeFlagAttachesValue(arg) {
                index += 1
                continue
            }
            // Bun exits before the path after a rejected value runs.
            // Node's dash-word rule is `nodeOption`, above. A value bun
            // accepts still falls through to `valueFlagWidth`.
            if runtime == "bun", bunValueExits(arg, following: following, argv: argv) {
                return nil
            }
            if let width = valueFlagWidth(arg, runtime: runtime) {
                index += width
                continue
            }
            // Node and Bun shorts that were not claimed above. An unknown
            // short, help, version, and stdin are not a script. `--help`
            // and `--version` print and exit, so the path is not a script
            // either, unless bun is `run` or `x` and that flag still
            // reaches the file. Node's other long options were decided
            // in `nodeOption`: an unrecognized one is not a script.
            // A Deno short, and a bun long option that is not a print,
            // still skip one word. `bun --not-a-flag` is that skip.
            if arg.hasPrefix("-") {
                if runtimePrintsAndExits(arg, runtime: runtime, argv: argv) {
                    return nil
                }
                if let short = runtimeShort(arg, runtime: runtime, following: following) {
                    switch short {
                    case .skip(let width):
                        index += width
                    case .exits:
                        return nil
                    }
                    continue
                }
                index += 1
                continue
            }
            if !skippedSubcommand, runtimeSubcommand(arg, runtime: runtime) {
                skippedSubcommand = true
                index += 1
                continue
            }
            return arg
        }
        return nil
    }

    /// Eval and module flags, including the payload glued on.
    ///
    /// herdr's node and bun walker matches `-eCODE`, `--eval=code`,
    /// `-pCODE`, and `--print=code` as the flag itself, then stops. Python's
    /// walker does the same for `-cCODE` and `-mmodule`. An exact `-e`
    /// already did, and so did an exact `-c` or `-m`. Deno and bun handle
    /// their own `-c` before this function runs. The glued form was
    /// skipped as an unknown flag, so the next word
    /// (`/tmp/codex`, a Letta path) became the script and outranked the
    /// real agent, including when that node was the group leader. A short
    /// flag only has to start with `-e`, `-p`, `-c`, or `-m`; herdr's
    /// `short_flag_payload` is that prefix for the flags that walker names.
    private static func runtimeAbandonsScript(_ arg: String) -> Bool {
        if runtimeEvalFlags.contains(arg) || arg.hasPrefix("-m=") {
            return true
        }
        if arg.hasPrefix("--eval=") || arg.hasPrefix("--print=") {
            return true
        }
        guard !arg.hasPrefix("--") else { return false }
        let shorts = ["-e", "-p", "-c", "-m"]
        for flag in shorts where arg.hasPrefix(flag) && arg.count > flag.count {
            return true
        }
        return false
    }

    /// `bun run` options whose next word is a value, not the script.
    ///
    /// The list is the string and number options on Bun 1.4.2's `bun run`
    /// help, plus `--origin`, which that binary still consumes and the
    /// help no longer prints. `--require`, `--import`, `--preload`,
    /// `--cwd`, `--env-file`, `--filter`, and `--tsconfig-override`
    /// are already `runtimeValueFlags`. Bun's `--loader` and `-l` are
    /// `bunLoader`: the value has to contain `:`, and a value that does
    /// not makes bun exit. Node and Deno still take `--loader` from
    /// `runtimeValueFlags`. Bun's
    /// space-separated `--config` is not: the next word is the script.
    /// Deno still takes `--config` from that set. `-e` and
    /// `-p` abandon the walk before this set is consulted, so they are
    /// not `--external` or `--port`. Bun's `-c` is not a value here: the
    /// next word is the script. `--external`, `--target`, and `--packages`
    /// as their own word are not options on
    /// that binary: the next word is the script. `-dVALUE` and
    /// `--define=KEY` keep the value in the flag word. Node and python
    /// are not bun, so `node --define` and `python -d` do not use this set.
    /// Node's own value flags are `nodeRequiredValueFlags`. Deno's are
    /// `denoRequiredValueFlags`, and Deno does not use this set.
    /// A dash word is not a value for `bunDashRejectedFlags`. `--define`
    /// needs a `:` or `=` in the value (`bunValueExits`); `KEY` exits
    /// and `KEY:1` does not. `--title` and `--user-agent` still take a
    /// dash word, and the script is the word after it.
    private static let bunRequiredValueFlags: Set<String> = [
        "--define", "-d",
        "--drop",
        "--shell",
        "--title",
        "--unhandled-rejections",
        "--console-depth",
        "--watch-kill-signal",
        "--elide-lines",
        "--install",
        "--conditions",
        "--main-fields",
        "--extension-order",
        "--jsx-factory",
        "--jsx-fragment",
        "--jsx-import-source",
        "--jsx-runtime",
        "--port",
        "--fetch-preconnect",
        "--max-http-header-size",
        "--dns-result-order",
        "--user-agent",
        "--cpu-prof-name",
        "--cpu-prof-dir",
        "--cpu-prof-interval",
        "--heap-prof-name",
        "--heap-prof-dir",
        "--heap-prof-interval",
        "--redirect-warnings",
        "--disable-warning",
        "--cron-title",
        "--cron-period",
        "--feature",
        "--origin",
        "--trace-event-categories",
        "--trace-event-file-pattern",
    ]

    /// Node options whose next word is a value, not the script.
    ///
    /// Checked against Node 22.23's `--help`: each `=...` option consumes
    /// the following word when that word is not the program. `--title`,
    /// the profiler names, and `--redirect-warnings` are the same shape
    /// bun already skipped, so `node --title codex server.js` was rank 4.
    /// `-C` is `--conditions`; bun rejects that short form, so it stays
    /// here. `--env-file`, `--require`, `--import`, and `--loader` are
    /// already `runtimeValueFlags`. `-e` / `--eval` abandon the walk.
    /// `--run` is `nodePackageProgram`: the operand is the program, not
    /// the file after it. `--inspect` does not take the next word. `--define` is not a node
    /// flag. Python and deno are not this runtime.
    /// `--experimental-sea-config` consumes its path and then does not
    /// run the positional: Node writes the blob and returns. That
    /// decision is `NodePrefix.seaConfig`, after `--run`.
    /// `--build-snapshot-config` also consumes its path. While
    /// snapshot building stays on, the program is the JSON `builder`,
    /// not the next word. That decision is `snapshotBuilderScript`.
    private static let nodeRequiredValueFlags: Set<String> = [
        "--title",
        "--unhandled-rejections",
        "--max-http-header-size",
        "--dns-result-order",
        "--watch-kill-signal",
        "--conditions",
        "-C",
        "--cpu-prof-name",
        "--cpu-prof-dir",
        "--cpu-prof-interval",
        "--heap-prof-name",
        "--heap-prof-dir",
        "--heap-prof-interval",
        "--redirect-warnings",
        "--disable-warning",
        "--trace-event-categories",
        "--trace-event-file-pattern",
        "--disable-proto",
        "--experimental-default-type",
        "--input-type",
        "--icu-data-dir",
        "--localstorage-file",
        "--tls-keylog",
        "--v8-pool-size",
        "--use-largepages",
        "--heapsnapshot-signal",
        "--heapsnapshot-near-heap-limit",
        "--report-signal",
        "--report-dir",
        "--report-directory",
        "--report-filename",
        "--inspect-publish-uid",
        "--secure-heap",
        "--secure-heap-min",
        "--openssl-config",
        "--diagnostic-dir",
        "--env-file-if-exists",
        "--watch-path",
        "--allow-fs-read",
        "--allow-fs-write",
        "--experimental-config-file",
        "--snapshot-blob",
        "--build-snapshot-config",
        "--experimental-sea-config",
        "--experimental-test-isolation",
        "--max-old-space-size-percentage",
        "--tls-cipher-list",
        "--trace-require-module",
        "--test-reporter",
        "--test-reporter-destination",
        "--test-name-pattern",
        "--test-skip-pattern",
        "--test-timeout",
        "--test-shard",
        "--test-concurrency",
        "--test-coverage-branches",
        "--test-coverage-include",
        "--test-coverage-exclude",
        "--test-coverage-functions",
        "--test-coverage-lines",
        "--network-family-autoselection-attempt-timeout",
    ]

    /// `--inspect`, `--inspect-wait`, and `--inspect-brk`. The `=` form
    /// is not in this set: `--inspect=9229` stays one word.
    private static let bunInspectFlags: Set<String> = [
        "--inspect", "--inspect-wait", "--inspect-brk",
    ]

    /// How Bun's inspector flag occupies argv. Nil when `arg` is not
    /// one of those flags. Node and Deno do not use this check.
    private enum BunInspect {
        /// Words to advance, including the flag. The next word is the script.
        case skip(Int)
        /// Bun looks the next word up as a script and does not run one.
        case exits
    }

    /// Bun 1.4.2 does not take a separate address for these flags.
    ///
    /// `bun --inspect ./codex`, `bun --inspect-brk ./codex`,
    /// `bun --inspect --watch ./codex`, and `bun --inspect=9229 ./codex`
    /// run that file. `--inspect-brk` on a path stays up under the
    /// inspector. `bun --inspect 9229 ./codex`, `bun --inspect-wait
    /// 127.0.0.1:9229 ./codex`, `bun --inspect localhost:6499/codex`,
    /// and `bun --inspect-brk [::1]:9229 ./codex` exit with that word
    /// as the missing script, so neither the address nor the path
    /// after it is a program. A Windows path is not an address. A
    /// missing word prints help and exits; there is no script.
    private static func bunInspect(_ arg: String, following: String?) -> BunInspect? {
        guard bunInspectFlags.contains(arg) else { return nil }
        if let following, looksLikeInspectAddress(following) {
            return .exits
        }
        return .skip(1)
    }

    /// Words this flag occupies, including itself. Nil when `arg` is not
    /// one of bun's or node's value flags. A required value takes the
    /// next word. Node's dash word, empty `--flag=`, and rejected flags
    /// exit in `nodeOption` before this width is used. Bun's rejected
    /// value exits in `bunValueExits` before this width is used, so a
    /// dash word here is one bun still accepts (`--title --watch`).
    /// Bun's `--inspect` is `bunInspect`: an address-shaped word makes
    /// bun exit, and a path is the script.
    private static func valueFlagWidth(_ arg: String, runtime: String) -> Int? {
        if let width = bunFlagWidth(arg, runtime: runtime) {
            return width
        }
        return nodeFlagWidth(arg, runtime: runtime)
    }

    private static func bunFlagWidth(_ arg: String, runtime: String) -> Int? {
        guard runtime == "bun" else { return nil }
        guard bunRequiredValueFlags.contains(arg) else { return nil }
        return 2
    }

    /// Bun 1.4.2 exits when the next word starts with `-`. Checked on
    /// that binary: each one reports the dash word as an invalid value
    /// and does not run the file. `--title`, `--user-agent`, `--drop`,
    /// and the profiler names are not here. With `--cpu-prof` set,
    /// `--cpu-prof-name --watch script.js` runs that file, so a dash
    /// word is the name. `--elide-lines=` and `--install=` are empty
    /// and still run; the other flags exit on an empty `=`.
    private static let bunDashRejectedFlags: Set<String> = [
        "--shell",
        "--unhandled-rejections",
        "--console-depth",
        "--elide-lines",
        "--install",
        "--jsx-runtime",
        "--port",
        "--fetch-preconnect",
        "--max-http-header-size",
        "--dns-result-order",
    ]

    /// An empty `--flag=` exits. `--elide-lines=` and `--install=` do
    /// not, so they stay off this list. `--define=` is `bunDefineOperand`.
    private static let bunEmptyAttachedExits: Set<String> = [
        "--shell",
        "--unhandled-rejections",
        "--console-depth",
        "--jsx-runtime",
        "--port",
        "--fetch-preconnect",
        "--max-http-header-size",
        "--dns-result-order",
    ]

    /// True when Bun 1.4.2 rejects this argv word and does not run a
    /// script after it.
    ///
    /// `--port --watch /tmp/codex`, `--port=--watch`, `--port=`, and
    /// `--shell --watch` exit. `--port 3000` and `--port=3000` do not.
    /// `--port codex`, `--port 65536`, `--install nope`, `--shell bash`,
    /// and `--fetch-preconnect https://example.com` exit too: a word
    /// that does not start with `-` can still be a value bun rejects.
    /// `--define KEY` exits because the value has no `:` or `=`.
    /// `KEY:1` runs. A separate word `bun` is not a value (`--shell bun`
    /// prints the file). `--shell=bun` and `--title=bun` still run.
    /// `--title --watch` is not an exit.
    private static func bunValueExits(
        _ arg: String,
        following: String?,
        argv: [String]
    ) -> Bool {
        if bunSeparateValueIsTheWordBun(arg, following: following) {
            return true
        }
        if let define = bunDefineOperand(arg, following: following) {
            return !define.contains(":") && !define.contains("=")
        }
        if let rejected = bunConstrainedExit(arg, following: following, argv: argv) {
            return rejected
        }
        if bunDashRejectedFlags.contains(arg) {
            guard let following else { return false }
            return following.hasPrefix("-")
        }
        return bunAttachedDashExits(arg)
    }

    /// A separate argv word whose text is `bun`. Bun 1.4.2 does not take
    /// that word as the value of a flag that consumes one: it prints the
    /// next file or treats the words as bundle entry points. The `=`
    /// form (`--title=bun`, `--shell=bun`) is a different word and is
    /// not this check. `--config` and the flags whose next word is the
    /// script are not value flags.
    private static func bunSeparateValueIsTheWordBun(_ arg: String, following: String?) -> Bool {
        guard following == "bun" else { return false }
        if bunFlagNamesTheScript(arg) || bunConfigFlagWidth(arg) != nil { return false }
        if bunRequiredValueFlags.contains(arg) { return true }
        return runtimeValueFlags.contains(arg)
    }

    /// The `--define` / `-d` value. Nil when `arg` is not that flag, so
    /// a missing word stays on `bunFlagWidth` and names no script. The
    /// `=` in `--define=` and `-d=` attaches the value; it is not the
    /// separator bun requires inside the value.
    private static func bunDefineOperand(_ arg: String, following: String?) -> String? {
        if arg == "--define" || arg == "-d" {
            return following
        }
        let longFlag = "--define="
        if arg.hasPrefix(longFlag) {
            return String(arg.dropFirst(longFlag.count))
        }
        guard arg.hasPrefix("-d"), !arg.hasPrefix("--"), arg.count > 2 else { return nil }
        var rest = arg.dropFirst(2)
        if rest.first == "=" {
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    /// `--port=--watch` and `--port=`. A value that does not start with
    /// `-` and is not empty stays one flag word, and the next word is
    /// the script. `--title=--watch` is not one of these flags.
    private static func bunAttachedDashExits(_ arg: String) -> Bool {
        for flag in bunDashRejectedFlags where flag.hasPrefix("--") {
            let prefix = flag + "="
            guard arg.hasPrefix(prefix) else { continue }
            let value = arg.dropFirst(prefix.count)
            if value.hasPrefix("-") { return true }
            return value.isEmpty && bunEmptyAttachedExits.contains(flag)
        }
        return false
    }

    /// A long flag's operand. `missing` is the flag with no following
    /// word. The `=` form is `.value`, including an empty one.
    private enum BunOperand {
        case missing
        case value(String)
    }

    /// The operand of an exact long flag or its `--flag=` form.
    /// Nil when `arg` is a different flag. `--flag=value` keeps the
    /// value in the word; a separate word is `following`.
    private static func bunLongOperand(
        _ arg: String,
        following: String?,
        name: String
    ) -> BunOperand? {
        if arg == name {
            if let following { return .value(following) }
            return .missing
        }
        let prefix = name + "="
        guard arg.hasPrefix(prefix) else { return nil }
        return .value(String(arg.dropFirst(prefix.count)))
    }

    /// True when this flag's value makes Bun 1.4.2 exit. Nil when `arg`
    /// is not one of the flags checked here.
    private static func bunConstrainedExit(
        _ arg: String,
        following: String?,
        argv: [String]
    ) -> Bool? {
        if let exit = bunPortExit(arg, following: following) { return exit }
        if let exit = bunInstallExit(arg, following: following) { return exit }
        if let exit = bunShellExit(arg, following: following) { return exit }
        if let exit = bunChoiceExit(
            arg, following: following, name: "--unhandled-rejections", choices: bunRejectionModes
        ) { return exit }
        if let exit = bunChoiceExit(
            arg, following: following, name: "--jsx-runtime", choices: bunJSXRuntimes
        ) { return exit }
        if let exit = bunChoiceExit(
            arg, following: following, name: "--dns-result-order", choices: bunDNSOrders
        ) { return exit }
        if let exit = bunRangedIntegerExit(
            arg, following: following, name: "--console-depth", maximum: 65535
        ) { return exit }
        if let exit = bunElideExit(arg, following: following) { return exit }
        if let exit = bunHeaderExit(arg, following: following) { return exit }
        if let exit = bunPreconnectExit(arg, following: following) { return exit }
        if let exit = bunProfilerExit(arg, following: following, argv: argv) { return exit }
        if let exit = bunCronExit(arg, following: following, argv: argv) { return exit }
        return nil
    }

    /// `--port` is an integer 0...65535. `+80` and `03000` are that
    /// integer. A word, an empty `=`, and a dash word are not.
    private static func bunPortExit(_ arg: String, following: String?) -> Bool? {
        guard let operand = bunLongOperand(arg, following: following, name: "--port") else {
            return nil
        }
        switch operand {
        case .missing:
            return false
        case .value(let value):
            guard let number = bunUnsignedInteger(value) else { return true }
            return number > 65535
        }
    }

    private static let bunInstallValues: Set<String> = [
        "auto", "fallback", "force", "disable",
    ]

    /// `--install=` and a separate empty word still run. `auto`,
    /// `fallback`, `force`, and `disable` run. Any other word exits.
    /// The match is case-sensitive.
    private static func bunInstallExit(_ arg: String, following: String?) -> Bool? {
        guard let operand = bunLongOperand(arg, following: following, name: "--install") else {
            return nil
        }
        switch operand {
        case .missing:
            return false
        case .value(let value):
            if value.isEmpty { return false }
            return !bunInstallValues.contains(value)
        }
    }

    /// `system` runs. An attached `bun` runs. A separate word `bun`
    /// prints the file, and every other word exits, including an empty `=`.
    private static func bunShellExit(_ arg: String, following: String?) -> Bool? {
        guard let operand = bunLongOperand(arg, following: following, name: "--shell") else {
            return nil
        }
        switch operand {
        case .missing:
            return false
        case .value(let value):
            if arg == "--shell", value == "bun" { return true }
            return value != "bun" && value != "system"
        }
    }

    private static let bunRejectionModes: Set<String> = [
        "strict", "throw", "warn", "none", "warn-with-error-code",
    ]

    private static let bunJSXRuntimes: Set<String> = ["automatic", "classic"]

    private static let bunDNSOrders: Set<String> = ["verbatim", "ipv4first", "ipv6first"]

    /// An enum bun prints in `--help`. Any other word, including a
    /// different case or an empty `=`, exits.
    private static func bunChoiceExit(
        _ arg: String,
        following: String?,
        name: String,
        choices: Set<String>
    ) -> Bool? {
        guard let operand = bunLongOperand(arg, following: following, name: name) else {
            return nil
        }
        switch operand {
        case .missing:
            return false
        case .value(let value):
            return !choices.contains(value)
        }
    }

    /// `--console-depth` is 0...65535. `+2` and `00` count. A larger
    /// number, a word, and an empty `=` exit.
    private static func bunRangedIntegerExit(
        _ arg: String,
        following: String?,
        name: String,
        maximum: UInt64
    ) -> Bool? {
        guard let operand = bunLongOperand(arg, following: following, name: name) else {
            return nil
        }
        switch operand {
        case .missing:
            return false
        case .value(let value):
            guard let number = bunUnsignedInteger(value) else { return true }
            return number > maximum
        }
    }

    /// `--elide-lines=` is empty and still runs. A non-negative integer,
    /// including `+2`, runs. A word, a dash word, and a value past
    /// `UInt64` exit.
    private static func bunElideExit(_ arg: String, following: String?) -> Bool? {
        guard let operand = bunLongOperand(arg, following: following, name: "--elide-lines") else {
            return nil
        }
        switch operand {
        case .missing:
            return false
        case .value(let value):
            if arg.hasPrefix("--elide-lines="), value.isEmpty { return false }
            return bunUnsignedInteger(value) == nil
        }
    }

    /// `--max-http-header-size` is a non-negative integer. `0` and `+16`
    /// run. An empty `=` and a word exit.
    private static func bunHeaderExit(_ arg: String, following: String?) -> Bool? {
        guard let operand = bunLongOperand(
            arg, following: following, name: "--max-http-header-size"
        ) else {
            return nil
        }
        switch operand {
        case .missing:
            return false
        case .value(let value):
            return bunUnsignedInteger(value) == nil
        }
    }

    /// `--fetch-preconnect` needs `http://` or `https://` and a port in
    /// 1...65535. `https://example.com` has no port and exits.
    /// `https://example.com:443` runs. A dash word exits.
    private static func bunPreconnectExit(_ arg: String, following: String?) -> Bool? {
        guard let operand = bunLongOperand(
            arg, following: following, name: "--fetch-preconnect"
        ) else {
            return nil
        }
        switch operand {
        case .missing:
            return false
        case .value(let value):
            return !bunPreconnectURL(value)
        }
    }

    /// `--cpu-prof-name` and `--cpu-prof-dir` exit unless `--cpu-prof`
    /// or `--cpu-prof-md` is its own word before the script. The heap
    /// name, directory, and interval exit unless `--heap-prof` or
    /// `--heap-prof-md` is. `--cpu-prof-interval` without either flag
    /// runs only when the value is 1000 (`+1000` and `01000` too).
    /// With either flag, any other value runs, including a dash word.
    /// `--cpu-prof=true` is not the flag, and a copy after the script
    /// does not count.
    private static func bunProfilerExit(
        _ arg: String,
        following: String?,
        argv: [String]
    ) -> Bool? {
        if let operand = bunLongOperand(arg, following: following, name: "--cpu-prof-interval") {
            if bunCPUProfiling(argv) {
                return false
            }
            switch operand {
            case .missing:
                return true
            case .value(let value):
                return !bunIntegerEquals(value, 1000)
            }
        }
        for name in ["--cpu-prof-name", "--cpu-prof-dir"] {
            if bunLongOperand(arg, following: following, name: name) != nil {
                return !bunCPUProfiling(argv)
            }
        }
        for name in ["--heap-prof-name", "--heap-prof-dir", "--heap-prof-interval"] {
            if bunLongOperand(arg, following: following, name: name) != nil {
                return !bunHeapProfiling(argv)
            }
        }
        return nil
    }

    /// `--cpu-prof` or `--cpu-prof-md` before the script. The markdown
    /// flag writes a profile on its own, and it also enables the name,
    /// directory, and interval flags.
    private static func bunCPUProfiling(_ argv: [String]) -> Bool {
        bunBooleanFlagBeforeScript("--cpu-prof", argv: argv)
            || bunBooleanFlagBeforeScript("--cpu-prof-md", argv: argv)
    }

    /// `--heap-prof` or `--heap-prof-md` before the script.
    private static func bunHeapProfiling(_ argv: [String]) -> Bool {
        bunBooleanFlagBeforeScript("--heap-prof", argv: argv)
            || bunBooleanFlagBeforeScript("--heap-prof-md", argv: argv)
    }

    /// `--cron-title` and `--cron-period` exit unless the other flag is
    /// also set before the script and this value is not empty. A bad
    /// period still imports the file, so the script is that path.
    /// A flag after the script does not count.
    private static func bunCronExit(
        _ arg: String,
        following: String?,
        argv: [String]
    ) -> Bool? {
        let pair: (String, String)?
        if bunLongOperand(arg, following: following, name: "--cron-title") != nil {
            pair = ("--cron-title", "--cron-period")
        } else if bunLongOperand(arg, following: following, name: "--cron-period") != nil {
            pair = ("--cron-period", "--cron-title")
        } else {
            pair = nil
        }
        guard let (name, other) = pair,
              let operand = bunLongOperand(arg, following: following, name: name) else {
            return nil
        }
        switch operand {
        case .missing:
            return true
        case .value(let value):
            if value.isEmpty { return true }
            return !bunNamedFlagBeforeScript(other, argv: argv)
        }
    }

    /// Optional leading `+`, then digits. `03000` is 3000. A word, a
    /// dash, an empty string, and a number past `UInt64.max` are nil.
    private static func bunUnsignedInteger(_ value: String) -> UInt64? {
        var digits = Substring(value)
        if digits.first == "+" {
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty else { return nil }
        for character in digits where !isASCIIDigit(character) {
            return nil
        }
        return UInt64(String(digits))
    }

    private static func bunIntegerEquals(_ value: String, _ target: UInt64) -> Bool {
        bunUnsignedInteger(value) == target
    }

    /// True when `flag` is its own argv word before the first positional
    /// script. A value of an earlier flag does not count, and a copy
    /// after the script does not either. `--` ends the flag region.
    private static func bunBooleanFlagBeforeScript(_ flag: String, argv: [String]) -> Bool {
        bunFlagBeforeScript(argv: argv) { $0 == flag }
    }

    /// `name` or `name=value`, before the script. `--cron-period=1s`
    /// is the flag. The value of `--cron-title` is not.
    private static func bunNamedFlagBeforeScript(_ name: String, argv: [String]) -> Bool {
        let attached = name + "="
        return bunFlagBeforeScript(argv: argv) { $0 == name || $0.hasPrefix(attached) }
    }

    private static func bunFlagBeforeScript(
        argv: [String],
        matches: (String) -> Bool
    ) -> Bool {
        guard argv.first.map({ shellBase($0) }) == "bun" else { return false }
        var index = 1
        var skippedSubcommand = false
        while index < argv.count {
            let arg = argv[index]
            if arg == "--" { return false }
            if matches(arg) { return true }
            if arg.hasPrefix("-") {
                if !arg.hasPrefix("--"),
                   let short = bunBareShort(
                    arg,
                    following: index + 1 < argv.count ? argv[index + 1] : nil
                   ) {
                    if case .skip(let width) = short {
                        index += width
                        continue
                    }
                }
                let width = bunFlagWordWidth(arg)
                if width > 1, index + 1 < argv.count {
                    index += width
                } else {
                    index += 1
                }
                continue
            }
            if !skippedSubcommand, runtimeSubcommand(arg, runtime: "bun") {
                skippedSubcommand = true
                index += 1
                continue
            }
            return false
        }
        return false
    }

    /// Words this flag occupies when scanning for a later flag. Value
    /// flags take the next word. `--config` and the flags whose next
    /// word is the script occupy one.
    private static func bunFlagWordWidth(_ arg: String) -> Int {
        if bunFlagNamesTheScript(arg) || bunConfigFlagWidth(arg) != nil { return 1 }
        if bunInspectFlags.contains(arg) { return 1 }
        if bunRequiredValueFlags.contains(arg) { return 2 }
        if arg == "--loader" || arg == "-l" { return 2 }
        if runtimeValueFlags.contains(arg) { return 2 }
        return 1
    }

    /// `http://host:80`, `https://example.com:443/path`, and
    /// `https://[::1]:443`. The scheme is either case. The port is
    /// 1...65535. A missing port, a port of 0, and a `#` glued to the
    /// port exit. A `#` after `/` stays.
    private static func bunPreconnectURL(_ value: String) -> Bool {
        guard let scheme = bunHTTPSchemeLength(value) else { return false }
        var rest = value.dropFirst(scheme)
        let limit = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
        if let at = rest[..<limit].lastIndex(of: "@") {
            rest = rest[rest.index(after: at)...]
        }
        guard !rest.isEmpty else { return false }
        let portAndMore: Substring
        if rest.first == "[" {
            guard let close = rest.firstIndex(of: "]") else { return false }
            let host = rest[rest.index(after: rest.startIndex)..<close]
            guard !host.isEmpty else { return false }
            let afterBracket = rest.index(after: close)
            guard afterBracket < rest.endIndex, rest[afterBracket] == ":" else { return false }
            portAndMore = rest[rest.index(after: afterBracket)...]
        } else {
            guard let colon = rest.firstIndex(of: ":") else { return false }
            let host = rest[..<colon]
            guard !host.isEmpty, !host.contains("/") else { return false }
            portAndMore = rest[rest.index(after: colon)...]
        }
        var digitEnd = portAndMore.startIndex
        while digitEnd < portAndMore.endIndex, isASCIIDigit(portAndMore[digitEnd]) {
            digitEnd = portAndMore.index(after: digitEnd)
        }
        let digits = portAndMore[..<digitEnd]
        guard let port = UInt64(String(digits)), port >= 1, port <= 65535 else { return false }
        let tail = portAndMore[digitEnd...]
        if tail.isEmpty { return true }
        let first = tail[tail.startIndex]
        return first == "/" || first == "?"
    }

    private static func bunHTTPSchemeLength(_ value: String) -> Int? {
        if value.count >= 8, value.prefix(8).lowercased() == "https://" { return 8 }
        if value.count >= 7, value.prefix(7).lowercased() == "http://" { return 7 }
        return nil
    }

    private static func nodeFlagWidth(_ arg: String, runtime: String) -> Int? {
        guard isNodeRuntime(runtime) else { return nil }
        guard nodeRequiredValueFlags.contains(arg) else { return nil }
        return 2
    }

    /// `node`, `nodejs`, and `node.exe`. Not bun, and not a name that
    /// only starts with those letters.
    private static func isNodeRuntime(_ runtime: String) -> Bool {
        runtime == "node" || runtime == "nodejs"
    }

    /// How a Node option occupies argv. Nil when `arg` is not one of
    /// Node's value flags and not a flag Node rejects, so
    /// `--title=helper` and `--debug-port=9229` stay one word and the
    /// next word is the script.
    private enum NodeOption {
        /// Words to advance, including the flag.
        case skip(Int)
        /// Node rejects the invocation and does not run a script.
        case exits
    }

    /// Flags in the shared set that Node 22.23 rejects. `--config` is
    /// `configFlagExits`. `-F` is Bun's filter; the other shorts are
    /// Python's or Bun's. A script written before the flag is already
    /// returned.
    private static let nodeRejectedFlags: Set<String> = [
        "-W", "-X", "-S", "-L", "-o", "-F",
        "--cwd", "--filter", "--preload", "--tsconfig-override",
    ]

    /// Shared flags Node does accept, besides `nodeRequiredValueFlags`.
    /// `--debug-port` is the alias of `--inspect-port`. The `=` form is
    /// not in this set.
    private static let nodeAcceptedSharedFlags: Set<String> = [
        "-r", "--require", "--loader", "--import", "--experimental-loader",
        "--inspect-port", "--env-file", "--debug-port",
    ]

    /// Node 22.23's option parser, checked on this runtime.
    ///
    /// A separate word that does not start with `-` is the value, and
    /// the script is the word after it: `node --title helper
    /// /tmp/codex`, `node --debug-port 9229 /tmp/codex`, and
    /// `node -r ./preload.js /tmp/codex` run that file. A missing word
    /// or a word that starts with `-` (`--watch`, `--`, `-`, `-1`)
    /// makes node exit, for every flag in `nodeRequiredValueFlags` and
    /// `nodeAcceptedSharedFlags`. An empty `--title=` or
    /// `--debug-port=` exits too. `--title=helper` and
    /// `--debug-port=-` keep the value in the flag word.
    /// `--cwd`, `--filter`, `--preload`, `--tsconfig-override`, `-W`,
    /// `-X`, `-S`, `-L`, `-o`, and `-F` are not node options, including
    /// `--cwd=/tmp` and `-Wignore`, so the path after them is not a
    /// program. A short value glued on (`-rpreload.js`, `-Cdev`) is
    /// the same exit. A long option that is not a Node boolean, a V8
    /// flag, or one of those value flags is `nodeLongOption`: Node
    /// exits, so `node --not-a-flag /tmp/codex` and `node --revision`
    /// do not run the file. An enum value Node 22.23 rejects
    /// (`--unhandled-rejections nope`, `--use-largepages OFF`) is the
    /// same exit, and so is a profiler flag whose companion is off
    /// (`--cpu-prof-name out` without `--cpu-prof`).
    /// `--max-old-space-size-percentage` exits unless `strtod` reads a
    /// value greater than 0 and at most 100 (`50`, `0x10`, and `nan`
    /// run; `nope`, `0`, `101`, and `inf` do not).
    /// `--experimental-test-isolation` exits only when `--test` is on
    /// and the last operand is not `none` or `process`. Without
    /// `--test`, `nope` still runs the file.
    /// `--heapsnapshot-near-heap-limit` exits when the last `atoll`
    /// value is negative (`=-1`, `\-1`). `0` and `abc` still run.
    /// `--secure-heap` below 0 aborts inside OpenSSL, and a value of
    /// at least 2 that is not a power of two is `CheckOptions`.
    /// `--secure-heap-min` is checked only once that heap is on, after
    /// Node clamps it. `0`, `1`, `4`, and `4abc` still run.
    /// With `--test` still on, the harness also rejects a
    /// `--test-shard` that is not `<index>/<total>` in range, a
    /// `--test-timeout` above 2147483647, a `--test-concurrency`
    /// above 4294967295, a coverage threshold outside 0...100 while
    /// coverage is on, and a reporter list whose length differs from
    /// its destinations. `0` is the unset timeout and concurrency.
    /// The last scalar wins. `--no-test` leaves those flags ignored.
    /// Bun does not use this check: `--title --watch` runs the file,
    /// `--not-a-flag` is the script, and `--cwd` takes the directory.
    /// Python's `-W` and `-X` still take the next word.
    private static func nodeOption(
        _ arg: String,
        following: String?,
        argv: [String],
        packageRun: Bool = false
    ) -> NodeOption? {
        if nodeOptionExits(arg) { return .exits }
        if nodeTakesSeparateValue(arg) {
            if let following, !following.hasPrefix("-") {
                if nodeRejectedOperand(
                    name: arg,
                    value: following,
                    argv: argv,
                    packageRun: packageRun
                ) {
                    return .exits
                }
                return .skip(2)
            }
            return .exits
        }
        return nodeLongOption(arg, argv: argv, packageRun: packageRun)
    }

    /// A Node long option after the value flags have been claimed.
    /// Nil when `arg` is not a long option, so a single dash still
    /// reaches `nodeBareShort`.
    ///
    /// `--watch`, `--interactive`, and `--experimental-strip-types`
    /// leave the next word as the script, and so does `--watch=true`.
    /// `--run` is not one of them: its operand is the package script
    /// (`nodePackageProgram`). `--test=true` is still this boolean.
    /// Whether the process runs the file is `testEqualsSkipsScript`:
    /// the child that keeps `--test=` does not, and `--no-test` or
    /// isolation `none` does. `--inspect`, `--inspect-brk`,
    /// `--inspect-wait`, and `--inspect-brk-node` are booleans, so a
    /// separate word is the script. Their `=` form is the inspector
    /// address (`nodeInspectHostPortRejects`): `--inspect=9229` names
    /// the file and `--inspect=80` does not. An empty `--inspect=` is
    /// a missing argument. `--no-inspect` names the file, and
    /// `--no-inspect=80` is not a boolean. `--use-strict` and
    /// `--harmony` are V8 booleans: the bare flag and `--no-harmony`
    /// name the file, and `--harmony=true` does not.
    /// `--max-old-space-size=4096` names the file. A separate word
    /// (`--max-old-space-size 4096`) is not a value. `--help`,
    /// `--version`, `--v8-options`, and `--completion-bash` print and
    /// exit. Anything else, including `--not-a-flag` and `--revision`,
    /// exits before the file runs.
    private static func nodeLongOption(
        _ arg: String,
        argv: [String],
        packageRun: Bool = false
    ) -> NodeOption? {
        guard let (name, value) = splitNodeFlag(arg) else { return nil }
        // `--help` and `--version` print and exit, unless `--run` names
        // a package script. Then they are ordinary booleans and the
        // script still runs.
        if NodeRuntimeFlags.printFlags.contains(name) {
            return packageRun ? .skip(1) : .exits
        }
        if nodeValueFlagName(name) {
            guard let value else { return nil }
            if value.isEmpty { return .exits }
            if nodeRejectedOperand(
                name: name,
                value: String(value),
                argv: argv,
                packageRun: packageRun
            ) {
                return .exits
            }
            return .skip(1)
        }
        if NodeRuntimeFlags.v8Values.contains(name) {
            guard let value else { return .exits }
            if value.isEmpty, NodeRuntimeFlags.v8EmptyEqualsExits.contains(name) {
                return .exits
            }
            return .skip(1)
        }
        if NodeRuntimeFlags.v8Booleans.contains(name) {
            return value == nil ? .skip(1) : .exits
        }
        if NodeRuntimeFlags.scriptBooleans.contains(name) {
            // `--test=` is not an exit at this word. The file body
            // runs or skips from the final prefix, after a later
            // `--no-test` or isolation value has been seen.
            // `--inspect=80` is the port alias, not that boolean.
            if let value, nodeInspectEqualsSetsPort(name) {
                if value.isEmpty || nodeInspectHostPortRejects(String(value)) {
                    return .exits
                }
            }
            return .skip(1)
        }
        if let positive = nodeNegatedFlag(name) {
            let nodeLike = NodeRuntimeFlags.scriptBooleans.contains(positive)
                || NodeRuntimeFlags.printFlags.contains(positive)
            if nodeLike {
                // `--no-inspect` is the boolean. `--no-inspect=80` is
                // the port alias, which is not a boolean negation.
                if value != nil, nodeInspectEqualsSetsPort(positive) {
                    return .exits
                }
                return .skip(1)
            }
            let v8Like = NodeRuntimeFlags.v8Booleans.contains(positive)
                || NodeRuntimeFlags.v8NegationOnly.contains(positive)
            if v8Like {
                return value == nil ? .skip(1) : .exits
            }
        }
        return .exits
    }

    /// `--title` and `--require`. The `=` form is not the set member;
    /// `nodeLongOption` reads the name before `=`.
    private static func nodeValueFlagName(_ name: String) -> Bool {
        nodeRequiredValueFlags.contains(name) || nodeAcceptedSharedFlags.contains(name)
    }

    /// The flag name and, when the word contains `=`, the attached value.
    /// Nil when `arg` is not a long option.
    private static func splitNodeFlag(_ arg: String) -> (name: String, value: Substring?)? {
        guard arg.hasPrefix("--") else { return nil }
        guard let equals = arg.firstIndex(of: "=") else { return (arg, nil) }
        let name = String(arg[..<equals])
        let value = arg[arg.index(after: equals)...]
        return (name, value)
    }

    /// `--no-watch` is `--watch`. `--no-no-warnings` is not a second
    /// negation: the remainder starts with `no-`, and Node rejects it.
    /// `--not-a-flag` does not start with `--no-`.
    private static func nodeNegatedFlag(_ name: String) -> String? {
        let prefix = "--no-"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard !rest.isEmpty, !rest.hasPrefix("no-") else { return nil }
        return "--" + rest
    }

    private static func nodeTakesSeparateValue(_ arg: String) -> Bool {
        nodeRequiredValueFlags.contains(arg) || nodeAcceptedSharedFlags.contains(arg)
    }

    private static func nodeOptionExits(_ arg: String) -> Bool {
        if nodeRejectedFlags.contains(arg) { return true }
        for flag in nodeRejectedFlags where flag.hasPrefix("--") {
            if arg.hasPrefix(flag + "=") { return true }
        }
        if nodeEmptyEquals(arg) { return true }
        return nodeGluedShort(arg)
    }

    /// `--title=` and `--debug-port=`. A non-empty `--title=helper`
    /// is not empty: the value stays in the word.
    private static func nodeEmptyEquals(_ arg: String) -> Bool {
        guard arg.hasSuffix("=") else { return false }
        let name = String(arg.dropLast())
        return nodeRequiredValueFlags.contains(name) || nodeAcceptedSharedFlags.contains(name)
    }

    /// `-rpreload.js` and `-Cdev`. Node has no glued short value.
    /// `-Wignore` is a rejected short with the same shape. An exact
    /// `-r` or `-C` is a separate word and is not this check.
    private static func nodeGluedShort(_ arg: String) -> Bool {
        guard arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 2 else { return false }
        let short = String(arg.prefix(2))
        if short == "-r" || short == "-C" { return true }
        return nodeRejectedFlags.contains(short)
    }

    /// Node 22.23.2 values that do not run a script. The sets are the
    /// checks in `EnvironmentOptions::CheckOptions` and `node.cc`. An
    /// empty string is the unset default for every flag except
    /// `--use-largepages`, whose default is the word `off` and whose
    /// empty word is `invalid value`. `--disable-proto=` is still
    /// `nodeEmptyEquals`: the `=` form with nothing after it exits
    /// before this set is read.
    private static let nodeEnumValues: [String: Set<String>] = [
        "--unhandled-rejections": [
            "", "strict", "throw", "warn", "none", "warn-with-error-code",
        ],
        "--dns-result-order": ["", "verbatim", "ipv4first", "ipv6first"],
        "--disable-proto": ["", "delete", "throw"],
        "--input-type": [
            "", "module", "commonjs", "module-typescript", "commonjs-typescript",
        ],
        "--experimental-default-type": ["", "module", "commonjs"],
        "--trace-require-module": ["", "all", "no-node-modules"],
        "--use-largepages": ["off", "on", "silent"],
    ]

    /// True when this operand makes Node 22.23 exit. `name` has no `=`.
    ///
    /// `--cpu-prof-name` and `--cpu-prof-dir` need `--cpu-prof` somewhere
    /// before the script. `--heap-prof-name`, `--heap-prof-dir`, and a
    /// non-default `--heap-prof-interval` need `--heap-prof`. The CPU
    /// interval's default is 1000 and the heap interval's is 524288
    /// (`512 * 1024`). `--cpu-prof-interval 1000` runs with profiling
    /// off, and so does `+1000`, `01000`, and `1000abc`: the integer
    /// parser keeps the leading number and ignores the tail. With the
    /// companion on, `nope` still runs. `--cpu-prof=false` turns
    /// profiling on. `--no-cpu-prof` turns it off, and the later flag
    /// wins. `--max-old-space-size-percentage` is `NodePercentage`:
    /// the word has to be a `strtod` value greater than 0 and at most
    /// 100, and `nan` still runs. `--experimental-test-isolation` is
    /// checked only when the final `--test` state is on. The last
    /// operand wins, and only `none` and `process` run. A later
    /// `--no-test` leaves the file running, including `nope`. A script
    /// written first is not this check. A `--test=` whose child still
    /// has the runner on is `testEqualsSkipsScript`: the process runs
    /// and does not execute the file. `--no-test` and isolation `none`
    /// do, so this word is not where that decision is made.
    /// `--heapsnapshot-near-heap-limit` uses `std::atoll`: a negative
    /// result exits, and the last operand wins. `abc` is 0 and still
    /// runs. `--secure-heap` below 0 does not run the file (OpenSSL
    /// aborts). A heap of at least 2 has to be a power of two.
    /// `--secure-heap-min` is read only then, after the clamp in
    /// `PerProcessOptions::CheckOptions`. The last operand of each
    /// flag wins, so an earlier `3` does not hide a later `4`.
    /// `--test-shard`, `--test-timeout`, `--test-concurrency`, the
    /// coverage thresholds, the reporter list, and a test name or
    /// skip pattern are `nodeTestHarnessRejects`. They throw inside
    /// the test runner, and only when the final `--test` state is on.
    /// A pattern throws when `convertStringToRegExp` throws. A `v`
    /// class the unicodeSets grammar rejects does too. An unknown
    /// `\p` name and a property that contains strings do too. A
    /// source scalar above U+FFFF is one code point when `u` or `v`
    /// is set, and a lead/trail pair otherwise, so a legacy range
    /// across that pair is the same check.
    /// `--inspect-port` and `--debug-port` are `SplitHostPort`. A port
    /// outside 0 and 1024...65535 exits. Node records every address, so
    /// a later 9229 does not erase an earlier 80. `9229`, `0`, `[::1]`,
    /// and `localhost:` still run. A script written first is not this check.
    private static func nodeRejectedOperand(
        name: String,
        value: String,
        argv: [String],
        packageRun: Bool = false
    ) -> Bool {
        if let allowed = nodeEnumValues[name] {
            return !allowed.contains(value)
        }
        if name == "--inspect-port" || name == "--debug-port" {
            // The last address is not the only one checked. Node
            // records an error for every value, so 80 beside 9229
            // still exits. `[::1]` and `65536abc` (a hostname) do not.
            return nodeInspectHostPortRejects(value)
        }
        if name == "--inspect-publish-uid" {
            return !nodePublishUID(value)
        }
        if name == "--max-old-space-size-percentage" {
            // `strtod`, not an enum. An empty word is the unset field
            // and the file still runs. `0x10` and `nan` run. `nope` does not.
            return NodePercentage.rejects(value)
        }
        let prefix = nodePrefixFlags(argv)
        // A package script still runs when the harness would throw.
        // `CheckOptions` (isolation, the secure heap, conflicts) does not.
        if !packageRun, nodeTestHarnessRejects(name, prefix: prefix) {
            return true
        }
        if name == "--heapsnapshot-near-heap-limit" {
            // The last operand, not this word. `=-1` and a separate
            // `\-1` are negative. `abc` is 0. A separate `-1` never
            // reaches here: it is a missing argument.
            return prefix.nearHeapLimit < 0
        }
        if name == "--secure-heap" || name == "--secure-heap-min" {
            return nodeSecureHeapExits(heap: prefix.secureHeap, minimum: prefix.secureHeapMin)
        }
        if name == "--experimental-test-isolation" {
            // `CheckOptions` reads this only inside `if (test_runner)`.
            // The last operand wins. `none` and `process` are the only
            // words that run. An empty word, `NONE`, and `nope` do not.
            // `--no-test` after `--test` leaves the flag ignored, so
            // the file still runs. The value on this word is not the
            // decision: a later `none` replaces an earlier `nope`.
            guard prefix.testRunner, let isolation = prefix.testIsolation else {
                return false
            }
            return isolation != "none" && isolation != "process"
        }
        switch name {
        case "--cpu-prof-name", "--cpu-prof-dir":
            return !value.isEmpty && !prefix.cpuProf
        case "--heap-prof-name", "--heap-prof-dir":
            return !value.isEmpty && !prefix.heapProf
        case "--cpu-prof-interval":
            return !prefix.cpuProf && !nodeIntegerPrefixEquals(value, 1000)
        case "--heap-prof-interval":
            return !prefix.heapProf && !nodeIntegerPrefixEquals(value, 524288)
        case "--allow-fs-read", "--allow-fs-write":
            // Both exit unless `--permission` (or its alias
            // `--experimental-permission`) is on before the script.
            // `--allow-addons` does not: it runs with the flag off.
            return !prefix.permission
        default:
            return false
        }
    }

    /// `--inspect=`, `--inspect-brk=`, `--inspect-wait=`, and
    /// `--inspect-brk-node=`. The bare flag is a boolean. The `=`
    /// form is the inspector address.
    private static func nodeInspectEqualsSetsPort(_ name: String) -> Bool {
        switch name {
        case "--inspect", "--inspect-brk", "--inspect-wait", "--inspect-brk-node":
            return true
        default:
            return false
        }
    }

    /// True when Node 22.23's `SplitHostPort` rejects this address.
    ///
    /// A word that starts with `[` and ends with `]` is a host with
    /// the default port, including `[::1]:80]`. Otherwise the text
    /// after the last `:`, or the whole word when every character is
    /// a digit, is `from_chars` into `uint16_t`. Overflow, and a value
    /// that is not 0 and is below 1024, exit. No digit (`abc`, `+1024`,
    /// a leading space) leaves the port at 0 and still runs. Trailing
    /// junk after a colon is ignored once a prefix fits
    /// (`host:1024abc` runs, `host:1023abc` and `host:65536abc` do not).
    /// `65536abc` with no colon is a hostname. `::1` is port 1.
    /// `--inspect 80` is not this check: the separate word is the script.
    private static func nodeInspectHostPortRejects(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        if scalars.count >= 2, scalars[0].value == 91, scalars[scalars.count - 1].value == 93 {
            return false
        }
        if let colon = scalars.lastIndex(where: { $0.value == 58 }) {
            let port = Array(scalars[scalars.index(after: colon)...])
            return nodeInspectPortNumberRejects(port)
        }
        let allDigits = !scalars.isEmpty && scalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
        if allDigits {
            return nodeInspectPortNumberRejects(scalars)
        }
        return false
    }

    /// `std::from_chars` base 10 into `uint16_t`, then Node's range.
    /// The digit run stops at the first non-digit. No digit is port 0,
    /// which is allowed. A run that does not fit in `uint16_t` is an
    /// error even when junk follows. A value that fits ignores that
    /// junk. 0 is allowed. 1...1023 is not. 1024...65535 is allowed.
    private static func nodeInspectPortNumberRejects(_ scalars: [Unicode.Scalar]) -> Bool {
        var index = 0
        var magnitude: UInt64 = 0
        var digits = 0
        var overflow = false
        let limit = UInt64(UInt16.max)
        while index < scalars.count {
            let code = scalars[index].value
            guard code >= 48, code <= 57 else { break }
            let digit = UInt64(code - 48)
            if magnitude > (limit - digit) / 10 {
                overflow = true
                break
            }
            magnitude = magnitude * 10 + digit
            digits += 1
            index += 1
        }
        if digits == 0 { return false }
        if overflow { return true }
        return magnitude != 0 && magnitude < 1024
    }

    /// `stderr` and `http`, comma-separated. An empty segment is
    /// ignored, so `,` and `stderr,` still run. `STDERR` and
    /// `stderr,nope` do not. A space after the comma is part of the
    /// token.
    private static func nodePublishUID(_ value: String) -> Bool {
        for token in value.split(separator: ",", omittingEmptySubsequences: false) {
            if token.isEmpty { continue }
            let word = String(token)
            if word != "stderr" && word != "http" { return false }
        }
        return true
    }

    /// The leading integer `strtoll` would keep. Leading C whitespace
    /// and one `+` or `-` are allowed. At least one digit is required.
    /// The rest of the word is ignored, so `1000.5abc` is 1000. No
    /// digit (`nope`, `+`) does not match. A value that does not fit in
    /// `Int64` does not match.
    private static func nodeIntegerPrefixEquals(_ value: String, _ target: Int64) -> Bool {
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count, nodeIsCSpace(scalars[index]) {
            index += 1
        }
        var negative = false
        if index < scalars.count, scalars[index].value == 43 || scalars[index].value == 45 {
            negative = scalars[index].value == 45
            index += 1
        }
        var digits = 0
        var number: Int64 = 0
        while index < scalars.count {
            let character = scalars[index]
            guard character.value >= 48, character.value <= 57 else { break }
            let digit = Int64(character.value - 48)
            if number > (Int64.max - digit) / 10 { return false }
            number = number * 10 + digit
            digits += 1
            index += 1
        }
        guard digits > 0 else { return false }
        if negative {
            if number == Int64.max { return false }
            number = -number
        }
        return number == target
    }

    /// `isspace` in the C locale: space, tab, newline, vertical tab,
    /// form feed, carriage return.
    private static func nodeIsCSpace(_ character: Unicode.Scalar) -> Bool {
        switch character.value {
        case 9, 10, 11, 12, 13, 32:
            return true
        default:
            return false
        }
    }

    private enum NodeIntegerFlag {
        case secureHeap
        case secureHeapMin
        case nearHeapLimit
    }

    /// One integer option and the `std::atoll` value Node keeps.
    private struct NodeIntegerOperand {
        var flag: NodeIntegerFlag
        var value: Int64
        var width: Int
    }

    /// `--secure-heap`, `--secure-heap-min`, and
    /// `--heapsnapshot-near-heap-limit`. Nil for every other word.
    ///
    /// The minimum is matched before the heap so `--secure-heap-min`
    /// is not the shorter name. An attached value is `atoll` of the
    /// text after `=`, backslash included. A separate `\-1` drops that
    /// backslash first. A missing word is 0; the walk already treats
    /// that as a missing argument and does not name a script.
    private static func nodeIntegerOperand(
        _ arg: String,
        argv: [String],
        index: Int
    ) -> NodeIntegerOperand? {
        let flags: [(String, NodeIntegerFlag)] = [
            ("--secure-heap-min", .secureHeapMin),
            ("--secure-heap", .secureHeap),
            ("--heapsnapshot-near-heap-limit", .nearHeapLimit),
        ]
        for (name, flag) in flags {
            if arg == name {
                let raw = index + 1 < argv.count ? argv[index + 1] : ""
                return NodeIntegerOperand(
                    flag: flag,
                    value: nodeAtoll(nodeUnescapedDash(raw)),
                    width: 2
                )
            }
            let attached = name + "="
            if arg.hasPrefix(attached) {
                return NodeIntegerOperand(
                    flag: flag,
                    value: nodeAtoll(String(arg.dropFirst(attached.count))),
                    width: 1
                )
            }
        }
        return nil
    }

    /// A separate word `\-1` is the value `-1`. Node only strips that
    /// prefix when the word was not attached with `=`.
    private static func nodeUnescapedDash(_ value: String) -> String {
        guard value.hasPrefix("\\-") else { return value }
        return String(value.dropFirst())
    }

    /// `std::atoll`. Leading C whitespace, one optional sign, then
    /// base-10 digits. The rest of the word is ignored, so `4abc` is 4
    /// and `0x10` is 0. No digit is 0. A value past `Int64` saturates.
    private static func nodeAtoll(_ value: String) -> Int64 {
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count, nodeIsCSpace(scalars[index]) {
            index += 1
        }
        var negative = false
        if index < scalars.count {
            let sign = scalars[index].value
            if sign == 43 || sign == 45 {
                negative = sign == 45
                index += 1
            }
        }
        var magnitude: UInt64 = 0
        var digits = 0
        var overflow = false
        while index < scalars.count {
            let character = scalars[index]
            guard character.value >= 48, character.value <= 57 else { break }
            let digit = UInt64(character.value - 48)
            if magnitude > (UInt64.max - digit) / 10 {
                overflow = true
                break
            }
            magnitude = magnitude * 10 + digit
            digits += 1
            index += 1
        }
        if digits == 0 { return 0 }
        if negative {
            let limit = UInt64(Int64.max) + 1
            if overflow || magnitude >= limit { return Int64.min }
            return -Int64(magnitude)
        }
        if overflow || magnitude > UInt64(Int64.max) { return Int64.max }
        return Int64(magnitude)
    }

    /// OpenSSL aborts when `--secure-heap` is negative, so the file
    /// does not run. `CheckOptions` rejects a heap of at least 2 that
    /// is not a power of two, then clamps the minimum to
    /// `max(2, min(heap, minimum, INT_MAX))` and requires that to be a
    /// power of two as well. A heap below 2 is off, and the minimum
    /// is not read.
    private static func nodeSecureHeapExits(heap: Int64, minimum: Int64) -> Bool {
        if heap < 0 { return true }
        if heap < 2 { return false }
        if !nodeIsPowerOfTwo(heap) { return true }
        let clamped = max(Int64(2), min(minimum, min(heap, Int64(Int32.max))))
        return !nodeIsPowerOfTwo(clamped)
    }

    private static func nodeIsPowerOfTwo(_ value: Int64) -> Bool {
        value > 0 && value & (value - 1) == 0
    }

    /// `std::strtoull` base 10. Leading C whitespace, one optional
    /// sign, then digits. The rest of the word is ignored, so `10abc`
    /// is 10, `1e2` is 1, and `0x10` is 0. No digit is 0. A value past
    /// `UInt64` saturates, including a negative whose magnitude
    /// overflows. `-1` wraps to `UInt64.max`. An attached `\-1` keeps
    /// the backslash, so this reads 0; the caller strips that prefix
    /// only for a separate word.
    private static func nodeStrtoull(_ value: String) -> UInt64 {
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count, nodeIsCSpace(scalars[index]) {
            index += 1
        }
        var negative = false
        if index < scalars.count {
            let sign = scalars[index].value
            if sign == 43 || sign == 45 {
                negative = sign == 45
                index += 1
            }
        }
        var magnitude: UInt64 = 0
        var digits = 0
        var overflow = false
        while index < scalars.count {
            let character = scalars[index]
            guard character.value >= 48, character.value <= 57 else { break }
            let digit = UInt64(character.value - 48)
            if magnitude > (UInt64.max - digit) / 10 {
                overflow = true
                break
            }
            magnitude = magnitude * 10 + digit
            digits += 1
            index += 1
        }
        if digits == 0 { return 0 }
        if overflow { return UInt64.max }
        if negative { return 0 &- magnitude }
        return magnitude
    }

    /// One test-runner option and the value Node keeps. Nil for every
    /// other word. Longer names are matched first so
    /// `--test-reporter-destination` is not `--test-reporter`.
    ///
    /// A separate word is unescaped when it starts with `\-`. An
    /// attached value keeps that backslash. A missing word is empty;
    /// the walk already treats a dash word and an empty `--flag=` as
    /// a missing argument and does not name a script.
    private enum NodeTestValue {
        case reporter
        case destination
        case shard(String)
        case timeout(UInt64)
        case concurrency(UInt64)
        case lines(UInt64)
        case branches(UInt64)
        case functions(UInt64)
        /// The operand text, with a separate `\-` left in place.
        case pattern(String)
    }

    private struct NodeTestOperand {
        var value: NodeTestValue
        var width: Int
    }

    private static func nodeTestOperand(
        _ arg: String,
        argv: [String],
        index: Int
    ) -> NodeTestOperand? {
        // Name and skip patterns keep the argv text. A leading `\-`
        // is not the numeric unescape `nodeUnescapedDash` applies
        // to a shard or a timeout.
        if let pattern = nodePatternOperand(arg, argv: argv, index: index) {
            return pattern
        }
        let flags: [(String, (String) -> NodeTestValue)] = [
            ("--test-reporter-destination", { _ in .destination }),
            ("--test-reporter", { _ in .reporter }),
            ("--test-shard", { .shard($0) }),
            ("--test-timeout", { .timeout(nodeStrtoull($0)) }),
            ("--test-concurrency", { .concurrency(nodeStrtoull($0)) }),
            ("--test-coverage-lines", { .lines(nodeStrtoull($0)) }),
            ("--test-coverage-branches", { .branches(nodeStrtoull($0)) }),
            ("--test-coverage-functions", { .functions(nodeStrtoull($0)) }),
        ]
        for (name, make) in flags {
            if arg == name {
                let raw = index + 1 < argv.count ? argv[index + 1] : ""
                return NodeTestOperand(value: make(nodeUnescapedDash(raw)), width: 2)
            }
            let attached = name + "="
            if arg.hasPrefix(attached) {
                let text = String(arg.dropFirst(attached.count))
                return NodeTestOperand(value: make(text), width: 1)
            }
        }
        return nil
    }

    /// `--test-name-pattern` and `--test-skip-pattern`, including the
    /// `=` form. Nil for every other word. The operand is not run
    /// through `nodeUnescapedDash`.
    private static func nodePatternOperand(
        _ arg: String,
        argv: [String],
        index: Int
    ) -> NodeTestOperand? {
        let names = ["--test-skip-pattern", "--test-name-pattern"]
        for name in names {
            if arg == name {
                let raw = index + 1 < argv.count ? argv[index + 1] : ""
                return NodeTestOperand(value: .pattern(raw), width: 2)
            }
            let attached = name + "="
            if arg.hasPrefix(attached) {
                let text = String(arg.dropFirst(attached.count))
                return NodeTestOperand(value: .pattern(text), width: 1)
            }
        }
        return nil
    }

    /// True when Node 22.23's test harness throws this flag before the
    /// file runs. `name` has no `=`. The decision is the final prefix,
    /// so a later good shard, timeout, concurrency, or coverage operand
    /// replaces an earlier bad one. A name or skip pattern does not:
    /// every operand is compiled, and any throw stops the file.
    ///
    /// `--test-shard` has to match `^\d+/\d+$`. Each side is
    /// `parseInt` and has to be a safe integer from 1 through the
    /// total. `--test-timeout` uses `strtoull`; `0` is falsy and
    /// becomes the default, and any other value above 2147483647
    /// throws. `--test-concurrency` is the same with 4294967295.
    /// The three coverage thresholds throw only while
    /// `--experimental-test-coverage` is on, and only outside 0...100.
    /// Reporter and destination counts have to match after one missing
    /// destination is filled in for a single reporter. `--no-test`
    /// leaves every one of these ignored. A reporter name that is not
    /// a builtin is not this check: the pane may be able to load it.
    private static func nodeTestHarnessRejects(_ name: String, prefix: NodePrefix) -> Bool {
        guard prefix.testRunner else { return false }
        switch name {
        case "--test-shard":
            guard let shard = prefix.shard else { return false }
            return nodeShardExits(shard)
        case "--test-timeout":
            return prefix.timeout > 2_147_483_647
        case "--test-concurrency":
            return prefix.concurrency > 4_294_967_295
        case "--test-coverage-lines", "--test-coverage-branches", "--test-coverage-functions":
            guard prefix.coverage else { return false }
            return prefix.coverageLines > 100
                || prefix.coverageBranches > 100
                || prefix.coverageFunctions > 100
        case "--test-reporter", "--test-reporter-destination":
            return nodeReporterCountRejects(
                reporters: prefix.reporterCount,
                destinations: prefix.destinationCount
            )
        case "--test-name-pattern", "--test-skip-pattern":
            return prefix.testPatterns.contains { NodeTestPattern.rejects($0) }
        default:
            return false
        }
    }

    /// `parseInt` of a digit string, when the result is a safe integer.
    /// Nil when a character is not a digit, or the value is above
    /// `Number.MAX_SAFE_INTEGER`. Leading zeros do not change it.
    /// `0` is returned: the shard range rejects it afterwards.
    private static func nodeSafeInteger(_ digits: Substring) -> Int64? {
        var magnitude: UInt64 = 0
        var digitsSeen = 0
        for character in digits {
            guard isASCIIDigit(character),
                  let scalar = character.unicodeScalars.first else {
                return nil
            }
            let digit = UInt64(scalar.value - 48)
            if magnitude > (UInt64.max - digit) / 10 { return nil }
            magnitude = magnitude * 10 + digit
            digitsSeen += 1
        }
        guard digitsSeen > 0, magnitude <= 9_007_199_254_740_991 else { return nil }
        return Int64(magnitude)
    }

    /// The shard grammar and range in `parseCommandLine` and `run`.
    /// Anything that is not `<index>/<total>`, or whose index is
    /// outside `1...total`, throws before the file. `01/02` is `1/2`.
    /// `2/2` is in range: the harness accepts it, and which file runs
    /// depends on the list.
    private static func nodeShardExits(_ shard: String) -> Bool {
        let parts = shard.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let index = nodeSafeInteger(parts[0]),
              let total = nodeSafeInteger(parts[1]) else {
            return true
        }
        return index < 1 || total < 1 || index > total
    }

    /// Reporter and destination vectors have to be the same length.
    /// No flags is the default reporter. One reporter and no
    /// destination is stdout. Every other mismatch throws before the
    /// files run, including two reporters and no destination.
    private static func nodeReporterCountRejects(reporters: Int, destinations: Int) -> Bool {
        var destinations = destinations
        if reporters == 0 && destinations == 0 { return false }
        if reporters == 1 && destinations == 0 {
            destinations = 1
        }
        return destinations != reporters
    }

    /// Booleans and the last integer operands, read from the flags
    /// before the first positional. A later `--no-` wins, and
    /// `--flag=false` is still on: Node's boolean parser does not read
    /// the attached word. `--cpu-prof-name` is not `--cpu-prof`.
    private struct NodePrefix {
        var cpuProf = false
        var heapProf = false
        var tlsMin13 = false
        var tlsMax12 = false
        var opensslCA = false
        var bundledCA = false
        var permission = false
        /// Final `--test` / `--no-test` state. `--test=true` is on:
        /// Node's boolean parser ignores the attached word.
        var testRunner = false
        /// Final `--test` state the child inherits. `filterExecArgv`
        /// drops a bare `--test` and keeps `--test=` and `--no-test`.
        /// When this stays on, that child is itself a test runner and
        /// does not execute the file.
        var childTestRunner = false
        /// Final `--interactive` / `-i` / `--no-interactive` state.
        /// `--interactive=false` is still on: the parser ignores the
        /// attached word. `-i` is the alias and is set by the scan.
        var interactive = false
        /// Final `--watch` / `--no-watch` state. `--watch=false` is
        /// still on. `--watch-path` implies `--watch` at the moment
        /// the path is seen, including after `--no-watch`. A later
        /// `--no-watch` clears this and leaves the path list.
        /// `--watch-preserve-output` does not imply `--watch`.
        var watch = false
        /// Final `--test-force-exit` / `--no-test-force-exit` state.
        /// `--test-force-exit=false` is still on.
        var testForceExit = false
        /// `--watch-path` appeared before the script. The path may be
        /// attached (`--watch-path=/tmp`) or the next word. `--watch`
        /// without this flag is not a conflict with `--test`.
        var watchPath = false
        /// Last `--experimental-test-isolation` operand before the
        /// script. Nil when that flag was not set. Node keeps the last
        /// one, including an empty word.
        var testIsolation: String?
        /// Last `--secure-heap` before the script. `std::atoll`. The
        /// default 0 leaves the secure heap off.
        var secureHeap: Int64 = 0
        /// Last `--secure-heap-min`. The default is 2, which is what
        /// Node uses when the flag is absent. Checked only when
        /// `secureHeap` is at least 2.
        var secureHeapMin: Int64 = 2
        /// Last `--heapsnapshot-near-heap-limit`. The default is 0.
        /// A negative value exits in `CheckOptions`.
        var nearHeapLimit: Int64 = 0
        /// Final `--experimental-test-coverage` state.
        /// `--experimental-test-coverage=false` is still on.
        var coverage = false
        /// How many `--test-reporter` values appear before the script.
        var reporterCount = 0
        /// How many `--test-reporter-destination` values appear.
        var destinationCount = 0
        /// Last `--test-shard` text, after a separate `\-` is stripped.
        /// Nil when the flag was not set. An empty word is still set.
        var shard: String?
        /// Last `--test-timeout`. `strtoull`. `0` is the unset default
        /// and does not throw. A value above 2147483647 does.
        var timeout: UInt64 = 0
        /// Last `--test-concurrency`. `0` is the unset default. A value
        /// above 4294967295 throws.
        var concurrency: UInt64 = 0
        /// Last coverage thresholds. `strtoull`, default 0. Checked
        /// only when `coverage` is on, and only outside 0...100.
        var coverageLines: UInt64 = 0
        var coverageBranches: UInt64 = 0
        var coverageFunctions: UInt64 = 0
        /// Every `--test-name-pattern` and `--test-skip-pattern` operand
        /// before the script. The harness compiles each one. A later
        /// valid pattern does not erase an earlier one that throws.
        /// A separate `\-` stays in the text. This is a string option,
        /// not the numeric unescape the shard path uses.
        var testPatterns: [String] = []
        /// `--experimental-sea-config` had a non-empty path before the
        /// first positional. Node writes the single-executable blob and
        /// returns, so the positional is not the program. A missing
        /// config file still counts: both outcomes leave that word
        /// unexecuted. An empty `=` or a separate word that starts
        /// with `-` is a missing argument and stays false. A separate
        /// empty word is an empty config string and stays false too:
        /// the next word still runs. `--run` is decided before this
        /// flag is consulted.
        var seaConfig = false
        /// Final `--build-snapshot` state. `--build-snapshot-config`
        /// implies this when that flag is seen, before its value is
        /// stored. A later `--no-build-snapshot` clears it and leaves
        /// the config path. `--build-snapshot=false` is still on: the
        /// parser ignores the attached word.
        var buildSnapshot = false
        /// Last non-empty `--build-snapshot-config` path before the
        /// first positional. An empty separate word clears it. Nil
        /// when the flag was absent or the last value was empty. A
        /// missing argument does not change it.
        var snapshotConfigPath: String?
        /// A `--build-snapshot-config` value was missing. The parser
        /// exits before the builder runs, including when an earlier
        /// config path is still stored.
        var snapshotConfigExits = false

        /// Snapshot building is on and a config path is set. Node runs
        /// the JSON `builder`, or exits when the file cannot be read.
        /// The positional is not the program. `--no-build-snapshot`
        /// after the config leaves this false.
        var snapshotConfigSkipsScript: Bool {
            buildSnapshot && snapshotConfigPath != nil
        }

        /// TLS pair, CA pair, `--test` with `--interactive` / `-i` or
        /// with `--watch-path`, or `--watch` with `--interactive` /
        /// `-i` or with `--test-force-exit`. `CheckOptions` rejects
        /// each of those before the file runs. `--watch` beside
        /// `--test`, with no path list, still runs. A later `--no-`
        /// wins for the booleans. `--watch-path` is not a boolean, so
        /// the path list stays set after `--no-watch`.
        var conflicts: Bool {
            (tlsMin13 && tlsMax12) || (opensslCA && bundledCA)
                || (testRunner && interactive)
                || (testRunner && watchPath)
                || (watch && interactive)
                || (watch && testForceExit)
        }

        /// Process isolation, the runner is on, and the child still
        /// has `--test=`. That child skips the file body. Isolation
        /// `none` runs the file in this process. A later `--no-test`
        /// clears the child, and a bare `--test` after that is the
        /// parent harness whose child does run the file.
        var testEqualsSkipsScript: Bool {
            testRunner && childTestRunner && testIsolation != "none"
        }

        mutating func set(_ flag: NodeBoolFlag, on: Bool) {
            switch flag {
            case .cpu: cpuProf = on
            case .heap: heapProf = on
            case .tlsMin: tlsMin13 = on
            case .tlsMax: tlsMax12 = on
            case .openssl: opensslCA = on
            case .bundled: bundledCA = on
            case .permission: permission = on
            case .test: testRunner = on
            case .interactive: interactive = on
            case .watch: watch = on
            case .testForceExit: testForceExit = on
            case .coverage: coverage = on
            case .buildSnapshot: buildSnapshot = on
            }
        }
    }

    private enum NodeBoolFlag {
        case cpu
        case heap
        case tlsMin
        case tlsMax
        case openssl
        case bundled
        case permission
        case test
        case interactive
        case watch
        case testForceExit
        case coverage
        case buildSnapshot
    }

    private static func nodePrefixFlags(_ argv: [String]) -> NodePrefix {
        var state = NodePrefix()
        guard let first = argv.first, isNodeRuntime(shellBase(first)) else { return state }
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            // The operand is the package script, not a program file, so
            // flags after it still count. A dash operand is malformed;
            // the package walker exits on that before this state matters.
            if arg == "--run" {
                index += 2
                continue
            }
            if arg.hasPrefix("--run=") || arg == "--no-run" || arg.hasPrefix("--no-run=") {
                index += 1
                continue
            }
            if arg == "--" || !arg.hasPrefix("-") { break }
            // `-i` is `--interactive`. Node does not cluster shorts, so
            // `-ii` is a different word and is not this flag.
            if arg == "-i" {
                state.interactive = true
                index += 1
                continue
            }
            if let (flag, on) = nodeBooleanUpdate(arg) {
                state.set(flag, on: on)
                // A bare `--test` is stripped from the child's execArgv.
                // `--test=` and `--no-test` are not, so only those move
                // the state the child actually runs with.
                if case .test = flag, arg != "--test" {
                    state.childTestRunner = on
                }
                index += 1
                continue
            }
            if let isolation = nodeIsolationOperand(arg, argv: argv, index: index) {
                state.testIsolation = isolation.value
                index += isolation.width
                continue
            }
            // Implies `--watch` at this word, which is what makes
            // `--watch-path` conflict with `--interactive` and
            // `--test-force-exit`. The `--test` conflict is the path
            // list, so `--no-watch` afterwards clears watch mode and
            // leaves the list. `--watch` without this flag still runs
            // beside `--test`. A dash word in the value slot still
            // exits in the walk; counting the flag here does not name
            // a script.
            if arg == "--watch-path" || arg.hasPrefix("--watch-path=") {
                state.watchPath = true
                state.watch = true
                index += arg.hasPrefix("--watch-path=") ? 1 : 2
                continue
            }
            if let integer = nodeIntegerOperand(arg, argv: argv, index: index) {
                switch integer.flag {
                case .secureHeap:
                    state.secureHeap = integer.value
                case .secureHeapMin:
                    state.secureHeapMin = integer.value
                case .nearHeapLimit:
                    state.nearHeapLimit = integer.value
                }
                index += integer.width
                continue
            }
            // The harness reads these after option parsing. The width
            // matches `nodeTakesSeparateValue`, so the script is still
            // the word after the operand. A later flag replaces a scalar.
            if let testOperand = nodeTestOperand(arg, argv: argv, index: index) {
                switch testOperand.value {
                case .reporter:
                    state.reporterCount += 1
                case .destination:
                    state.destinationCount += 1
                case .shard(let shard):
                    state.shard = shard
                case .timeout(let value):
                    state.timeout = value
                case .concurrency(let value):
                    state.concurrency = value
                case .lines(let value):
                    state.coverageLines = value
                case .branches(let value):
                    state.coverageBranches = value
                case .functions(let value):
                    state.coverageFunctions = value
                case .pattern(let text):
                    state.testPatterns.append(text)
                }
                index += testOperand.width
                continue
            }
            // A non-empty path makes Node write the blob and return.
            // The word after that path is not a program. An empty
            // `=` and a separate dash word are a missing argument,
            // so this stays false and the walk exits. `--run` was
            // skipped above; a package script still runs.
            if nodeSeaConfigSetsBlob(arg, argv: argv, index: index) {
                state.seaConfig = true
            }
            // Implies `--build-snapshot` before the value is stored.
            // A non-empty path replaces the previous one. An empty
            // separate word clears it, and the positional is the
            // builder. A missing value does not clear a path already
            // stored; the parser exits on that word.
            if let config = nodeSnapshotConfigValue(arg, argv: argv, index: index) {
                state.buildSnapshot = true
                switch config {
                case .path(let path):
                    state.snapshotConfigPath = path
                case .empty:
                    state.snapshotConfigPath = nil
                case .missing:
                    state.snapshotConfigExits = true
                }
            }
            let width = arg.contains("=") || !nodeTakesSeparateValue(arg) ? 1 : 2
            index += width
        }
        return state
    }

    /// True when this word is `--experimental-sea-config` and the
    /// value is a path Node will try to read.
    ///
    /// `sea.json` and `--experimental-sea-config=sea.json` are that
    /// path, including a value that is only spaces and an attached
    /// value that starts with `-` (`=--watch` is a filename). A
    /// separate word that starts with `-`, an empty `=`, and a
    /// missing word are not: the parser exits before the blob, and
    /// the walk reports that exit. A separate empty word is an empty
    /// config string, so this stays false and the next word still
    /// runs. The positional after a real path is not the program.
    private static func nodeSeaConfigSetsBlob(
        _ arg: String,
        argv: [String],
        index: Int
    ) -> Bool {
        if arg == "--experimental-sea-config" {
            guard index + 1 < argv.count else { return false }
            let value = argv[index + 1]
            return !value.isEmpty && !value.hasPrefix("-")
        }
        let prefix = "--experimental-sea-config="
        guard arg.hasPrefix(prefix) else { return false }
        return arg.count > prefix.count
    }

    /// What `--build-snapshot-config` contributes on this word.
    private enum SnapshotConfigValue {
        /// A path Node will try to open, including spaces and
        /// `=--watch`. A separate `\-file` is the filename `-file`.
        case path(String)
        /// A separate empty word. The config string becomes empty and
        /// the positional is the builder.
        case empty
        /// No word, an empty `=`, or a separate word that starts with
        /// `-`. The parser exits. The stored path is left as it was.
        case missing
    }

    /// The config value, or nil when this word is not the flag.
    ///
    /// `snap.json` and `--build-snapshot-config=snap.json` are paths.
    /// A separate word that starts with `-`, an empty `=`, and a
    /// missing word are not stored. A separate empty word clears the
    /// path. The implication that turns `--build-snapshot` on is
    /// applied by the caller for every one of these, which is the
    /// order in `OptionsParser::Parse`.
    private static func nodeSnapshotConfigValue(
        _ arg: String,
        argv: [String],
        index: Int
    ) -> SnapshotConfigValue? {
        if arg == "--build-snapshot-config" {
            guard index + 1 < argv.count else { return .missing }
            let value = argv[index + 1]
            if value.isEmpty { return .empty }
            if value.hasPrefix("-") { return .missing }
            if value.hasPrefix("\\-") {
                return .path(String(value.dropFirst()))
            }
            return .path(value)
        }
        let prefix = "--build-snapshot-config="
        guard arg.hasPrefix(prefix) else { return nil }
        let value = String(arg.dropFirst(prefix.count))
        return value.isEmpty ? .missing : .path(value)
    }

    /// The user script `--build-snapshot-config` runs, or nil when
    /// Node does not run one.
    ///
    /// The path is the process's, joined to `cwd` when it is relative.
    /// A missing file, a directory, JSON that is not an object, a
    /// `builder` that is missing or empty, and a `withoutCodeCache`
    /// that is not a boolean are the exits `ReadSnapshotConfig`
    /// reports. `node:generate_default_snapshot`,
    /// `node:generate_default_snapshot_source`, and
    /// `node:embedded_snapshot_main` do not run a user file. Any other
    /// builder is the script only when that path is a readable file:
    /// Node reads it before the snapshot is written, and a missing
    /// builder exits. The positional is never this result. A config
    /// larger than 1 MiB is not read, so a path aimed at a huge file
    /// cannot stall the sample.
    private static func snapshotBuilderScript(configPath: String, cwd: String?) -> String? {
        guard let file = resolveSnapshotFile(configPath, cwd: cwd),
              let data = snapshotConfigData(at: file),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            return nil
        }
        if let flag = object["withoutCodeCache"], !jsonIsBool(flag) {
            return nil
        }
        guard let builder = object["builder"] as? String, !builder.isEmpty else { return nil }
        if snapshotBuiltinBuilders.contains(builder) { return nil }
        guard let builderFile = resolveSnapshotFile(builder, cwd: cwd) else { return nil }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: builderFile, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: builderFile) else {
            return nil
        }
        return builder
    }

    /// Node's three builder names that do not read a user script.
    private static let snapshotBuiltinBuilders: Set<String> = [
        "node:generate_default_snapshot",
        "node:generate_default_snapshot_source",
        "node:embedded_snapshot_main",
    ]

    /// Absolute path, or a relative path joined to an absolute process
    /// cwd. The config and the builder are files, not `PATH` lookups,
    /// so a bare name is joined. Without that cwd the pane's directory
    /// is not this process's, and the file is treated as unreadable.
    /// A backslash path is a Windows file and is not opened here.
    private static func resolveSnapshotFile(_ token: String, cwd: String?) -> String? {
        if token.hasPrefix("/") { return token }
        if token.contains("\\") { return nil }
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        let prefix = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return prefix + "/" + token
    }

    /// The config bytes, when the path is a readable file of at most
    /// 1 MiB. A directory and a larger file are the same as a missing
    /// config: the positional is not ranked in their place.
    private static func snapshotConfigData(at path: String) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0,
              size.int64Value <= 1_048_576,
              let kind = attributes[.type] as? FileAttributeType,
              kind == .typeRegular,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return data
    }

    /// JSON `true` and `false` only. A number is not a boolean, which
    /// is the check that rejects `"withoutCodeCache": 1`.
    /// `JSONSerialization` boxes booleans as `CFBoolean`.
    private static func jsonIsBool(_ value: Any) -> Bool {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        return value is Bool
    }

    /// The operand of `--experimental-test-isolation`, and how many
    /// words it occupies. Nil when `arg` is a different option.
    ///
    /// `--flag=none` keeps `none` in the word. A separate word is the
    /// next argv entry. A word that starts with `-` is still a missing
    /// argument in the walk, so that invocation is not a script. A
    /// missing word is empty. The last operand, including that empty
    /// word, is what `nodeRejectedOperand` reads.
    private static func nodeIsolationOperand(
        _ arg: String,
        argv: [String],
        index: Int
    ) -> (value: String, width: Int)? {
        if arg == "--experimental-test-isolation" {
            let value = index + 1 < argv.count ? argv[index + 1] : ""
            return (value, 2)
        }
        let prefix = "--experimental-test-isolation="
        guard arg.hasPrefix(prefix) else { return nil }
        return (String(arg.dropFirst(prefix.count)), 1)
    }

    /// `--cpu-prof`, `--cpu-prof=false`, and `--no-cpu-prof=true`.
    /// The word before `=` is the flag. Nil when `arg` is a different
    /// option, including `--cpu-prof-name`.
    private static func nodeBooleanUpdate(_ arg: String) -> (NodeBoolFlag, Bool)? {
        let word = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
        let negated = word.hasPrefix("--no-")
        let name: String
        if negated {
            let rest = word.dropFirst(5)
            guard !rest.isEmpty else { return nil }
            name = "--" + String(rest)
        } else {
            name = word
        }
        let flag: NodeBoolFlag?
        switch name {
        case "--cpu-prof": flag = .cpu
        case "--heap-prof": flag = .heap
        case "--tls-min-v1.3": flag = .tlsMin
        case "--tls-max-v1.2": flag = .tlsMax
        case "--use-openssl-ca": flag = .openssl
        case "--use-bundled-ca": flag = .bundled
        case "--permission", "--experimental-permission": flag = .permission
        case "--test": flag = .test
        case "--test-force-exit": flag = .testForceExit
        case "--experimental-test-coverage": flag = .coverage
        case "--interactive": flag = .interactive
        case "--watch": flag = .watch
        case "--build-snapshot": flag = .buildSnapshot
        default: flag = nil
        }
        guard let flag else { return nil }
        return (flag, !negated)
    }

    /// Bun 1.4.2 rejects these shorts. `bun -W ignore /tmp/codex` exits
    /// with `Invalid Argument '-W'` and does not run the file. `-X`,
    /// `-S`, `-L`, and `-o` do the same, including `-Wignore`. `-F` is
    /// `--filter` and is not here. Python still takes `-W` and `-X`.
    private static let bunRejectedShorts: Set<String> = [
        "-W", "-X", "-S", "-L", "-o",
    ]

    private static func bunRejectedShort(_ arg: String) -> Bool {
        if bunRejectedShorts.contains(arg) { return true }
        guard arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 2 else { return false }
        return bunRejectedShorts.contains(String(arg.prefix(2)))
    }

    /// Bun 1.4.2 does not take a separate word for these node flags.
    /// `bun --experimental-loader /tmp/codex.js /tmp/other.js` runs
    /// `codex.js`. `bun --inspect-port /tmp/codex` runs that file, and
    /// `bun --inspect-port 9229 /tmp/codex` tries to run `9229` and
    /// exits. `--experimental-loader=mod` and `--inspect-port=9229`
    /// keep the value in the flag word, so they are not this check.
    /// Node consumes both in `nodeOption`: a word that starts with `-`
    /// makes node exit, and any other word is the loader or the port.
    /// Python rejects them in `pythonRejectsSharedFlag`.
    private static func bunFlagNamesTheScript(_ arg: String) -> Bool {
        arg == "--experimental-loader" || arg == "--inspect-port"
    }

    /// How Bun's `--loader` / `-l` occupies argv. Nil when `arg` is not
    /// that flag, so node and deno still take `--loader` from the shared
    /// value set.
    private enum BunLoader {
        /// Words to advance, including the flag.
        case skip(Int)
        /// Bun rejects the invocation and does not run a script.
        case exits
    }

    /// Bun 1.4.2's loader value has to contain `:`.
    ///
    /// `bun --loader .js:jsx /tmp/codex`, `bun --loader=.md:text /tmp/codex`,
    /// `bun -l .js:jsx /tmp/codex`, `bun -l.js:jsx /tmp/codex`, and
    /// `bun -l=.js:jsx /tmp/codex` run that file. `bun --loader
    /// /tmp/codex.js /usr/local/bin/codex`, `bun --loader=script.js
    /// /tmp/codex`, `bun -l nocolon /tmp/codex`, and `bun -lnocolon
    /// /tmp/codex` exit before any script runs: the error is that the
    /// value is missing a `:`. `--watch` in the value slot is that same
    /// exit. A missing word and an empty `--loader=` exit too. A `:`
    /// whose loader name bun rejects (`.js:notaloader`, an empty name)
    /// also exits; the name list is not checked here. Node's `--loader`
    /// is a module specifier and is not this check.
    private static func bunLoader(_ arg: String, following: String?) -> BunLoader? {
        if arg == "--loader" || arg == "-l" {
            guard let following, following.contains(":") else { return .exits }
            return .skip(2)
        }
        guard let value = bunLoaderAttachedValue(arg) else { return nil }
        guard value.contains(":") else { return .exits }
        return .skip(1)
    }

    /// The value glued onto `--loader=` or `-l`, not including the flag.
    /// Nil for a separate word and for `--loader` itself.
    private static func bunLoaderAttachedValue(_ arg: String) -> Substring? {
        let longFlag = "--loader="
        if arg.hasPrefix(longFlag) {
            return arg.dropFirst(longFlag.count)
        }
        guard arg.hasPrefix("-l"), !arg.hasPrefix("--"), arg.count > 2 else { return nil }
        return arg.dropFirst(2)
    }

    /// Bun 1.4.2 keeps a config path glued to the flag (`-cPATH`,
    /// `-c=PATH`, `--config=PATH`). A separate word is the script:
    /// `bun -c /tmp/codex` and `bun run --config /tmp/codex` run that
    /// file. Python's `-c` is still eval, node's `-c` is still a syntax
    /// check, and Deno's `--config` and `-c` still take the next word.
    private static func bunConfigFlagWidth(_ arg: String) -> Int? {
        if arg == "--config" { return 1 }
        guard arg.hasPrefix("-c"), !arg.hasPrefix("--") else { return nil }
        return 1
    }

    /// Node and Python reject `--config` and exit. The words after it
    /// are not a program. Bun's space form is the script, and Deno's is
    /// the config file; neither runtime is this check.
    private static func configFlagExits(_ runtime: String) -> Bool {
        if runtime == "node" || runtime == "nodejs" { return true }
        return isPythonRuntime(runtime)
    }

    /// `python`, `python3`, `python3.11`, and `python.exe`. Not `python3.`
    /// and not a name that only starts with those letters.
    private static func isPythonRuntime(_ runtime: String) -> Bool {
        guard runtime.hasPrefix("python") else { return false }
        return genericRuntimeName(runtime)
    }

    /// How `--check-hash-based-pycs` occupies argv. Nil when `arg` is
    /// not that flag. Shorts, including `-W` and `-X`, are `pythonShort`.
    private enum PythonOption {
        /// Words to advance, including the flag.
        case skip(Int)
        /// Python rejects the invocation and does not run a script.
        case exits
    }

    /// Python 3.13's `--check-hash-based-pycs`. Short options, including
    /// `-S`, are `pythonShort`.
    ///
    /// The mode is exactly `always`, `default`, or `never`. Another
    /// word, a missing word, or `--check-hash-based-pycs=always` makes
    /// Python exit, and the path after it is not a program. The `=`
    /// form is also a long option `pythonRejectsSharedFlag` rejects.
    private static let pythonHashPycModes: Set<String> = [
        "always", "default", "never",
    ]

    private static func pythonOption(_ arg: String, following: String?) -> PythonOption? {
        if arg == "--check-hash-based-pycs" {
            if let following, pythonHashPycModes.contains(following) {
                return .skip(2)
            }
            return .exits
        }
        if arg.hasPrefix("--check-hash-based-pycs=") { return .exits }
        return nil
    }

    /// How one Python argv word that starts with a single `-` occupies
    /// the vector. Nil for a long option (`--…`), which is not a cluster.
    private enum PythonShort {
        /// Words to advance, including the flag.
        case skip(Int)
        /// Python does not run a file after this word.
        case exits
    }

    /// Booleans in Python 3.13.5's `SHORT_OPTS` (`Python/getopt.c`):
    /// `bBc:dEhiIJm:OPqRsStuvVW:xX:?`. `c`, `m`, `W`, and `X` take a
    /// value. `h`, `V`, and `?` exit. `-t` is accepted and ignored.
    /// `-R` turns the hash seed off. `-J` is rejected before that lookup.
    private static let pythonBooleanShorts: Set<Character> = [
        "b", "B", "d", "E", "i", "I", "O", "P", "q", "R", "s", "S", "t", "u", "v", "x",
    ]

    /// Python walks the cluster one letter at a time.
    ///
    /// `python3 -qS /tmp/codex`, `-bb`, `-OOO`, `-vu`, `-R`, and `-t`
    /// run that file. `python3 -qW ignore /tmp/codex` and
    /// `python3 -bWignore /tmp/codex` do too: `W` and `X` take the rest
    /// of the cluster, or the next word when nothing is glued on. `c`
    /// and `m` end the options, so the program is not a file.
    /// `python3 -z /tmp/codex`, `-qz`, `-qh`, `-J`, `-1`, and a lone `-`
    /// (the program is stdin) do not run the path. A missing word after
    /// `-W` or `-X` does not either. Node and bun are not this set.
    /// `node -q` is a bad option (`nodeBareShort`), and `python3 -q` is quiet.
    private static func pythonShort(_ arg: String, following: String?) -> PythonShort? {
        guard arg.hasPrefix("-"), !arg.hasPrefix("--") else { return nil }
        if arg == "-" { return .exits }
        let body = arg.dropFirst()
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            let next = body.index(after: index)
            if character == "c" || character == "m" {
                return .exits
            }
            if character == "W" || character == "X" {
                if next == body.endIndex {
                    guard following != nil else { return .exits }
                    return .skip(2)
                }
                return .skip(1)
            }
            if character == "h" || character == "V" || character == "?" {
                return .exits
            }
            if pythonBooleanShorts.contains(character) {
                index = next
                continue
            }
            return .exits
        }
        return .skip(1)
    }

    /// Python 3.13 exits before the file after a foreign long option runs.
    ///
    /// The only long option that reaches a script is exactly
    /// `--check-hash-based-pycs`. `python3 --require preload.js
    /// /tmp/codex`, `python3 --cwd=/tmp /tmp/codex`, `python3 --help
    /// /tmp/codex`, and `python3 --not-a-flag /tmp/codex` all exit, and
    /// so does `--check-hash-based-pycs=always`. Shorts are `pythonShort`.
    /// `--config` exits in `configFlagExits` before this check. Bun still
    /// runs the script after `--require` and `--cwd`. Node consumes
    /// `--require`, `--loader`, `--import`, and `--env-file`. Deno still
    /// consumes those long flags. A script written before the flag is
    /// already returned. `--` is handled before this check, so the word
    /// after it stays the script.
    private static func pythonRejectsSharedFlag(_ arg: String) -> Bool {
        guard arg.hasPrefix("--") else { return false }
        return arg != "--check-hash-based-pycs"
    }

    /// Deno flags whose next word is the script. `-r` is `--reload`.
    /// `-W` and `-S` are permissions. `--env-file` reads `.env` unless
    /// the path is `--env-file=<path>`. Node's `-r` and `--env-file`,
    /// and Python's `-W`, are not in this set.
    private static let denoBooleanFlags: Set<String> = [
        "-r", "-W", "-S", "--env-file",
    ]

    /// Deno options whose next word is a value, not the script.
    ///
    /// Checked against Deno 2.9.7. Each one consumes the following word,
    /// so `deno run --import-map codex server.js` was rank 4 and, as the
    /// group leader, was the pid `ps` read. `--config` is already
    /// `runtimeValueFlags`. `--lock` consumes the next word only when
    /// that word is not a flag. `--port` and `--host` are `deno serve`;
    /// `deno run` rejects them, and the value is still not the script.
    /// `--inspect` does not take the next word. `--allow-read` and
    /// `--node-modules-dir` do not either, except as `--flag=value`.
    private static let denoRequiredValueFlags: Set<String> = [
        "--import-map",
        "--cert",
        "--location",
        "--seed",
        "--ext",
        "--conditions",
        "--min-dep-age",
        "--node-modules-linker",
        "--inspect-publish-uid",
        "--log-level",
        "--port",
        "--host",
    ]

    /// Words this Deno flag occupies, including itself. Nil when `arg`
    /// is not one of them. An exact `-c` takes the config file. `-cPATH`
    /// and `-c=PATH` keep that file in the flag word.
    private static func denoFlagWidth(_ arg: String, following: String?) -> Int? {
        if arg == "-c" { return 2 }
        if arg.hasPrefix("-c"), !arg.hasPrefix("--") { return 1 }
        if arg == "--lock" {
            if let following, !following.hasPrefix("-") { return 2 }
            return 1
        }
        guard denoRequiredValueFlags.contains(arg) else { return nil }
        return 2
    }

    /// A port, `host:port`, `host:port/prefix`, or `[::1]:port`. A Windows
    /// drive (`C:\…`) is a path. A script path is not an address.
    private static func looksLikeInspectAddress(_ value: String) -> Bool {
        if value.isEmpty || value.hasPrefix("-") { return false }
        if value.allSatisfy({ isASCIIDigit($0) }) { return true }
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let afterBracket = value.index(after: close)
            guard afterBracket < value.endIndex, value[afterBracket] == ":" else { return false }
            return inspectPort(value[value.index(after: afterBracket)...])
        }
        guard let colon = value.firstIndex(of: ":") else { return false }
        let host = value[..<colon]
        let rest = value[value.index(after: colon)...]
        if host.count == 1, let first = host.first, isASCIILetter(first),
           (rest.first == "\\" || rest.first == "/") {
            return false
        }
        return inspectPort(rest)
    }

    private static func inspectPort(_ rest: Substring) -> Bool {
        let port = rest.prefix { isASCIIDigit($0) }
        guard !port.isEmpty else { return false }
        let after = rest[port.endIndex...]
        return after.isEmpty || after.first == "/"
    }

    /// How one Node or Bun argv word that starts with a single `-`
    /// occupies the vector, once the exact flags above have been claimed.
    /// Nil for a long option and for Deno, which still skips the word.
    private enum RuntimeShort {
        /// Words to advance, including the flag.
        case skip(Int)
        /// The runtime does not run a file after this word.
        case exits
    }

    /// Node 22.23 and Bun 1.4.2 do not share Python's short set.
    ///
    /// Node does not cluster. Exactly `-i` still runs the file.
    /// `-h`, `-v`, a lone `-` (stdin), and every other short, including
    /// `-z`, `-q`, `-qh`, and `-ii`, exit before the file runs.
    /// Bun walks the cluster. `b` and `i` are booleans (`-bi`, `-ii`).
    /// `h` and `v` exit. `c` keeps an optional config path in the rest
    /// of the word and the next word is the script. `u`, `r`, and `F`
    /// take the rest of the cluster or the next word. `d` and `l` do
    /// too, and still require their separator. `e` and `p` are eval.
    /// Any other letter exits, and so does `-b=1`. A lone `-` is stdin.
    /// `--help` and `--version` are `runtimePrintsAndExits`.
    /// A Node long option is `nodeLongOption`. `--not-a-flag` is not
    /// this check: Bun still runs the file.
    private static func runtimeShort(
        _ arg: String,
        runtime: String,
        following: String?
    ) -> RuntimeShort? {
        guard arg.hasPrefix("-"), !arg.hasPrefix("--") else { return nil }
        if isNodeRuntime(runtime) {
            return nodeBareShort(arg)
        }
        if runtime == "bun" {
            return bunBareShort(arg, following: following)
        }
        return nil
    }

    /// Node 22.23 and Bun 1.4.2 print and exit before the file runs.
    ///
    /// `--help` and `--version` do that on Node, including `--help=1`
    /// and an empty `--version=`, wherever the flag sits before the
    /// script. `node --use-strict --version /tmp/codex` does not run
    /// the file. Bun prints `--help`, `--version`, and `--revision`
    /// only when the invocation is not `run` or `x`. The subcommand
    /// counts when the flag comes first: `bun --version run /tmp/codex`
    /// and `bun --version=1 run /tmp/codex` still run the file, and so
    /// do `bun run --version` and `bun run --revision`. `bun --help run`
    /// and `bun run --help` do not. `bun --help x` and `bun x --version`
    /// still run the package. `--title run` is not that subcommand:
    /// `run` is the title. A version word that is the value of
    /// `--title` or `--user-agent` was consumed before this check.
    /// `--interactive`, `--watch`, `--hot`, `--bun`, and
    /// `bun --not-a-flag` are not this exit. `node --not-a-flag` exits
    /// in `nodeLongOption` before this check. Deno was not installed, so
    /// its long flags are not this check. A script written before the
    /// flag is already returned. `--` is handled before this check, so
    /// the word after it stays the script.
    private static func runtimePrintsAndExits(
        _ arg: String,
        runtime: String,
        argv: [String]
    ) -> Bool {
        let help = arg == "--help" || arg.hasPrefix("--help=")
        if isNodeRuntime(runtime) {
            return help || arg == "--version" || arg.hasPrefix("--version=")
        }
        guard runtime == "bun" else { return false }
        let command = bunLeadingCommand(argv)
        if command == "x" { return false }
        if help { return true }
        if command == "run" { return false }
        if arg == "--version" || arg.hasPrefix("--version=") { return true }
        return arg == "--revision" || arg.hasPrefix("--revision=")
    }

    /// `run` or `x` before the script. Flags may come first:
    /// `bun --version run file` is `run`. The value of `--title`,
    /// `-r`, or another flag is not the subcommand, so `--title run`
    /// is a script whose title is `run`. Nil when a flag exits before
    /// any positional, or the first positional is the script.
    private static func bunLeadingCommand(_ argv: [String]) -> String? {
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            let following = index + 1 < argv.count ? argv[index + 1] : nil
            if arg == "--" { return nil }
            if arg.hasPrefix("-") {
                guard let width = bunCommandSkip(arg, following: following, argv: argv) else {
                    return nil
                }
                index += width
                continue
            }
            if arg == "run" || arg == "x" { return arg }
            return nil
        }
        return nil
    }

    /// Words this bun flag occupies while looking for `run` or `x`.
    /// Nil when the flag exits and no script runs, which is the same
    /// answer as there being no subcommand. A long option is one word
    /// unless a value flag already claimed it. `bunBareShort` is only
    /// for a single dash: `--version` is not a cluster.
    private static func bunCommandSkip(
        _ arg: String,
        following: String?,
        argv: [String]
    ) -> Int? {
        if bunConfigFlagWidth(arg) != nil || bunFlagNamesTheScript(arg) { return 1 }
        if let loader = bunLoader(arg, following: following) {
            if case .skip(let width) = loader { return width }
            return nil
        }
        if let inspect = bunInspect(arg, following: following) {
            if case .skip(let width) = inspect { return width }
            return nil
        }
        if bunRejectedShort(arg) || runtimeAbandonsScript(arg) { return nil }
        if bunSeparateValueIsTheWordBun(arg, following: following) { return nil }
        if bunValueExits(arg, following: following, argv: argv) { return nil }
        if runtimeValueFlags.contains(arg) { return 2 }
        if runtimeFlagAttachesValue(arg) { return 1 }
        if let width = valueFlagWidth(arg, runtime: "bun") { return width }
        if !arg.hasPrefix("--"), let short = bunBareShort(arg, following: following) {
            if case .skip(let width) = short { return width }
            return nil
        }
        return 1
    }

    /// Exactly `-i`, or a V8 flag spelled with one dash.
    ///
    /// Node 22.23 rejects every other single-dash word that the earlier
    /// checks did not already consume. `-harmony` and `-use-strict` run
    /// the file. `-max-old-space-size=4096` keeps the value in the word
    /// and the next word is the script. `-watch`, `-not-a-flag`, and
    /// `-harmony=true` do not run the file: a node boolean is not a V8
    /// flag, and a V8 boolean rejects `=`.
    private static func nodeBareShort(_ arg: String) -> RuntimeShort {
        if arg == "-i" { return .skip(1) }
        guard arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 1 else { return .exits }
        let body = arg.dropFirst()
        if let equals = body.firstIndex(of: "=") {
            let name = "--" + body[..<equals]
            let value = body[body.index(after: equals)...]
            guard NodeRuntimeFlags.v8Values.contains(name) else { return .exits }
            if value.isEmpty, NodeRuntimeFlags.v8EmptyEqualsExits.contains(name) {
                return .exits
            }
            return .skip(1)
        }
        let name = "--" + body
        if NodeRuntimeFlags.v8Booleans.contains(name) { return .skip(1) }
        return .exits
    }

    /// `bun -b` / `--bun` and `bun -i` (auto-install). Repeats are the
    /// same boolean. A letter that is not here is a value or an exit.
    private static let bunBooleanShorts: Set<Character> = ["b", "i"]

    /// Bun 1.4.2's short cluster, checked on that binary.
    ///
    /// `-i`, `-b`, `-bi`, `-ii`, `-ic`, and `-bc` run the file.
    /// `-uz`, `-u foo`, `-uh`, and `-u=` do too: `u` takes a value, and
    /// an empty `-u` with no further word prints help. `-h`, `-v`,
    /// `-hu`, `-z`, `-q`, `-bz`, `-iz`, `-m`, `-b=1`, and a lone `-`
    /// do not run the file. `-ir preload.js script.js` runs the script,
    /// and `-id K:1` / `-il .js:jsx` do too. `-id K` and `-il nocolon`
    /// exit. `-ie code` evals the code. `-iF pkg script.js` is the same
    /// filter as `-F`: the package may be missing on this machine, and
    /// the script is still the word after the value.
    private static func bunBareShort(_ arg: String, following: String?) -> RuntimeShort {
        if arg == "-" { return .exits }
        let body = arg.dropFirst()
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            let next = body.index(after: index)
            let rest = body[next...]
            if bunBooleanShorts.contains(character) {
                index = next
                continue
            }
            if character == "h" || character == "v" || character == "e" || character == "p" {
                return .exits
            }
            if character == "c" {
                return .skip(1)
            }
            if character == "u" || character == "r" || character == "F" {
                if rest.isEmpty {
                    guard following != nil else { return .exits }
                    return .skip(2)
                }
                return .skip(1)
            }
            if character == "d" || character == "l" {
                if rest.isEmpty {
                    guard let following else { return .exits }
                    if !bunClusterValueAccepted(character, value: following) { return .exits }
                    return .skip(2)
                }
                var glued = rest
                if glued.first == "=" {
                    glued = glued.dropFirst()
                }
                if !bunClusterValueAccepted(character, value: String(glued)) { return .exits }
                return .skip(1)
            }
            return .exits
        }
        return .skip(1)
    }

    /// `d` needs `:` or `=` in the value. `l` needs `:`. An empty value,
    /// including the value left by `-id=` and `-il=`, is not accepted.
    private static func bunClusterValueAccepted(_ flag: Character, value: String) -> Bool {
        if value.isEmpty { return false }
        if flag == "l" { return value.contains(":") }
        return value.contains(":") || value.contains("=")
    }

    /// `--require=mod` and `-rpreload` keep the value in the same word.
    private static func runtimeFlagAttachesValue(_ arg: String) -> Bool {
        for flag in runtimeValueFlags where flag.hasPrefix("--") {
            if arg.hasPrefix(flag + "=") { return true }
        }
        guard arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 2 else { return false }
        return runtimeValueFlags.contains(String(arg.prefix(2)))
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        return value >= 48 && value <= 57
    }
}
