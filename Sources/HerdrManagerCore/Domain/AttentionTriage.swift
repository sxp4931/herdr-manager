import Foundation

/// Shared worst-state-wins ranking for the menu bar, panel, CLI, and MCP.
///
/// `needsYou` is the actionable set (blocked, process-gone, silent).
/// `attentionWorthy` also includes finished-unseen (`done`) so a glance
/// list can show work that completed while the owner was away.
public enum AttentionTriage: Sendable {
    /// Actionable now. Finished (`done`) and idle are not included: they
    /// do not ask for input. Process-gone outranks a stale silent verdict;
    /// blocked outranks silent so a permission prompt is never shown as
    /// "quiet" after `diagnoseAll` races a status change.
    public static func needsYou(_ agent: Agent) -> Bool {
        if agent.verdict.isProcessGone { return true }
        if agent.status == .blocked { return true }
        if agent.status == .done || agent.status == .idle { return false }
        return agent.verdict.isSilent
    }

    /// Silent for attention counts. A stale `.silent` verdict on a blocked,
    /// gone, done, or idle pane is not silence — those states already won.
    public static func isActionablySilent(_ agent: Agent) -> Bool {
        needsYou(agent) && agent.status != .blocked && !agent.verdict.isProcessGone
    }

    /// Blocked for attention counts. Process-gone on a blocked pane is gone,
    /// not a live permission prompt.
    public static func isActionablyBlocked(_ agent: Agent) -> Bool {
        agent.status == .blocked && !agent.verdict.isProcessGone
    }

    /// The panel's Running scope and its header count.
    ///
    /// herdr leaves `working` in place after the process dies, so a status
    /// check alone puts that pane in the running list and counts it again
    /// beside "needs you". A quiet worker is still running: silence is a
    /// clock on a live process, not an exit.
    public static func isRunning(_ agent: Agent) -> Bool {
        agent.status == .working && !agent.verdict.isProcessGone
    }

    /// Finished, and still that episode. A crash outranks `done`, so the
    /// header does not count one pane as done and as needing you.
    public static func isFinished(_ agent: Agent) -> Bool {
        kind(for: agent) == .done
    }

    /// Glance list: needs-you plus finished-unseen.
    public static func attentionWorthy(_ agent: Agent) -> Bool {
        needsYou(agent) || agent.status == .done
    }

    /// Worst-first: gone/blocked = 0, actionable silent = 1, done = 2, else 3.
    /// Stale `.silent` on done/idle must not outrank a finished agent.
    public static func priority(_ agent: Agent) -> Int {
        if agent.verdict.isProcessGone || agent.status == .blocked { return 0 }
        if isActionablySilent(agent) { return 1 }
        if agent.status == .done { return 2 }
        return 3
    }

    /// Worst-first ordering shared by every attention list: priority, then
    /// longest-waiting, then pane id. The id tie-break keeps equal rows from
    /// swapping between redraws — the store's herd is a Dictionary (no
    /// stable order) and `displayAgents` stamps one `now` on every agent.
    public static func ranksBefore(_ a: Agent, _ b: Agent) -> Bool {
        let pa = priority(a)
        let pb = priority(b)
        if pa != pb { return pa < pb }
        if a.enteredAt != b.enteredAt { return a.enteredAt < b.enteredAt }
        return a.id.raw < b.id.raw
    }

    /// Exclusive bucket for one agent. Process-gone wins over herdr's raw
    /// status, then a live block, then silence. Idle and unknown are the
    /// leftovers `counts` does not tally; a stale silent verdict on done or
    /// idle stays in that status's bucket.
    public enum Kind: String, Sendable, Equatable {
        case gone
        case blocked
        case silent
        case done
        case working
        case idle
        case unknown
    }

    public static func kind(for agent: Agent) -> Kind {
        if agent.verdict.isProcessGone { return .gone }
        if isActionablyBlocked(agent) { return .blocked }
        if isActionablySilent(agent) { return .silent }
        switch agent.status {
        case .done: return .done
        case .working: return .working
        case .idle: return .idle
        case .blocked: return .blocked
        case .unknown: return .unknown
        }
    }

    /// Text-table mark. Gone and blocked share a colour on the menu bar,
    /// which says which with a word. A text cell has only this mark, so a
    /// crashed pane is the word and a permission prompt stays the circle.
    /// `working` overrides the working mark where a surface already paints
    /// working differently from idle.
    public static func statusMark(for kind: Kind, working: String = "🟢") -> String {
        switch kind {
        case .gone: return "GONE"
        case .blocked: return "🔴"
        case .silent: return "🟠"
        case .done: return "🔵"
        case .working: return working
        case .idle: return "🟢"
        case .unknown: return "⚪"
        }
    }

    public static func statusMark(for agent: Agent, working: String = "🟢") -> String {
        statusMark(for: kind(for: agent), working: working)
    }

    /// Human footer for a herd table. The counts are the exclusive buckets,
    /// so a crashed pane is `gone` and not also `blocked`.
    public static func statusFooter(agentCount: Int, counts: Counts) -> String {
        "\(agentCount) agents | \(counts.blocked) blocked | \(counts.gone) gone | \(counts.silent) silent | \(counts.done) done"
    }

    /// Exclusive badge/footer counts. A stale silent verdict on done or idle
    /// is not silence; process-gone on a blocked pane is gone, not blocked.
    public struct Counts: Equatable, Sendable {
        public var blocked = 0
        public var gone = 0
        public var silent = 0
        public var done = 0
        public var working = 0

        public var total: Int { blocked + gone + silent + done }
        public var urgent: Int { blocked + gone }
    }

    public static func counts<S: Sequence>(_ agents: S) -> Counts where S.Element == Agent {
        var counts = Counts()
        for agent in agents {
            switch kind(for: agent) {
            case .gone: counts.gone += 1
            case .blocked: counts.blocked += 1
            case .silent: counts.silent += 1
            case .done: counts.done += 1
            case .working: counts.working += 1
            case .idle, .unknown: break
            }
        }
        return counts
    }
}
