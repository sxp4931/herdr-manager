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
    private var perAgentLastWrite: [String: Date] = [:]
    private var globalWriteTimestamps: [Date] = []
    private var consecutiveAnswers: [String: Int] = [:]
    private var lastKnownSeq: [String: UInt64] = [:]
    /// Highest herd-read serial recorded for this agent.
    private var lastObservationSerial: [String: UInt64] = [:]
    private var lastOccupant: [String: String] = [:]

    private let perAgentCooldown: TimeInterval = 10
    private let globalLimitPerMinute = 6
    private let maxConsecutiveAnswers = 3

    public init() {}

    /// Check if a write is allowed under policy.
    public func checkWriteAllowed(agentId: String, tier: AuthorityTier) -> PolicyResult {
        let now = Date()

        if case .free = tier { return .allowed }

        // Per-agent cooldown: ≤1 write per agent per 10s
        if let lastWrite = perAgentLastWrite[agentId] {
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

        // For .gated tier (agent.answer): check consecutive cap
        if case .gated = tier {
            let count = consecutiveAnswers[agentId] ?? 0
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
    public func recordWrite(agentId: String) {
        let now = Date()
        perAgentLastWrite[agentId] = now
        globalWriteTimestamps.append(now)
    }

    /// Record an answer for consecutive-answer tracking.
    public func recordAnswer(agentId: String) {
        consecutiveAnswers[agentId, default: 0] += 1
    }

    /// Record the status episode observed for an agent.
    ///
    /// Without `observationSerial`, only a strictly greater `newSeq`
    /// resets the consecutive-answer cap. An equal or lower seq is a
    /// stale observation and does not clear it.
    ///
    /// `observationSerial` orders overlapping reads of the same pane. A
    /// serial that is not strictly newer than the one already recorded is
    /// ignored, seq and occupant included. A newer serial whose seq went
    /// backwards, or whose occupant fingerprint changed, is a herdr
    /// restart or a reused pane id: the cap resets instead of sticking
    /// for the life of the process. The same seq and occupant on a newer
    /// read is still the episode the cap is counting.
    public func recordStatusChange(
        agentId: String,
        newSeq: UInt64,
        observationSerial: UInt64? = nil,
        occupantFingerprint: String? = nil
    ) {
        if let observationSerial {
            if let seen = lastObservationSerial[agentId], observationSerial <= seen {
                return
            }
            lastObservationSerial[agentId] = observationSerial

            let previousOccupant = lastOccupant[agentId]
            if let occupantFingerprint {
                lastOccupant[agentId] = occupantFingerprint
            }
            let occupantReplaced = occupantFingerprint != nil
                && previousOccupant != nil
                && occupantFingerprint != previousOccupant

            if let oldSeq = lastKnownSeq[agentId], newSeq == oldSeq, !occupantReplaced {
                return
            }
            lastKnownSeq[agentId] = newSeq
            consecutiveAnswers[agentId] = 0
            return
        }

        if let oldSeq = lastKnownSeq[agentId], newSeq <= oldSeq {
            return // stale sequence, ignore
        }
        lastKnownSeq[agentId] = newSeq
        consecutiveAnswers[agentId] = 0
        if let occupantFingerprint {
            lastOccupant[agentId] = occupantFingerprint
        }
    }
}
