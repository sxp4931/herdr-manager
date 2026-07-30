import Foundation
import Darwin

// MARK: - JournalEntry

public struct JournalEntry: Sendable, Codable {
    public let timestamp: Date
    public let actionId: String
    public let tool: String
    public let params: [String: String]
    public let caller: String
    public let preState: String
    public let postState: String?
    public let outcome: String
    public var keepForever: Bool

    public init(
        timestamp: Date = Date(),
        actionId: String,
        tool: String,
        params: [String: String],
        caller: String,
        preState: String,
        postState: String? = nil,
        outcome: String,
        keepForever: Bool = false
    ) {
        self.timestamp = timestamp
        self.actionId = actionId
        self.tool = tool
        self.params = params
        self.caller = caller
        self.preState = preState
        self.postState = postState
        self.outcome = outcome
        self.keepForever = keepForever
    }
}

// MARK: - Journal

public actor Journal {
    private let fileURL: URL
    private let lockURL: URL
    private let encoder: JSONEncoder

    public init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("HerdrManager", isDirectory: true)
        Self.ensureDirectory(at: dir)
        let url = dir.appendingPathComponent("journal.ndjson")
        Self.migratePermissions(dir: dir, file: url)
        self.fileURL = url
        self.lockURL = dir.appendingPathComponent(".journal.lock")
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    /// Testable initializer with a custom file URL.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.lockURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".journal.lock")
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    /// Append a journal entry as one NDJSON line under cross-process advisory lock.
    public func record(_ entry: JournalEntry) {
        do {
            let data = try encoder.encode(entry)
            var line = data
            line.append(0x0A)
            try withLock {
                try appendLine(line)
            }
        } catch {
            FileHandle.standardError.write(Data("journal write failed: \(error)\n".utf8))
        }
    }

    /// Get the file URL for testing/inspection.
    public var url: URL { fileURL }

    /// Remove journal entries older than maxAgeDays, unless keepForever is true.
    /// Rewrites the journal file atomically under cross-process advisory lock.
    public func cleanup(maxAgeDays: Int = 30) {
        do {
            try withLock {
                try cleanupUnlocked(maxAgeDays: maxAgeDays)
            }
        } catch {
            FileHandle.standardError.write(Data("journal cleanup failed: \(error)\n".utf8))
        }
    }

    // MARK: - Private

    /// Open the journal file with O_APPEND and write a single line.
    /// The caller must already hold the cross-process lock.
    private func appendLine(_ line: Data) throws {
        let fd: Int32 = fileURL.withUnsafeFileSystemRepresentation { pathPtr in
            guard let pathPtr else { return -1 }
            return Darwin.open(pathPtr, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        }
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { Darwin.close(fd) }
        line.withUnsafeBytes { buf in
            if let base = buf.baseAddress {
                _ = Darwin.write(fd, base, buf.count)
            }
        }
    }

    /// Read, filter, and atomically rewrite the journal. Caller must hold the lock.
    private func cleanupUnlocked(maxAgeDays: Int) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return }

        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86400)
        var kept: [Data] = []

        for line in lines {
            guard let entry = try? decoder.decode(JournalEntry.self, from: Data(line)) else {
                continue // skip malformed lines
            }
            if entry.keepForever || entry.timestamp > cutoff {
                if let encoded = try? encoder.encode(entry) {
                    kept.append(encoded)
                }
            }
        }

        var newData = Data()
        for (i, line) in kept.enumerated() {
            newData.append(line)
            if i < kept.count - 1 {
                newData.append(0x0A)
            }
        }
        if !kept.isEmpty {
            newData.append(0x0A) // trailing newline
        }

        let dir = fileURL.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent(".journal-\(UUID().uuidString).tmp")
        try newData.write(to: tempURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tempURL.path
        )
        // Atomic replace via POSIX rename — no absent-file window
        let renamed = tempURL.withUnsafeFileSystemRepresentation { tempPath in
            fileURL.withUnsafeFileSystemRepresentation { finalPath in
                guard let tempPath, let finalPath else { return false }
                return Darwin.rename(tempPath, finalPath) == 0
            }
        }
        if !renamed {
            try? FileManager.default.removeItem(at: tempURL)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Acquire a cross-process advisory lock (POSIX fcntl on a sidecar `.lock` file),
    /// execute the synchronous body, then release. Never holds the lock across an `await`.
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd: Int32 = lockURL.withUnsafeFileSystemRepresentation { pathPtr in
            guard let pathPtr else { return -1 }
            return Darwin.open(pathPtr, O_RDWR | O_CREAT, 0o600)
        }
        guard fd >= 0 else {
            // Degrade to unlocked operation if the lock file cannot be opened
            return try body()
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0  // Lock entire file
        _ = Darwin.fcntl(fd, F_SETLKW, &lock)
        defer {
            var unlock = flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            unlock.l_start = 0
            unlock.l_len = 0
            _ = Darwin.fcntl(fd, F_SETLK, &unlock)
            Darwin.close(fd)
        }
        return try body()
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
    private static func migratePermissions(dir: URL, file: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        if fm.fileExists(atPath: file.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
