import Foundation
import Darwin

// MARK: - SharedActionStoreError

/// Thrown when the cross-process advisory lock cannot be acquired. The store
/// refuses to proceed unlocked — degrading silently to an unguarded
/// read-modify-write is exactly the corruption risk the lock exists to prevent.
public enum SharedActionStoreError: Error, CustomStringConvertible {
    case lockUnavailable(String)
    public var description: String {
        switch self {
        case .lockUnavailable(let detail):
            return "Cross-process lock unavailable: \(detail)"
        }
    }
}

// MARK: - SharedActionStore

/// File-based IPC for sharing pending actions between the MCP server and the menu-bar app.
/// Both processes read/write the same JSON file atomically with cross-process advisory locking.
public actor SharedActionStore {
    private let fileURL: URL
    private let lockURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL? = nil) {
        let resolvedURL: URL
        if let fileURL {
            resolvedURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            let dir = appSupport.appendingPathComponent("HerdrManager", isDirectory: true)
            Self.ensureDirectory(at: dir)
            resolvedURL = dir.appendingPathComponent("pending-actions.json")
            Self.migratePermissions(dir: dir, file: resolvedURL)
        }
        self.fileURL = resolvedURL
        self.lockURL = resolvedURL.deletingLastPathComponent()
            .appendingPathComponent(".pending-actions.lock")

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
    public func create(tool: String, params: [String: String]) throws -> String {
        return try withLock {
            var actions = loadActions()
            let actionId = Self.generateActionId()
            let action = PendingAction(actionId: actionId, tool: tool, params: params)
            actions.append(action)
            writeActions(actions)
            return actionId
        }
    }

    // MARK: - Mutate

    /// Approve a pending action by actionId.
    public func approve(_ actionId: String) throws {
        try mutate(actionId) { action in
            guard action.state == .pending else { return false }
            action.state = .approved
            return true
        }
    }

    /// Deny a pending action by actionId.
    public func deny(_ actionId: String) throws {
        try mutate(actionId) { action in
            guard action.state == .pending else { return false }
            action.state = .denied
            return true
        }
    }

    /// Mark an action as executed.
    public func markExecuted(_ actionId: String) throws {
        try mutate(actionId) { action in
            action.state = .executed
            return true
        }
    }

    /// Mark an action as failed.
    public func markFailed(_ actionId: String, detail: String) throws {
        try mutate(actionId) { action in
            action.state = .failed
            action.failDetail = detail
            return true
        }
    }

    /// Expire stale pending actions (past their expiresAt).
    public func expireStale() throws {
        try withLock {
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
    }

    /// Claim an approved action for execution.
    /// Under the cross-process lock, transitions the matching action from `.approved` to
    /// `.executing` only if it is currently `.approved` and not past its `expiresAt`.
    /// Returns the claimed action, or nil if it was not claimable
    /// (already executing/executed/denied/expired/missing).
    public func claimExecuting(actionId: String) throws -> PendingAction? {
        return try withLock {
            var actions = loadActions()
            guard let idx = actions.firstIndex(where: { $0.actionId == actionId }) else {
                return nil
            }
            guard actions[idx].state == .approved else { return nil }
            guard Date() <= actions[idx].expiresAt else { return nil }
            actions[idx].state = .executing
            writeActions(actions)
            return actions[idx]
        }
    }

    /// Expire pending actions past their `expiresAt` and prune terminal actions
    /// (`.executed`, `.failed`, `.denied`, `.expired`) whose `createdAt` is older
    /// than 24 hours. Additive — callers may invoke this periodically.
    public func reapStale(now: Date = Date()) throws {
        try withLock {
            var actions = loadActions()
            var dirty = false

            for i in actions.indices {
                if actions[i].state == .pending && now > actions[i].expiresAt {
                    actions[i].state = .expired
                    dirty = true
                }
            }

            let pruneCutoff = now.addingTimeInterval(-24 * 3600)
            let before = actions.count
            actions.removeAll { a in
                switch a.state {
                case .executed, .failed, .denied, .expired:
                    return a.createdAt < pruneCutoff
                default:
                    return false
                }
            }
            if actions.count != before { dirty = true }

            if dirty {
                writeActions(actions)
            }
        }
    }

    // MARK: - Private

    private func mutate(_ actionId: String, _ transform: (inout PendingAction) -> Bool) throws {
        try withLock {
            var actions = loadActions()
            guard let idx = actions.firstIndex(where: { $0.actionId == actionId }) else {
                return
            }
            if transform(&actions[idx]) {
                writeActions(actions)
            }
        }
    }

    /// Write actions to disk atomically: write to a temp file in the same directory,
    /// set 0600, then POSIX-rename over the destination (no absent-file window).
    private func writeActions(_ actions: [PendingAction]) {
        do {
            let data = try encoder.encode(actions)
            let dir = fileURL.deletingLastPathComponent()
            let tempURL = dir.appendingPathComponent(".pending-actions-\(UUID().uuidString).tmp")
            try data.write(to: tempURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: tempURL.path
            )
            // Atomic replace via POSIX rename — overwrites destination with no gap
            let renamed = tempURL.withUnsafeFileSystemRepresentation { tempPath in
                fileURL.withUnsafeFileSystemRepresentation { finalPath in
                    guard let tempPath, let finalPath else { return false }
                    return Darwin.rename(tempPath, finalPath) == 0
                }
            }
            if !renamed {
                try? FileManager.default.removeItem(at: tempURL)
            }
        } catch {
            FileHandle.standardError.write(
                Data("SharedActionStore write failed: \(error)\n".utf8)
            )
        }
    }

    /// Acquire a cross-process advisory lock (POSIX fcntl on a sidecar `.lock`
    /// file), execute the synchronous body, then release. Never holds the lock
    /// across an `await`. If the lock cannot be opened or acquired this THROWS
    /// rather than degrading to an unguarded read-modify-write — proceeding
    /// unlocked is the corruption risk the lock exists to prevent.
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let fd: Int32 = lockURL.withUnsafeFileSystemRepresentation { pathPtr in
            guard let pathPtr else { return -1 }
            return Darwin.open(pathPtr, O_RDWR | O_CREAT, 0o600)
        }
        guard fd >= 0 else {
            let detail = "cannot open lock file \(lockURL.lastPathComponent) (errno \(errno))"
            Self.logLockFailure(detail)
            throw SharedActionStoreError.lockUnavailable(detail)
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0  // Lock entire file
        var acquired = false
        for _ in 0..<3 {
            if Darwin.fcntl(fd, F_SETLKW, &lock) == 0 { acquired = true; break }
            if errno != EINTR { break }
        }
        defer {
            var unlock = flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            unlock.l_start = 0
            unlock.l_len = 0
            _ = Darwin.fcntl(fd, F_SETLK, &unlock)
            Darwin.close(fd)
        }
        guard acquired else {
            let detail = "fcntl lock failed on \(lockURL.lastPathComponent) (errno \(errno))"
            Self.logLockFailure(detail)
            throw SharedActionStoreError.lockUnavailable(detail)
        }
        return try body()
    }

    private static func logLockFailure(_ detail: String) {
        FileHandle.standardError.write(
            Data("SharedActionStore LOCK FAILURE: \(detail)\n".utf8)
        )
    }

    private static func ensureDirectory(at dir: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    /// Tighten permissions on an existing directory (0700) and file (0600).
    /// Silently ignores errors (e.g. file not yet created).
    private static func migratePermissions(dir: URL, file: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        if fm.fileExists(atPath: file.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private static func generateActionId() -> String {
        return UUID().uuidString
    }
}
