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

    /// JSON fragment for a tool result that followed a move.
    ///
    /// Empty when `resolved` is nil or empty. Callers pass nil when the
    /// write stayed on the pane that was named. The approval wait is long
    /// enough for a cross-workspace move, and the result is what the
    /// caller reads next. Omitting the new id sends the follow-up at the
    /// pane the agent left. A quote, backslash, or control character in
    /// the id is escaped: the results are built by hand, and one of those
    /// characters would end the object.
    public static func resolvedAgentField(_ resolved: String?) -> String {
        guard let resolved, !resolved.isEmpty else { return "" }
        return ",\"resolvedAgentId\":\"\(jsonEscaped(resolved))\""
    }

    /// A value placed between JSON string quotes.
    static func jsonEscaped(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x5C:
                out += "\\\\"
            case 0x22:
                out += "\\\""
            case 0x0A:
                out += "\\n"
            case 0x0D:
                out += "\\r"
            case 0x09:
                out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    let pad = String(repeating: "0", count: max(0, 4 - hex.count))
                    out += "\\u" + pad + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
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

// MARK: - GatedSayFollow

/// Where an auto-allowed `agent.say` goes after the write-gate re-read.
///
/// MCP sends that say with `prompt`, which writes the text and then Enter.
/// The tier was chosen from an earlier `agent.list`: idle or done, so no
/// person confirms it. The policy check after that list awaits. A
/// cross-workspace move in that gap leaves the old pane id empty or
/// occupied by someone else, and a block that appears there would receive
/// the Enter.
///
/// The confirming list is the one that is addressed. The original pane
/// wins when it still runs the same occupant. A different occupant refuses,
/// even when the old session is also sitting on another pane. When the
/// original pane is no longer an agent, the message follows a unique
/// session. Status and seq are not an episode lock for that hop — a move
/// that is still idle or done is the same request — but the pane that is
/// addressed has to still be idle or done. Working and blocked take the
/// confirm tier, and Enter must not reach them on the auto path. An empty
/// session value does not follow a pane that left.
public enum GatedSayFollow: Sendable {

    public enum Refusal: Equatable, Sendable {
        case agentGone
        case occupantChanged
        /// The pane that would be addressed is no longer idle or done.
        case noLongerAuto(paneId: String, status: String)
    }

    /// Idle and done are the statuses an `agent.say` may send without a
    /// person. The MCP tier and this re-read both use it, so the two cannot
    /// drift. `prompt` submits Enter; every other status waits.
    public static func acceptsAutoSend(status: String) -> Bool {
        status == AgentStatus.idle.rawValue || status == AgentStatus.done.rawValue
    }

    /// The pane the auto-send should address, or why it should not.
    public static func resolve(
        previous: HerdrAgentInfo,
        in agents: [HerdrAgentInfo]
    ) -> Result<HerdrAgentInfo, Refusal> {
        guard !previous.paneId.isEmpty else { return .failure(.agentGone) }

        let target: HerdrAgentInfo
        if let current = agents.first(where: { $0.paneId == previous.paneId && isAgent($0) }) {
            guard current.occupantFingerprint == previous.occupantFingerprint else {
                return .failure(.occupantChanged)
            }
            target = current
        } else if let session = previous.sessionIdentity,
                  let successor = ConfirmedPaneFollow.uniqueSuccessor(
                    sessionIdentity: session,
                    excluding: previous.paneId,
                    in: agents
                  ) {
            target = successor
        } else {
            return .failure(.agentGone)
        }

        guard acceptsAutoSend(status: target.agentStatus) else {
            return .failure(.noLongerAuto(paneId: target.paneId, status: target.agentStatus))
        }
        return .success(target)
    }

    private static func isAgent(_ info: HerdrAgentInfo) -> Bool {
        guard let agent = info.agent, !agent.isEmpty else { return false }
        return true
    }
}
