import Foundation

// MARK: - PromptAnswerCheck

/// The panel's Approve and Deny send a bare Enter or Esc to the pane, based
/// on a row that can be seconds old: the prompt may have been answered in
/// the terminal, replaced by a different prompt, or the pane reused, before
/// the store caught up. Enter would then accept a prompt the user never
/// saw, and Esc would interrupt a working agent.
///
/// The app re-reads `agent.list` right before the send, and this check asks
/// whether the prompt the row showed is still the one waiting. It is the
/// panel's counterpart to the seq check MCP `agent.answer` makes.
public enum PromptAnswerCheck: Sendable {

    public enum Refusal: Equatable, Sendable {
        /// The pane is gone or no longer runs an agent.
        case agentGone
        /// A different agent now runs in the pane.
        case agentReplaced
        /// The agent is no longer waiting on a prompt.
        case notBlocked(now: AgentStatus)
        /// Still waiting, but on a later status episode than the row showed:
        /// possibly a different prompt.
        case promptChanged

        public var message: String {
            switch self {
            case .agentGone:
                return "the agent is no longer in that pane"
            case .agentReplaced:
                return "a different agent now runs in that pane"
            case .notBlocked(let now):
                return "the agent is no longer waiting (now \(now.rawValue))"
            case .promptChanged:
                return "the prompt may have changed since the panel showed it; check it and try again"
            }
        }
    }

    /// Nil when `shown` is still blocked on the same status episode in
    /// `snapshot`.
    ///
    /// Seq is compared exactly, so a herdr restart (seq starts over) also
    /// refuses. herdr's status events carry no seq, so until the next
    /// `agent.list` poll a newly blocked row still holds the seq of the
    /// episode before it, and that refuses too. The caller applies
    /// `snapshot`, so the next click goes through. A refused click is the
    /// safe side.
    public static func refusal(answering shown: Agent, in snapshot: HerdSnapshot) -> Refusal? {
        guard let current = snapshot.displayAgents().first(where: { $0.id == shown.id }) else {
            return .agentGone
        }
        guard current.kind == shown.kind else {
            return .agentReplaced
        }
        guard current.status == .blocked else {
            return .notBlocked(now: current.status)
        }
        guard current.stateChangeSeq == shown.stateChangeSeq else {
            return .promptChanged
        }
        return nil
    }
}
