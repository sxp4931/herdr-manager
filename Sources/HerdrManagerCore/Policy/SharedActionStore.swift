import Foundation

// MARK: - SharedActionStore

/// File-based IPC for sharing pending actions between the MCP server and the menu-bar app.
/// Both processes read/write the same JSON file atomically.
public actor SharedActionStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            let dir = appSupport.appendingPathComponent("HerdrManager", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            self.fileURL = dir.appendingPathComponent("pending-actions.json")
        }

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = .prettyPrinted

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Read

    /// Load all actions from the file.
    public func loadActions() -> [PendingAction] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return [] }
        return (try? decoder.decode([PendingAction].self, from: data)) ?? []
    }

    /// Get only pending actions (for UI).
    public func pendingActions() -> [PendingAction] {
        loadActions().filter { $0.state == .pending }
    }

    /// Get the current state of an action.
    public func status(_ actionId: String) -> ActionState? {
        loadActions().first { $0.actionId == actionId }?.state
    }

    /// Get the full action by ID.
    public func get(_ actionId: String) -> PendingAction? {
        loadActions().first { $0.actionId == actionId }
    }

    // MARK: - Create

    /// Create a new pending action, write to file, return actionId.
    public func create(tool: String, params: [String: String]) -> String {
        var actions = loadActions()
        let actionId = Self.generateActionId()
        let action = PendingAction(actionId: actionId, tool: tool, params: params)
        actions.append(action)
        writeActions(actions)
        return actionId
    }

    // MARK: - Mutate

    /// Approve a pending action by actionId.
    public func approve(_ actionId: String) {
        mutate(actionId) { action in
            guard action.state == .pending else { return false }
            action.state = .approved
            return true
        }
    }

    /// Deny a pending action by actionId.
    public func deny(_ actionId: String) {
        mutate(actionId) { action in
            guard action.state == .pending else { return false }
            action.state = .denied
            return true
        }
    }

    /// Mark an action as executed.
    public func markExecuted(_ actionId: String) {
        mutate(actionId) { action in
            action.state = .executed
            return true
        }
    }

    /// Mark an action as failed.
    public func markFailed(_ actionId: String, detail: String) {
        mutate(actionId) { action in
            action.state = .failed
            action.failDetail = detail
            return true
        }
    }

    /// Expire stale pending actions (past their expiresAt).
    public func expireStale() {
        let now = Date()
        var actions = loadActions()
        var changed = false
        for i in actions.indices {
            if actions[i].state == .pending && now > actions[i].expiresAt {
                actions[i].state = .expired
                changed = true
            }
        }
        if changed {
            writeActions(actions)
        }
    }

    // MARK: - Private

    private func mutate(_ actionId: String, _ transform: (inout PendingAction) -> Bool) {
        var actions = loadActions()
        guard let idx = actions.firstIndex(where: { $0.actionId == actionId }) else { return }
        if transform(&actions[idx]) {
            writeActions(actions)
        }
    }

    private func writeActions(_ actions: [PendingAction]) {
        do {
            let data = try encoder.encode(actions)
            // Atomic write: write to temp file, then replace
            let dir = fileURL.deletingLastPathComponent()
            let tempURL = dir.appendingPathComponent(".pending-actions-\(UUID().uuidString).tmp")
            try data.write(to: tempURL, options: .atomic)
            // Replace existing file atomically
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        } catch {
            FileHandle.standardError.write(Data("SharedActionStore write failed: \(error)\n".utf8))
        }
    }

    private static func generateActionId() -> String {
        let hex = (0..<4).map { _ in
            String(format: "%x", Int.random(in: 0...15))
        }.joined()
        return "a_\(hex)"
    }
}
