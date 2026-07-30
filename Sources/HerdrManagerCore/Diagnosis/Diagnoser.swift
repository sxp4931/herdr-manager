import Foundation

// MARK: - Diagnoser

/// The S1-S4 classifier. Precedence: S3 → S1 → S2 → S4.
///
/// - S3: Process gone — pane.process_info shows a bare shell while the agent
///       is supposed to be alive (working/blocked/unknown).
/// - S1: Awaiting input — status==blocked + agent.explain → matched_rule.id → BlockKind
/// - S2: Silent — status==working ∧ now−lastOutputAt > threshold, enriched with CPU via `ps`
/// - S4: Unclassifiable — unknown status or screen_detection_skipped → degraded classification
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

        // S3: Process gone — check first, highest priority
        if let s3 = await checkProcessGone(agent: agent, paneId: paneId, adapter: adapter) {
            return s3
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

        // S4: Unclassifiable
        return await checkUnclassifiable(agent: agent, paneId: paneId, adapter: adapter)
    }

    // MARK: - S3: Process Gone

    /// Check if the agent's process is gone. Returns .processGone if so, nil otherwise.
    ///
    /// A *finished* (`done`) or `idle` agent has legitimately returned to the
    /// shell — that is the expected end state, NOT a crash, so we never flag it.
    /// We only consider agents that are supposed to be alive (working/blocked/
    /// unknown), and even then we corroborate: the foreground must be a bare
    /// shell. If a non-shell process (e.g. `node`/`bun` hosting the agent) is
    /// in the foreground, the read is inconclusive and we stay silent rather
    /// than raise a false "process gone".
    private func checkProcessGone(agent: Agent, paneId: String, adapter: HerdrAdapter) async -> Verdict? {
        guard agent.status == .working || agent.status == .blocked || agent.status == .unknown else {
            return nil
        }

        do {
            let procInfo = try await adapter.processInfo(paneId: paneId)
            let procs = procInfo.foregroundProcesses

            // Empty foreground = we couldn't read it; inconclusive, don't alarm.
            guard !procs.isEmpty else { return nil }

            // Corroborate: only a bare shell in the foreground means the agent's
            // process group vanished. Anything else (a runtime hosting it) means
            // we genuinely can't tell, so we do not declare it gone.
            let foregroundIsBareShell = procs.allSatisfy { Self.isShellProcessName($0.name) }
            guard foregroundIsBareShell else { return nil }

            let lastLine = procs.last.map { "\($0.name) (pid \($0.pid))" }
            return .processGone(lastLine: lastLine)
        } catch {
            // If we can't get process info, we can't determine S3 — fall through
            return nil
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
        let lastOutput = agent.lastOutputAt ?? agent.enteredAt
        let elapsed = Date().timeIntervalSince(lastOutput)

        guard elapsed > threshold else { return nil }

        // Enrich with CPU state
        let cpu = await cpuState(for: agent, paneId: paneId, adapter: adapter)

        return .silent(since: lastOutput, cpu: cpu)
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
        case .working:
            return .unclassifiable(reason: "working but unclassifiable")
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

    /// True when a foreground process name looks like a login/interactive shell.
    /// Used to corroborate S3: a "gone" agent leaves a bare shell in the pane,
    /// whereas a healthy agent leaves its runtime (node/bun/…) in the foreground.
    private static func isShellProcessName(_ name: String) -> Bool {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        let n = base.hasPrefix("-") ? String(base.dropFirst()) : base
        return ["zsh", "bash", "sh", "fish", "tcsh", "ksh", "dash", "login"]
            .contains(n.lowercased())
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
