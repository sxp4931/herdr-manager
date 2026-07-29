import Foundation

// MARK: - Settings

public struct Settings: Codable, Sendable {
    public var defaultThresholdMinutes: Int = 5
    public var agentOverrides: [String: Int] = [:]  // paneId -> threshold minutes
    public var metadataWriteBackEnabled: Bool = true

    public init() {}
}

// MARK: - SettingsStore

public actor SettingsStore {
    private let fileURL: URL
    private var settings: Settings = Settings()

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
            self.fileURL = dir.appendingPathComponent("settings.json")
        }
    }

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return }
        let decoder = JSONDecoder()
        settings = try decoder.decode(Settings.self, from: data)
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Get the effective threshold for an agent, considering overrides.
    public func threshold(for paneId: String) -> Int {
        if let override = settings.agentOverrides[paneId] {
            return override
        }
        return settings.defaultThresholdMinutes
    }

    public func setOverride(paneId: String, minutes: Int) throws {
        settings.agentOverrides[paneId] = minutes
        try save()
    }

    public func removeOverride(paneId: String) throws {
        settings.agentOverrides.removeValue(forKey: paneId)
        try save()
    }

    public func setMetadataWriteBack(_ enabled: Bool) throws {
        settings.metadataWriteBackEnabled = enabled
        try save()
    }

    /// Non-throwing snapshot for UI reads.
    public func settingsSnapshot() -> Settings {
        settings
    }
}
