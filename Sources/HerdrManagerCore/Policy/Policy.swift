import Foundation

// MARK: - AuthorityTier

public enum AuthorityTier: Sendable {
    case free       // read tools — no gating
    case gated      // agent.answer, agent.say when idle/done
    case confirm    // agent.say when working/blocked, interrupt, stop, spawn
}

// MARK: - PolicyResult

public struct PolicyResult: Sendable {
    public let allowed: Bool
    public let reason: String?
    public let retryAfterSeconds: Int?

    public init(allowed: Bool, reason: String? = nil, retryAfterSeconds: Int? = nil) {
        self.allowed = allowed
        self.reason = reason
        self.retryAfterSeconds = retryAfterSeconds
    }

    public static let allowed = PolicyResult(allowed: true)
}

// MARK: - PolicyEngine

public actor PolicyEngine {
    /// Pane id, or the session identity when the caller has one.
    ///
    /// A cross-workspace move assigns a new public pane id. The answer
    /// cap and the write cooldown belong to the occupant, so a client
    /// that addresses the new id must not start from an empty budget.
    /// An empty session value is not a key: several panes look like that.
    private enum BudgetKey: Hashable, Sendable {
        case pane(String)
        case session(String)
    }

    private var perAgentLastWrite: [BudgetKey: Date] = [:]
    private var globalWriteTimestamps: [Date] = []
    private var consecutiveAnswers: [BudgetKey: Int] = [:]
    private var lastKnownSeq: [BudgetKey: UInt64] = [:]
    /// Highest herd-read serial recorded for this budget.
    private var lastObservationSerial: [BudgetKey: UInt64] = [:]
    private var lastOccupant: [BudgetKey: String] = [:]

    private let perAgentCooldown: TimeInterval = 10
    private let globalLimitPerMinute = 6
    private let maxConsecutiveAnswers = 3

    public init() {}

    /// Check if a write is allowed under policy.
    ///
    /// `sessionIdentity` is `HerdrAgentInfo.sessionIdentity`. Pass it on
    /// every check and record for that occupant. The cooldown also
    /// sticks to `agentId` itself, so a write recorded with a session
    /// still limits a later check of that same pane that omits it.
    public func checkWriteAllowed(
        agentId: String,
        tier: AuthorityTier,
        sessionIdentity: String? = nil
    ) -> PolicyResult {
        let now = Date()

        if case .free = tier { return .allowed }

        // Per-agent cooldown: ≤1 write per agent per 10s. A session
        // write is visible from every pane id checked with that session,
        // and from the pane id the write named.
        if let lastWrite = cooldownAnchor(agentId: agentId, sessionIdentity: sessionIdentity) {
            let elapsed = now.timeIntervalSince(lastWrite)
            if elapsed < perAgentCooldown {
                let retryAfter = Int(perAgentCooldown - elapsed) + 1
                return PolicyResult(
                    allowed: false,
                    reason: "Per-agent rate limit: wait \(retryAfter)s between writes to \(agentId)",
                    retryAfterSeconds: retryAfter
                )
            }
        }

        // Global rate limit: ≤6/min
        let cutoff = now.addingTimeInterval(-60)
        globalWriteTimestamps.removeAll { $0 < cutoff }
        if globalWriteTimestamps.count >= globalLimitPerMinute {
            let oldest = globalWriteTimestamps.first ?? now
            let retryAfter = Int(oldest.addingTimeInterval(60).timeIntervalSince(now)) + 1
            return PolicyResult(
                allowed: false,
                reason: "Global rate limit: \(globalLimitPerMinute) writes/min exceeded",
                retryAfterSeconds: max(retryAfter, 1)
            )
        }

        // For .gated tier (agent.answer, and agent.say while idle or
        // done): a session counts only its own answers. The pane count
        // is the mirror for a check that has no session. Mixing the two
        // would leave the previous occupant's cap on an id a new session
        // had just taken.
        if case .gated = tier {
            let count = answerCount(agentId: agentId, sessionIdentity: sessionIdentity)
            if count >= maxConsecutiveAnswers {
                return PolicyResult(
                    allowed: false,
                    reason: "Consecutive answer limit: \(maxConsecutiveAnswers) answers to \(agentId) without status change",
                    retryAfterSeconds: nil
                )
            }
        }

        return .allowed
    }

    /// Record that a write was performed for an agent.
    ///
    /// One global timestamp. A session also stamps `agentId`, so the
    /// pane the write addressed stays in cooldown when a later check
    /// has no session to offer.
    public func recordWrite(agentId: String, sessionIdentity: String? = nil) {
        let now = Date()
        let key = budgetKey(agentId: agentId, sessionIdentity: sessionIdentity)
        perAgentLastWrite[key] = now
        if case .session = key {
            perAgentLastWrite[.pane(agentId)] = now
        }
        globalWriteTimestamps.append(now)
    }

    /// Record an answer for consecutive-answer tracking.
    ///
    /// The session count is the one a later pane id checks. The pane
    /// count stays in step so a check that only has this pane id still
    /// sees the answers just recorded against it.
    public func recordAnswer(agentId: String, sessionIdentity: String? = nil) {
        let key = budgetKey(agentId: agentId, sessionIdentity: sessionIdentity)
        consecutiveAnswers[key, default: 0] += 1
        if case .session = key {
            consecutiveAnswers[.pane(agentId), default: 0] += 1
        }
    }

    /// Record the status episode observed for an agent.
    ///
    /// Without `observationSerial`, only a strictly greater `newSeq`
    /// resets the consecutive-answer cap. An equal or lower seq is a
    /// stale observation and does not clear it. An equal seq on a
    /// session does publish that session's cap onto `agentId`, which is
    /// how a move makes the new pane id refuse the next answer.
    ///
    /// `observationSerial` orders overlapping reads of the same
    /// occupant. A serial that is not strictly newer than the one
    /// already recorded is ignored, seq and occupant included. A newer
    /// serial whose seq went backwards, or whose occupant fingerprint
    /// changed, is a herdr restart or a reused pane id: the cap resets
    /// instead of sticking for the life of the process. The same seq
    /// and occupant on a newer read is still the episode the cap is
    /// counting. A fingerprint that differs only by the pane id is the
    /// same occupant when both strings belong to `sessionIdentity`.
    public func recordStatusChange(
        agentId: String,
        newSeq: UInt64,
        observationSerial: UInt64? = nil,
        occupantFingerprint: String? = nil,
        sessionIdentity: String? = nil
    ) {
        let key = budgetKey(agentId: agentId, sessionIdentity: sessionIdentity)
        if let observationSerial {
            if let seen = lastObservationSerial[key], observationSerial <= seen {
                return
            }
            lastObservationSerial[key] = observationSerial

            let previousOccupant = lastOccupant[key]
            if let occupantFingerprint {
                lastOccupant[key] = occupantFingerprint
            }
            let occupantReplaced = Self.occupantReplaced(
                previous: previousOccupant,
                current: occupantFingerprint,
                sessionIdentity: sessionIdentity
            )

            if let oldSeq = lastKnownSeq[key], newSeq == oldSeq, !occupantReplaced {
                mirrorCapOntoPane(key: key, agentId: agentId)
                return
            }
            lastKnownSeq[key] = newSeq
            clearAnswers(key: key, agentId: agentId)
            return
        }

        if let oldSeq = lastKnownSeq[key], newSeq < oldSeq {
            return // stale sequence, ignore
        }
        if let oldSeq = lastKnownSeq[key], newSeq == oldSeq {
            mirrorCapOntoPane(key: key, agentId: agentId)
            return
        }
        lastKnownSeq[key] = newSeq
        clearAnswers(key: key, agentId: agentId)
        if let occupantFingerprint {
            lastOccupant[key] = occupantFingerprint
        }
    }

    /// Session when the caller has a non-empty one, otherwise the pane.
    private func budgetKey(agentId: String, sessionIdentity: String?) -> BudgetKey {
        if let sessionIdentity, !sessionIdentity.isEmpty {
            return .session(sessionIdentity)
        }
        return .pane(agentId)
    }

    /// The later of the pane's own write and the session's write.
    private func cooldownAnchor(agentId: String, sessionIdentity: String?) -> Date? {
        var latest = perAgentLastWrite[.pane(agentId)]
        if let sessionIdentity, !sessionIdentity.isEmpty,
           let sessionWrite = perAgentLastWrite[.session(sessionIdentity)] {
            if let paneWrite = latest {
                latest = max(paneWrite, sessionWrite)
            } else {
                latest = sessionWrite
            }
        }
        return latest
    }

    /// Answers recorded for this check. A session does not consult the
    /// pane mirror: that mirror can still hold the occupant who left.
    private func answerCount(agentId: String, sessionIdentity: String?) -> Int {
        if let sessionIdentity, !sessionIdentity.isEmpty {
            return consecutiveAnswers[.session(sessionIdentity)] ?? 0
        }
        return consecutiveAnswers[.pane(agentId)] ?? 0
    }

    /// Publish the session cap on the pane this observation named.
    private func mirrorCapOntoPane(key: BudgetKey, agentId: String) {
        guard case .session = key else { return }
        consecutiveAnswers[.pane(agentId)] = consecutiveAnswers[key] ?? 0
    }

    /// A new episode drops the session count and the pane mirror. The
    /// pane mirror belongs to whoever was just observed; leaving it
    /// would block the next occupant of this id.
    private func clearAnswers(key: BudgetKey, agentId: String) {
        consecutiveAnswers[key] = 0
        if case .session = key {
            consecutiveAnswers[.pane(agentId)] = 0
        }
    }

    /// True when both fingerprints are present and name different
    /// occupants. A pane-id suffix on the same session is the move, not
    /// a new occupant. Callers that omit the session keep a raw string
    /// compare, which is what an equal-seq replacement resets on.
    private static func occupantReplaced(
        previous: String?,
        current: String?,
        sessionIdentity: String?
    ) -> Bool {
        guard let current, let previous, current != previous else { return false }
        if let sessionIdentity, !sessionIdentity.isEmpty,
           fingerprintBelongs(current, to: sessionIdentity),
           fingerprintBelongs(previous, to: sessionIdentity) {
            return false
        }
        return true
    }

    /// `session|<identity>|<paneId>`. The trailing separator keeps a
    /// longer session value (`…abc` vs `…abcd`) from matching.
    private static func fingerprintBelongs(_ fingerprint: String, to sessionIdentity: String) -> Bool {
        fingerprint.hasPrefix("session|\(sessionIdentity)|")
    }
}
