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
}
