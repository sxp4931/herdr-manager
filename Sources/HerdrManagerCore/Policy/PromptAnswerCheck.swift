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
/// panel's counterpart to the seq check MCP `agent.answer` makes. When the
/// click captured a session, the pane still has to be that session: the
/// same kind blocked on the same seq can be a different occupant.
///
/// The re-read can already show a cross-workspace move: the row's pane id
/// is gone and the same session is blocked on the new id. `sessionIdentity`
/// is the value the store had for the row before that read. When exactly
/// one pane carries it, the keys go there. Without an identity, a missing
/// pane still refuses — kind and title are not an occupant.
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
    ///
    /// `sessionIdentity` follows a move. See `destination`. Omit it and a
    /// pane that left the list refuses, which is what callers that have
    /// not captured an identity do.
    public static func refusal(
        answering shown: Agent,
        in snapshot: HerdSnapshot,
        sessionIdentity: String? = nil
    ) -> Refusal? {
        if case .failure(let refusal) = destination(
            answering: shown,
            in: snapshot,
            sessionIdentity: sessionIdentity
        ) {
            return refusal
        }
        return nil
    }

    /// The pane id the keys should be sent to, or why they should not.
    ///
    /// The row's own id wins when that pane still runs the occupant the
    /// click captured. Kind, status, and seq are not that occupant: a
    /// herdr restart, or a new session in the same pane, can be the same
    /// kind, still blocked, on the same seq. When `sessionIdentity` was
    /// captured, a different session refuses, and so does a re-read that
    /// no longer names one. The keys do not follow the old session onto
    /// another pane while this pane still runs an agent. Callers that
    /// captured no identity keep the kind comparison — there is no
    /// session to require.
    ///
    /// A move drops the pane. The captured session then has to name
    /// exactly one other agent, and that agent still has to be the blocked
    /// episode the row showed. A different kind, a status that left
    /// blocked, or a different seq refuses. The returned id is the one to
    /// address: sending to `shown.id` would hit the pane the agent left.
    public static func destination(
        answering shown: Agent,
        in snapshot: HerdSnapshot,
        sessionIdentity: String? = nil
    ) -> Result<String, Refusal> {
        let currentInfo: HerdrAgentInfo?
        if let same = snapshot.agents.first(where: { $0.paneId == shown.id.raw && Self.isListedAgent($0) }) {
            if let sessionIdentity, !sessionIdentity.isEmpty {
                // Missing and different are the same refusal. A list that
                // drops `agent_session` is not proof this is still the
                // occupant, and a longer value (`abc|extra`) is not `abc`.
                guard let currentSession = same.sessionIdentity,
                      currentSession == sessionIdentity else {
                    return .failure(.agentReplaced)
                }
            }
            currentInfo = same
        } else if let sessionIdentity, !sessionIdentity.isEmpty,
                  let followed = ConfirmedPaneFollow.uniqueSuccessor(
                    sessionIdentity: sessionIdentity,
                    excluding: shown.id.raw,
                    in: snapshot.agents
                  ) {
            currentInfo = followed
        } else {
            currentInfo = nil
        }
        guard let currentInfo, let current = snapshot.displayAgent(for: currentInfo) else {
            return .failure(.agentGone)
        }
        guard current.kind == shown.kind else {
            return .failure(.agentReplaced)
        }
        guard current.status == .blocked else {
            return .failure(.notBlocked(now: current.status))
        }
        guard current.stateChangeSeq == shown.stateChangeSeq else {
            return .failure(.promptChanged)
        }
        return .success(current.id.raw)
    }

    private static func isListedAgent(_ info: HerdrAgentInfo) -> Bool {
        guard let agent = info.agent, !agent.isEmpty else { return false }
        return true
    }
}

// MARK: - AnswerSendCheck

/// MCP `agent.answer` proves the prompt, then awaits `agent.explain` and a
/// fresh protocol reading before `sendKeys`. The pane can be answered,
/// replaced, or restarted in that gap. This is the re-read immediately
/// before the keys: same pane, still blocked, same `state_change_seq`,
/// same occupant as the read that authorized the answer.
///
/// A move to a new pane id refuses, including when the same session is
/// still blocked there. `explain` was addressed to the pane this read
/// authorized. After the move that id can be a shell, and the block kind
/// that justified the keys is not a reading of the new pane. The
/// consecutive-answer cap follows the session (`PolicyEngine`), so a
/// later answer addressed to the new id still counts against it.
/// Confirm-tier writes follow the session. They do not explain a screen.
public enum AnswerSendCheck: Sendable {

    public enum Refusal: Equatable, Sendable {
        case agentGone
        case notBlocked(now: String)
        /// Still blocked, but on a different status episode than the one
        /// the answer was checked against. `currentSeq` may be lower: a
        /// herdr restart starts the counter over.
        case promptChanged(currentSeq: UInt64)
        case occupantChanged
    }

    /// Nil when `snapshot` still shows `observed`'s pane blocked on the
    /// same status episode and occupant.
    public static func refusal(
        sendingTo observed: HerdrAgentInfo,
        in snapshot: HerdSnapshot
    ) -> Refusal? {
        guard let current = snapshot.agents.first(where: { $0.paneId == observed.paneId }) else {
            return .agentGone
        }
        guard current.agentStatus == "blocked" else {
            return .notBlocked(now: current.agentStatus)
        }
        guard current.stateChangeSeq == observed.stateChangeSeq else {
            return .promptChanged(currentSeq: current.stateChangeSeq)
        }
        guard current.occupantFingerprint == observed.occupantFingerprint else {
            return .occupantChanged
        }
        return nil
    }
}
