import Foundation

// MARK: - ConfirmedPaneFollow

/// Where a write goes after the user has already approved it.
///
/// MCP confirm-tier tools (`agent.say`, `agent.interrupt`, `agent.stop`,
/// and a split `session.spawn`) hold a pane id across a wait that can last
/// two minutes. A cross-workspace move assigns a new public id and does not
/// keep the old one. The occupant fingerprint includes that id, so the
/// re-read called the agent gone and the approved write never ran — or, if
/// the check had been skipped, it would have addressed the pane the agent
/// left.
///
/// The session value is the occupant. When the approved pane id is no
/// longer an agent, and exactly one listed pane has that same session, the
/// write goes there. Status and `state_change_seq` still have to match the
/// approval: a new prompt, a restart, or a status change refuses. An empty
/// session value is not an identity. Two panes sharing one value match
/// nothing. A fingerprint with no session (kind and title) does not follow;
/// those are shared by agents that are not the same occupant.
///
/// A pane id that is still listed is never redirected. Whoever is there
/// now is compared to the approval, and a different occupant refuses even
/// when the old session is also sitting on another pane.
public enum ConfirmedPaneFollow: Sendable {

    public enum Refusal: Equatable, Sendable {
        case paneGone
        case occupantChanged(expected: String, current: String)
        /// Still the same pane, or the one session successor, but not the
        /// status episode that was approved. `current` may be lower: a
        /// herdr restart starts the counter over.
        case seqAdvanced(expected: UInt64, current: UInt64)
        case statusChanged(expected: String, current: String)
    }

    /// The pane the approved write should address.
    ///
    /// `occupantFingerprint`, `expectedStatus`, and `expectedSeq` are the
    /// values stored on the pending action. An empty fingerprint or status
    /// skips that comparison, which is how a spawn with no target pane
    /// records the fields. A missing seq skips the seq comparison.
    public static func resolve(
        previousPaneId: String,
        occupantFingerprint: String?,
        expectedStatus: String?,
        expectedSeq: UInt64?,
        in agents: [HerdrAgentInfo]
    ) -> Result<HerdrAgentInfo, Refusal> {
        guard !previousPaneId.isEmpty else { return .failure(.paneGone) }

        if let current = agents.first(where: {
            $0.paneId == previousPaneId && Self.isAgent($0)
        }) {
            return episode(
                of: current,
                occupantFingerprint: occupantFingerprint,
                expectedStatus: expectedStatus,
                expectedSeq: expectedSeq,
                occupantMustMatchExactly: true
            )
        }

        guard let fingerprint = occupantFingerprint, !fingerprint.isEmpty,
              let identity = sessionIdentity(in: fingerprint, previousPaneId: previousPaneId),
              let successor = uniqueSuccessor(sessionIdentity: identity, excluding: previousPaneId, in: agents)
        else {
            return .failure(.paneGone)
        }
        return episode(
            of: successor,
            occupantFingerprint: fingerprint,
            expectedStatus: expectedStatus,
            expectedSeq: expectedSeq,
            occupantMustMatchExactly: false
        )
    }

    /// The one other agent whose session identity is `sessionIdentity`.
    /// Zero matches and two matches both return nil: the caller must not
    /// pick an arbitrary pane.
    static func uniqueSuccessor(
        sessionIdentity: String,
        excluding paneId: String,
        in agents: [HerdrAgentInfo]
    ) -> HerdrAgentInfo? {
        guard !sessionIdentity.isEmpty else { return nil }
        let matches = agents.filter { info in
            !info.paneId.isEmpty
                && info.paneId != paneId
                && info.sessionIdentity == sessionIdentity
                && isAgent(info)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    /// `source|agent|kind|value` from a session fingerprint that ends with
    /// `previousPaneId`. Nil for a fallback fingerprint, an empty session
    /// value, or a string that does not end in that pane id.
    private static func sessionIdentity(in fingerprint: String, previousPaneId: String) -> String? {
        let prefix = "session|"
        let suffix = "|\(previousPaneId)"
        guard fingerprint.hasPrefix(prefix), fingerprint.hasSuffix(suffix) else { return nil }
        guard fingerprint.count > prefix.count + suffix.count else { return nil }
        let identity = String(fingerprint.dropFirst(prefix.count).dropLast(suffix.count))
        // An empty session value leaves a trailing separator. That value is
        // what several panes look like, so it is not an identity.
        guard !identity.isEmpty, !identity.hasSuffix("|") else { return nil }
        return identity
    }

    private static func episode(
        of current: HerdrAgentInfo,
        occupantFingerprint: String?,
        expectedStatus: String?,
        expectedSeq: UInt64?,
        occupantMustMatchExactly: Bool
    ) -> Result<HerdrAgentInfo, Refusal> {
        if occupantMustMatchExactly,
           let expected = occupantFingerprint, !expected.isEmpty,
           expected != current.occupantFingerprint {
            return .failure(.occupantChanged(expected: expected, current: current.occupantFingerprint))
        }
        if let expectedSeq, expectedSeq != current.stateChangeSeq {
            return .failure(.seqAdvanced(expected: expectedSeq, current: current.stateChangeSeq))
        }
        if let expectedStatus, !expectedStatus.isEmpty, expectedStatus != current.agentStatus {
            return .failure(.statusChanged(expected: expectedStatus, current: current.agentStatus))
        }
        return .success(current)
    }

    private static func isAgent(_ info: HerdrAgentInfo) -> Bool {
        guard let agent = info.agent, !agent.isEmpty else { return false }
        return true
    }
}
