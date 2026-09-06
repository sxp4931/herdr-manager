import Foundation

// MARK: - ActionState

public enum ActionState: String, Sendable, Codable {
    case pending
    case approved
    case denied
    case expired
    case executing
    case executed
    case failed
}

// MARK: - PendingAction

public struct PendingAction: Sendable, Codable, Equatable {
    public let actionId: String
    public let tool: String
    public let params: [String: String]
    public let createdAt: Date
    public var state: ActionState
    public let expiresAt: Date
    public var failDetail: String?
    public var occupantFingerprint: String?
    public var observedStatus: String?
    public var expectedSeq: UInt64?

    public init(
        actionId: String,
        tool: String,
        params: [String: String],
        occupantFingerprint: String? = nil,
        observedStatus: String? = nil,
        expectedSeq: UInt64? = nil,
        expiresAt: Date? = nil
    ) {
        self.actionId = actionId
        self.tool = tool
        self.params = params
        self.createdAt = Date()
        self.state = .pending
        self.expiresAt = expiresAt ?? Date().addingTimeInterval(120)
        self.occupantFingerprint = occupantFingerprint
        self.observedStatus = observedStatus
        self.expectedSeq = expectedSeq
    }

    /// Apply the action deadline. Pending/approved become expired; a stuck
    /// executing claim becomes failed so it can be reaped. Returns whether
    /// the record changed.
    public mutating func applyDeadline(now: Date) -> Bool {
        switch state {
        case .pending, .approved:
            guard now > expiresAt else { return false }
            state = .expired
            return true
        case .executing:
            guard now > expiresAt else { return false }
            state = .failed
            if failDetail == nil {
                failDetail = "expired while executing"
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - ActionStore

public actor ActionStore {
    private var actions: [String: PendingAction] = [:]

    public init() {}

    /// Create a new pending action. Returns the actionId.
    public func create(tool: String, params: [String: String], expiresAt: Date? = nil) -> String {
        let actionId = Self.generateActionId()
        let action = PendingAction(
            actionId: actionId, tool: tool, params: params, expiresAt: expiresAt
        )
        actions[actionId] = action
        return actionId
    }

    /// Approve a pending action. Returns the action if it was pending, nil otherwise.
    /// An already-expired pending action is marked expired and not approved.
    public func approve(_ actionId: String, now: Date = Date()) -> PendingAction? {
        guard var action = actions[actionId], action.state == .pending else { return nil }
        guard now <= action.expiresAt else {
            action.state = .expired
            actions[actionId] = action
            return nil
        }
        action.state = .approved
        actions[actionId] = action
        return action
    }

    /// Deny a pending action.
    public func deny(_ actionId: String) {
        guard var action = actions[actionId], action.state == .pending else { return }
        action.state = .denied
        actions[actionId] = action
    }

    /// Mark an action as executed.
    public func markExecuted(_ actionId: String) {
        guard var action = actions[actionId] else { return }
        action.state = .executed
        actions[actionId] = action
    }

    /// Mark an action as failed.
    public func markFailed(_ actionId: String, detail: String) {
        guard var action = actions[actionId] else { return }
        action.state = .failed
        action.failDetail = detail
        actions[actionId] = action
    }

    /// Get the current status of an action. Past-deadline pending/approved
    /// rows are expired first so a status poll cannot present an un-approvable
    /// write as live.
    public func status(_ actionId: String, now: Date = Date()) -> (state: ActionState, detail: String?)? {
        expireStale(now: now)
        guard let action = actions[actionId] else { return nil }
        return (action.state, action.failDetail)
    }

    /// Get the full pending action (for executing approved actions).
    public func get(_ actionId: String, now: Date = Date()) -> PendingAction? {
        expireStale(now: now)
        return actions[actionId]
    }

    /// Expire stale pending/approved actions and fail stuck executing claims.
    public func expireStale(now: Date = Date()) {
        for (id, var action) in actions {
            if action.applyDeadline(now: now) {
                actions[id] = action
            }
        }
    }

    /// Claim an approved action for execution.
    /// Transitions from `.approved` to `.executing` only if currently approved and not expired.
    /// Returns the claimed action, or nil if not claimable.
    public func claimExecuting(actionId: String, now: Date = Date()) -> PendingAction? {
        guard var action = actions[actionId], action.state == .approved else { return nil }
        guard now <= action.expiresAt else {
            action.state = .expired
            actions[actionId] = action
            return nil
        }
        action.state = .executing
        actions[actionId] = action
        return action
    }

    /// Generate a unique action ID using UUID.
    private static func generateActionId() -> String {
        return UUID().uuidString
    }
}
