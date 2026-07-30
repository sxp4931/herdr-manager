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

    public init(actionId: String, tool: String, params: [String: String],
                occupantFingerprint: String? = nil, observedStatus: String? = nil,
                expectedSeq: UInt64? = nil) {
        self.actionId = actionId
        self.tool = tool
        self.params = params
        self.createdAt = Date()
        self.state = .pending
        self.expiresAt = Date().addingTimeInterval(120)
        self.occupantFingerprint = occupantFingerprint
        self.observedStatus = observedStatus
        self.expectedSeq = expectedSeq
    }
}

// MARK: - ActionStore

public actor ActionStore {
    private var actions: [String: PendingAction] = [:]

    public init() {}

    /// Create a new pending action. Returns the actionId.
    public func create(tool: String, params: [String: String]) -> String {
        let actionId = Self.generateActionId()
        let action = PendingAction(actionId: actionId, tool: tool, params: params)
        actions[actionId] = action
        return actionId
    }

    /// Approve a pending action. Returns the action if it was pending, nil otherwise.
    public func approve(_ actionId: String) -> PendingAction? {
        guard var action = actions[actionId], action.state == .pending else { return nil }
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

    /// Get the current status of an action.
    public func status(_ actionId: String) -> (state: ActionState, detail: String?)? {
        guard let action = actions[actionId] else { return nil }
        return (action.state, action.failDetail)
    }

    /// Get the full pending action (for executing approved actions).
    public func get(_ actionId: String) -> PendingAction? {
        return actions[actionId]
    }

    /// Expire stale pending actions (past 120s).
    public func expireStale() {
        let now = Date()
        for (id, var action) in actions {
            if action.state == .pending && now > action.expiresAt {
                action.state = .expired
                actions[id] = action
            }
        }
    }

    /// Claim an approved action for execution.
    /// Transitions from `.approved` to `.executing` only if currently approved and not expired.
    /// Returns the claimed action, or nil if not claimable.
    public func claimExecuting(actionId: String) -> PendingAction? {
        guard var action = actions[actionId], action.state == .approved else { return nil }
        guard Date() <= action.expiresAt else { return nil }
        action.state = .executing
        actions[actionId] = action
        return action
    }

    /// Generate a unique action ID using UUID.
    private static func generateActionId() -> String {
        return UUID().uuidString
    }
}
