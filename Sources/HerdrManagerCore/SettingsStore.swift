import Foundation

// MARK: - Settings

public struct Settings: Codable, Sendable {
    public var defaultThresholdMinutes: Int = 5
    public var agentOverrides: [String: Int] = [:]  // paneId -> minutes (legacy/fallback)
    /// Threshold overrides keyed by OCCUPANT identity (agent kind/session), so
    /// an override follows the agent rather than the pane it happens to occupy.
    /// Looked up before the pane-id map; defaults to empty for old settings files.
    public var occupantOverrides: [String: Int] = [:]
    public var metadataWriteBackEnabled: Bool = true
    /// Editable API-equivalent prices. Old settings files predate the usage
    /// meter, so decoding falls back to the bundled price book.
    public var tokenMeterPrices: [String: TokenMeterPricing] = TokenMeterPriceBook.defaults.entries

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case defaultThresholdMinutes
        case agentOverrides
        case occupantOverrides
        case metadataWriteBackEnabled
        case tokenMeterPrices
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultThresholdMinutes = try container.decodeIfPresent(Int.self, forKey: .defaultThresholdMinutes) ?? 5
        agentOverrides = try container.decodeIfPresent([String: Int].self, forKey: .agentOverrides) ?? [:]
        occupantOverrides = try container.decodeIfPresent([String: Int].self, forKey: .occupantOverrides) ?? [:]
        metadataWriteBackEnabled = try container.decodeIfPresent(Bool.self, forKey: .metadataWriteBackEnabled) ?? true
        tokenMeterPrices = try container.decodeIfPresent(
            [String: TokenMeterPricing].self,
            forKey: .tokenMeterPrices
        ) ?? TokenMeterPriceBook.defaults.entries
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultThresholdMinutes, forKey: .defaultThresholdMinutes)
        try container.encode(agentOverrides, forKey: .agentOverrides)
        try container.encode(occupantOverrides, forKey: .occupantOverrides)
        try container.encode(metadataWriteBackEnabled, forKey: .metadataWriteBackEnabled)
        try container.encode(tokenMeterPrices, forKey: .tokenMeterPrices)
    }
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
    /// Occupant-keyed overrides (which follow the agent across panes) take
    /// precedence over the legacy pane-id map; falls back to the default.
    public func threshold(for paneId: String, occupant: String? = nil) -> Int {
        if let occupant, let override = settings.occupantOverrides[occupant] {
            return override
        }
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

    /// Set a threshold override keyed by OCCUPANT identity (follows the agent).
    public func setOverride(occupant: String, minutes: Int) throws {
        settings.occupantOverrides[occupant] = minutes
        try save()
    }

    public func removeOverride(occupant: String) throws {
        settings.occupantOverrides.removeValue(forKey: occupant)
        try save()
    }

    public func setMetadataWriteBack(_ enabled: Bool) throws {
        settings.metadataWriteBackEnabled = enabled
        try save()
    }

    public func setTokenMeterPriceBook(_ priceBook: TokenMeterPriceBook) throws {
        settings.tokenMeterPrices = priceBook.entries
        try save()
    }

    /// Non-throwing snapshot for UI reads.
    public func settingsSnapshot() -> Settings {
        settings
    }
}
