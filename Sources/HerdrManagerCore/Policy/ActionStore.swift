import Foundation

// MARK: - ActionState

public enum ActionState: String, Sendable, Codable {
    case pending
    case approved
    case denied
    case expired
    case executed
    case failed
}

// MARK: - PendingAction

public struct PendingAction: Sendable, Codable {
    public let actionId: String
    public let tool: String
    public let params: [String: String]
    public let createdAt: Date
    public var state: ActionState
    public let expiresAt: Date
    public var failDetail: String?

    public init(actionId: String, tool: String, params: [String: String]) {
        self.actionId = actionId
        self.tool = tool
        self.params = params
        self.createdAt = Date()
        self.state = .pending
        self.expiresAt = Date().addingTimeInterval(120)
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

    /// Generate a short action ID: "a_" + 4 random hex chars.
    private static func generateActionId() -> String {
        let hex = (0..<4).map { _ in
            String(format: "%x", Int.random(in: 0...15))
        }.joined()
        return "a_\(hex)"
    }
}
