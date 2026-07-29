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

    /// Record a status change — resets the consecutive answer counter.
    public func recordStatusChange(agentId: String, newSeq: UInt64) {
        if let oldSeq = lastKnownSeq[agentId], newSeq <= oldSeq {
            return // stale sequence, ignore
        }
        lastKnownSeq[agentId] = newSeq
        consecutiveAnswers[agentId] = 0
    }
}
