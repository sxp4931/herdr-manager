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
            if agent.verdict.isProcessGone {
                counts.gone += 1
            } else if isActionablyBlocked(agent) {
                counts.blocked += 1
            } else if isActionablySilent(agent) {
                counts.silent += 1
            } else if agent.status == .done {
                counts.done += 1
            } else if agent.status == .working {
                counts.working += 1
            }
        }
        return counts
    }
}
