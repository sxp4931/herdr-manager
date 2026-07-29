import Foundation

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
    private let encoder: JSONEncoder

    public init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("HerdrManager", isDirectory: true)

        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        self.fileURL = dir.appendingPathComponent("journal.ndjson")
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    /// Testable initializer with a custom file URL.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    /// Append a journal entry as one NDJSON line.
    public func record(_ entry: JournalEntry) {
        do {
            let data = try encoder.encode(entry)
            var line = data
            line.append(0x0A) // newline
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(line)
                    handle.closeFile()
                }
            } else {
                try line.write(to: fileURL)
            }
        } catch {
            FileHandle.standardError.write(Data("journal write failed: \(error)\n".utf8))
        }
    }

    /// Get the file URL for testing/inspection.
    public var url: URL { fileURL }

    /// Remove journal entries older than maxAgeDays, unless keepForever is true.
    /// Rewrites the journal file atomically.
    public func cleanup(maxAgeDays: Int = 30) {
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

        // Rewrite file atomically
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

        do {
            let dir = fileURL.deletingLastPathComponent()
            let tempURL = dir.appendingPathComponent(".journal-\(UUID().uuidString).tmp")
            try newData.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        } catch {
            FileHandle.standardError.write(Data("journal cleanup failed: \(error)\n".utf8))
        }
    }
}
