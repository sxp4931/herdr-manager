import Foundation

// MARK: - Provider and time windows

/// Providers for which the local log formats are understood by TokenMeter.
/// Herdr's agent kind list is intentionally broader than this list: an agent
/// can still be monitored without having a locally readable billing log.
public enum TokenMeterProvider: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case claude
    case codex
    case kimi
    case grok
    case deepseek
    case qwen

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex / OpenAI"
        case .kimi: return "Kimi"
        case .grok: return "Grok"
        case .deepseek: return "DeepSeek"
        case .qwen: return "Qwen / Alibaba"
        }
    }

    /// Maps Herdr's detected agent kind to a supported local log provider.
    public init?(agentKind: AgentKind) {
        self.init(rawValue: agentKind.label)
    }

    public init?(rawValue: String) {
        switch rawValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "claude", "claude-code", "claude_code", "anthropic": self = .claude
        case "codex", "openai": self = .codex
        case "kimi", "kimi-code", "kimi_code": self = .kimi
        case "grok", "xai": self = .grok
        case "deepseek", "deepseek-r1", "deepseek_v3": self = .deepseek
        case "qwen", "alibaba", "dashscope", "qwen-coder": self = .qwen
        default: return nil
        }
    }
}

public enum UsageWindow: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case hour
    case day
    case week
    case month
    case allTime

    public var id: Self { self }

    public var shortLabel: String {
        switch self {
        case .hour: return "1h"
        case .day: return "Today"
        case .week: return "Week"
        case .month: return "Month"
        case .allTime: return "All"
        }
    }

    public var longLabel: String {
        switch self {
        case .hour: return "Last hour"
        case .day: return "Today"
        case .week: return "This week"
        case .month: return "This month"
        case .allTime: return "All time"
        }
    }

    public func startDate(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .hour:
            return now.addingTimeInterval(-60 * 60)
        case .day:
            return calendar.startOfDay(for: now)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.startOfDay(for: now)
        case .month:
            return calendar.dateInterval(of: .month, for: now)?.start
                ?? calendar.startOfDay(for: now)
        case .allTime:
            return .distantPast
        }
    }
}

// MARK: - Pricing

/// USD list prices per million tokens. These are API-equivalent reference
/// prices, not the user's subscription bill. Cache write fields are retained
/// even though some CLIs do not expose them.
public struct TokenMeterPricing: Codable, Equatable, Sendable {
    public var inputPerMillion: Double
    public var cacheReadPerMillion: Double
    public var cacheWrite5mPerMillion: Double
    public var cacheWrite1hPerMillion: Double
    public var outputPerMillion: Double

    public init(
        inputPerMillion: Double,
        cacheReadPerMillion: Double? = nil,
        cacheWrite5mPerMillion: Double? = nil,
        cacheWrite1hPerMillion: Double? = nil,
        outputPerMillion: Double
    ) {
        self.inputPerMillion = inputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion ?? inputPerMillion
        self.cacheWrite5mPerMillion = cacheWrite5mPerMillion ?? inputPerMillion
        self.cacheWrite1hPerMillion = cacheWrite1hPerMillion ?? self.cacheWrite5mPerMillion
        self.outputPerMillion = outputPerMillion
    }

    public func cost(for usage: TokenUsage) -> Double {
        if usage.isSplit {
            let uncached = max(
                0,
                usage.inputTokens
                    - usage.cacheReadTokens
                    - usage.cacheWrite5mTokens
                    - usage.cacheWrite1hTokens
            )
            return (
                Double(uncached) * inputPerMillion
                    + Double(usage.cacheReadTokens) * cacheReadPerMillion
                    + Double(usage.cacheWrite5mTokens) * cacheWrite5mPerMillion
                    + Double(usage.cacheWrite1hTokens) * cacheWrite1hPerMillion
                    + Double(usage.outputTokens) * outputPerMillion
            ) / 1_000_000.0
        }

        // This follows TokenMeter's documented fallback for CLIs (currently
        // Grok) that only log a running context total.
        let outputShare = 0.05
        let cacheHit = 0.90
        let output = Double(usage.totalTokens) * outputShare
        let input = Double(usage.totalTokens) - output
        return (
            input * ((1.0 - cacheHit) * inputPerMillion + cacheHit * cacheReadPerMillion)
                + output * outputPerMillion
        ) / 1_000_000.0
    }
}

/// A small, editable price book. Provider names are fallback keys. Model
/// fragments are matched before them, with provider-scoped keys taking
/// precedence over legacy unscoped model keys. A logged model never falls
/// through to a generic provider price: unknown models remain unpriced.
public struct TokenMeterPriceBook: Codable, Equatable, Sendable {
    public var entries: [String: TokenMeterPricing]

    public init(entries: [String: TokenMeterPricing] = TokenMeterPriceBook.defaults.entries) {
        self.entries = entries
    }

    public func pricing(for provider: TokenMeterProvider, model: String?) -> TokenMeterPricing? {
        let modelKey = model?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEntries = entries.map { ($0.key.lowercased(), $0.value) }

        if let modelKey, !modelKey.isEmpty {
            let scopedPrefix = "\(provider.rawValue):"
            let scopedMatches = normalizedEntries
                .compactMap { key, value -> (String, TokenMeterPricing)? in
                    guard key.hasPrefix(scopedPrefix) else { return nil }
                    let fragment = String(key.dropFirst(scopedPrefix.count))
                    guard !fragment.isEmpty,
                          modelKey == fragment || modelKey.contains(fragment) else {
                        return nil
                    }
                    return (fragment, value)
                }
                .sorted { $0.0.count > $1.0.count }
            if let match = scopedMatches.first {
                return match.1
            }

            let providerKeys = Set(TokenMeterProvider.allCases.map(\.rawValue))
            // Exclude provider-scoped keys (e.g. "codex:gpt-5"), which are
            // handled by the scoped match above, and bare provider fallback
            // keys. Unscoped id entries may legitimately contain colons (e.g.
            // the OpenRouter "tencent/hy3:free" free model), so only prefixes
            // belonging to a provider are filtered rather than any colon.
            let providerScopedPrefixes = Set(
                TokenMeterProvider.allCases.map { "\($0.rawValue):" }
            )
            let legacyMatches = normalizedEntries
                .filter { key, _ in
                    !providerScopedPrefixes.contains { key.hasPrefix($0) }
                        && !providerKeys.contains(key)
                        && (modelKey == key || modelKey.contains(key))
                }
                .sorted { $0.0.count > $1.0.count }
            if let match = legacyMatches.first {
                return match.1
            }

            // A model was recorded but no model-specific price is known.
            // Returning the provider fallback here would silently misprice it.
            return nil
        }

        return entries[provider.rawValue]
    }

    public mutating func setProviderPricing(_ pricing: TokenMeterPricing, for provider: TokenMeterProvider) {
        entries[provider.rawValue] = pricing
    }

    public mutating func setModelPricing(
        _ pricing: TokenMeterPricing,
        for provider: TokenMeterProvider,
        model: String
    ) {
        let normalizedModel = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else { return }
        entries[Self.modelEntryKey(for: provider, model: normalizedModel)] = pricing
    }

    public static func modelEntryKey(for provider: TokenMeterProvider, model: String) -> String {
        "\(provider.rawValue):\(model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Defaults are intentionally explicit and easy to replace. The app does
    /// not fetch prices or send log data anywhere; users can edit these values
    /// from the Usage screen when a provider changes rates or a gateway uses a
    /// different model price.
    public static let defaults = TokenMeterPriceBook(entries: [
        // Anthropic: Sonnet 5 introductory rate in effect in July/August 2026.
        "claude-sonnet-5": TokenMeterPricing(
            inputPerMillion: 2.0,
            cacheReadPerMillion: 0.20,
            cacheWrite5mPerMillion: 2.50,
            cacheWrite1hPerMillion: 4.0,
            outputPerMillion: 10.0
        ),
        "claude-sonnet-4.6": TokenMeterPricing(
            inputPerMillion: 3.0,
            cacheReadPerMillion: 0.30,
            cacheWrite5mPerMillion: 3.75,
            cacheWrite1hPerMillion: 6.0,
            outputPerMillion: 15.0
        ),
        "claude-sonnet-4-6": TokenMeterPricing(
            inputPerMillion: 3.0,
            cacheReadPerMillion: 0.30,
            cacheWrite5mPerMillion: 3.75,
            cacheWrite1hPerMillion: 6.0,
            outputPerMillion: 15.0
        ),
        "claude-sonnet-4.5": TokenMeterPricing(
            inputPerMillion: 3.0,
            cacheReadPerMillion: 0.30,
            cacheWrite5mPerMillion: 3.75,
            cacheWrite1hPerMillion: 6.0,
            outputPerMillion: 15.0
        ),
        "claude-sonnet-4-5": TokenMeterPricing(
            inputPerMillion: 3.0,
            cacheReadPerMillion: 0.30,
            cacheWrite5mPerMillion: 3.75,
            cacheWrite1hPerMillion: 6.0,
            outputPerMillion: 15.0
        ),
        "claude-opus-5": TokenMeterPricing(
            inputPerMillion: 5.0,
            cacheReadPerMillion: 0.50,
            cacheWrite5mPerMillion: 6.25,
            cacheWrite1hPerMillion: 10.0,
            outputPerMillion: 25.0
        ),
        "claude-fable-5": TokenMeterPricing(
            inputPerMillion: 10.0,
            cacheReadPerMillion: 1.0,
            cacheWrite5mPerMillion: 12.50,
            cacheWrite1hPerMillion: 20.0,
            outputPerMillion: 50.0
        ),
        "claude-mythos-5": TokenMeterPricing(
            inputPerMillion: 10.0,
            cacheReadPerMillion: 1.0,
            cacheWrite5mPerMillion: 12.50,
            cacheWrite1hPerMillion: 20.0,
            outputPerMillion: 50.0
        ),
        "claude-opus-4.5": TokenMeterPricing(
            inputPerMillion: 5.0,
            cacheReadPerMillion: 0.50,
            cacheWrite5mPerMillion: 6.25,
            cacheWrite1hPerMillion: 10.0,
            outputPerMillion: 25.0
        ),
        "claude-opus-4-5": TokenMeterPricing(
            inputPerMillion: 5.0,
            cacheReadPerMillion: 0.50,
            cacheWrite5mPerMillion: 6.25,
            cacheWrite1hPerMillion: 10.0,
            outputPerMillion: 25.0
        ),
        "claude-haiku-4.5": TokenMeterPricing(
            inputPerMillion: 1.0,
            cacheReadPerMillion: 0.10,
            cacheWrite5mPerMillion: 1.25,
            cacheWrite1hPerMillion: 2.0,
            outputPerMillion: 5.0
        ),
        "claude-haiku-4-5": TokenMeterPricing(
            inputPerMillion: 1.0,
            cacheReadPerMillion: 0.10,
            cacheWrite5mPerMillion: 1.25,
            cacheWrite1hPerMillion: 2.0,
            outputPerMillion: 5.0
        ),
        "claude": TokenMeterPricing(
            inputPerMillion: 3.0,
            cacheReadPerMillion: 0.30,
            cacheWrite5mPerMillion: 3.75,
            cacheWrite1hPerMillion: 6.0,
            outputPerMillion: 15.0
        ),

        // OpenAI / Codex model rates (short-context), verified against
        // https://platform.openai.com/docs/pricing on 2026-08-06. Codex
        // sessions often omit the model id, so the provider fallback uses
        // the GPT-5.6 Terra rate.
        "gpt-5.6-sol": TokenMeterPricing(
            inputPerMillion: 5.0,
            cacheReadPerMillion: 0.50,
            cacheWrite5mPerMillion: 6.25,
            cacheWrite1hPerMillion: 6.25,
            outputPerMillion: 30.0
        ),
        "gpt-5.6-terra": TokenMeterPricing(
            inputPerMillion: 2.0,
            cacheReadPerMillion: 0.20,
            cacheWrite5mPerMillion: 2.50,
            cacheWrite1hPerMillion: 2.50,
            outputPerMillion: 12.0
        ),
        "gpt-5.6-luna": TokenMeterPricing(
            inputPerMillion: 0.20,
            cacheReadPerMillion: 0.02,
            cacheWrite5mPerMillion: 0.25,
            cacheWrite1hPerMillion: 0.25,
            outputPerMillion: 1.20
        ),
        "gpt-5.5": TokenMeterPricing(
            inputPerMillion: 5.0,
            cacheReadPerMillion: 0.50,
            cacheWrite5mPerMillion: 5.0,
            cacheWrite1hPerMillion: 5.0,
            outputPerMillion: 30.0
        ),
        "gpt-5.5-pro": TokenMeterPricing(
            inputPerMillion: 30.0,
            cacheReadPerMillion: 30.0,
            cacheWrite5mPerMillion: 30.0,
            cacheWrite1hPerMillion: 30.0,
            outputPerMillion: 180.0
        ),
        "gpt-5.4": TokenMeterPricing(
            inputPerMillion: 2.50,
            cacheReadPerMillion: 0.25,
            cacheWrite5mPerMillion: 2.50,
            cacheWrite1hPerMillion: 2.50,
            outputPerMillion: 15.0
        ),
        "gpt-5.4-mini": TokenMeterPricing(
            inputPerMillion: 0.75,
            cacheReadPerMillion: 0.075,
            cacheWrite5mPerMillion: 0.75,
            cacheWrite1hPerMillion: 0.75,
            outputPerMillion: 4.50
        ),
        "gpt-5.4-nano": TokenMeterPricing(
            inputPerMillion: 0.20,
            cacheReadPerMillion: 0.02,
            cacheWrite5mPerMillion: 0.20,
            cacheWrite1hPerMillion: 0.20,
            outputPerMillion: 1.25
        ),
        "gpt-5.4-pro": TokenMeterPricing(
            inputPerMillion: 30.0,
            cacheReadPerMillion: 30.0,
            cacheWrite5mPerMillion: 30.0,
            cacheWrite1hPerMillion: 30.0,
            outputPerMillion: 180.0
        ),
        "gpt-5.3-codex": TokenMeterPricing(
            inputPerMillion: 1.75,
            cacheReadPerMillion: 0.175,
            cacheWrite5mPerMillion: 1.75,
            cacheWrite1hPerMillion: 1.75,
            outputPerMillion: 14.0
        ),
        "gpt-5": TokenMeterPricing(
            inputPerMillion: 1.25,
            cacheReadPerMillion: 0.125,
            cacheWrite5mPerMillion: 1.5625,
            cacheWrite1hPerMillion: 1.5625,
            outputPerMillion: 10.0
        ),
        // codex-auto-review has no separately published fee; it is a Codex
        // agent that consumes the same token budget, priced like GPT-5.6 Terra.
        "codex-auto-review": TokenMeterPricing(
            inputPerMillion: 2.0,
            cacheReadPerMillion: 0.20,
            cacheWrite5mPerMillion: 2.50,
            cacheWrite1hPerMillion: 2.50,
            outputPerMillion: 12.0
        ),
        "codex": TokenMeterPricing(
            inputPerMillion: 2.0,
            cacheReadPerMillion: 0.20,
            cacheWrite5mPerMillion: 2.50,
            cacheWrite1hPerMillion: 2.50,
            outputPerMillion: 12.0
        ),

        // DeepSeek rates, verified against
        // https://api-docs.deepseek.com/quick_start/pricing on 2026-08-06.
        // DeepSeek has no separate cache-write tier; writes bill at the cache
        // miss (input) rate. A price increase has been announced but with no
        // date or amount yet.
        "deepseek-v4-flash": TokenMeterPricing(
            inputPerMillion: 0.14,
            cacheReadPerMillion: 0.0028,
            cacheWrite5mPerMillion: 0.14,
            cacheWrite1hPerMillion: 0.14,
            outputPerMillion: 0.28
        ),
        // The -0731 suffix is the versioned snapshot id recorded in opencode's
        // DB; it prices identically to v4-flash.
        "deepseek-v4-flash-0731": TokenMeterPricing(
            inputPerMillion: 0.14,
            cacheReadPerMillion: 0.0028,
            cacheWrite5mPerMillion: 0.14,
            cacheWrite1hPerMillion: 0.14,
            outputPerMillion: 0.28
        ),
        "deepseek-v4-pro": TokenMeterPricing(
            inputPerMillion: 0.435,
            cacheReadPerMillion: 0.003625,
            cacheWrite5mPerMillion: 0.435,
            cacheWrite1hPerMillion: 0.435,
            outputPerMillion: 0.87
        ),
        "deepseek": TokenMeterPricing(
            inputPerMillion: 0.14,
            cacheReadPerMillion: 0.0028,
            cacheWrite5mPerMillion: 0.14,
            cacheWrite1hPerMillion: 0.14,
            outputPerMillion: 0.28
        ),

        // Qwen / Alibaba Model Studio rates (Global regions), verified against
        // https://www.alibabacloud.com/help/en/model-studio/qwen3-8-max on
        // 2026-08-03. The provider fallback uses the balanced qwen3.7-plus
        // rate.
        "qwen3.8-max": TokenMeterPricing(
            inputPerMillion: 1.65,
            cacheReadPerMillion: 0.206,
            cacheWrite5mPerMillion: 2.063,
            cacheWrite1hPerMillion: 2.063,
            outputPerMillion: 4.951
        ),
        // Alias: no separately priced page for the preview snapshot.
        "qwen3.8-max-preview": TokenMeterPricing(
            inputPerMillion: 1.65,
            cacheReadPerMillion: 0.206,
            cacheWrite5mPerMillion: 2.063,
            cacheWrite1hPerMillion: 2.063,
            outputPerMillion: 4.951
        ),
        "qwen3.7-max": TokenMeterPricing(
            inputPerMillion: 1.65,
            cacheReadPerMillion: 0.33,
            cacheWrite5mPerMillion: 2.063,
            cacheWrite1hPerMillion: 2.063,
            outputPerMillion: 4.951
        ),
        "qwen3.7-plus": TokenMeterPricing(
            inputPerMillion: 0.276,
            cacheReadPerMillion: 0.056,
            cacheWrite5mPerMillion: 0.344,
            cacheWrite1hPerMillion: 0.344,
            outputPerMillion: 1.101
        ),
        "qwen3.6-flash": TokenMeterPricing(
            inputPerMillion: 0.165,
            cacheReadPerMillion: 0.017,
            cacheWrite5mPerMillion: 0.206,
            cacheWrite1hPerMillion: 0.206,
            outputPerMillion: 0.99
        ),
        "glm-5.2": TokenMeterPricing(
            inputPerMillion: 1.10,
            cacheReadPerMillion: 0.275,
            cacheWrite5mPerMillion: 1.10,
            cacheWrite1hPerMillion: 1.10,
            outputPerMillion: 3.851
        ),
        "qwen": TokenMeterPricing(
            inputPerMillion: 0.276,
            cacheReadPerMillion: 0.056,
            cacheWrite5mPerMillion: 0.344,
            cacheWrite1hPerMillion: 0.344,
            outputPerMillion: 1.101
        ),

        // Free / local models — priced at $0 so they show as $0 instead of
        // "price missing".
        "tencent/hy3:free": TokenMeterPricing(
            inputPerMillion: 0.0,
            cacheReadPerMillion: 0.0,
            cacheWrite5mPerMillion: 0.0,
            cacheWrite1hPerMillion: 0.0,
            outputPerMillion: 0.0
        ),
        "deepseek-v4-flash-free": TokenMeterPricing(
            inputPerMillion: 0.0,
            cacheReadPerMillion: 0.0,
            cacheWrite5mPerMillion: 0.0,
            cacheWrite1hPerMillion: 0.0,
            outputPerMillion: 0.0
        ),
        "qwen3.6-35b-a3b": TokenMeterPricing(
            inputPerMillion: 0.0,
            cacheReadPerMillion: 0.0,
            cacheWrite5mPerMillion: 0.0,
            cacheWrite1hPerMillion: 0.0,
            outputPerMillion: 0.0
        ),

        // xAI rates used by TokenMeter's total-only Grok adapter.
        "grok-4.5": TokenMeterPricing(
            inputPerMillion: 2.0,
            cacheReadPerMillion: 0.30,
            outputPerMillion: 6.0
        ),
        "grok-build-0.1": TokenMeterPricing(
            inputPerMillion: 1.0,
            cacheReadPerMillion: 0.20,
            outputPerMillion: 2.0
        ),
        "grok-4.3": TokenMeterPricing(
            inputPerMillion: 1.25,
            cacheReadPerMillion: 0.20,
            outputPerMillion: 2.50
        ),
        "grok": TokenMeterPricing(
            inputPerMillion: 2.0,
            cacheReadPerMillion: 0.30,
            outputPerMillion: 6.0
        ),
    ])
}

// MARK: - Usage records

/// Input tokens include cache reads and cache writes, matching TokenMeter's
/// definition of billed input. A total-only record is used for Grok's log
/// format and is always marked as an estimate when priced.
public struct TokenUsage: Equatable, Sendable {
    public var inputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheWrite5mTokens: Int64
    public var cacheWrite1hTokens: Int64
    public var outputTokens: Int64
    private var totalOnlyTokens: Int64
    public private(set) var isSplit: Bool

    public var totalTokens: Int64 {
        inputTokens + outputTokens + totalOnlyTokens
    }

    public init(
        inputTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        cacheWrite5mTokens: Int64 = 0,
        cacheWrite1hTokens: Int64 = 0,
        outputTokens: Int64 = 0
    ) {
        self.inputTokens = max(0, inputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.cacheWrite5mTokens = max(0, cacheWrite5mTokens)
        self.cacheWrite1hTokens = max(0, cacheWrite1hTokens)
        self.outputTokens = max(0, outputTokens)
        self.totalOnlyTokens = 0
        self.isSplit = true
    }

    public static func totalOnly(_ totalTokens: Int64) -> TokenUsage {
        var usage = TokenUsage()
        usage.totalOnlyTokens = max(0, totalTokens)
        usage.isSplit = false
        return usage
    }

    public mutating func add(_ other: TokenUsage) {
        inputTokens += other.inputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWrite5mTokens += other.cacheWrite5mTokens
        cacheWrite1hTokens += other.cacheWrite1hTokens
        outputTokens += other.outputTokens
        totalOnlyTokens += other.totalOnlyTokens
        isSplit = isSplit && other.isSplit
    }
}

public struct TokenUsageEvent: Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let provider: TokenMeterProvider
    public let model: String?
    public let cwd: String?
    public let date: Date
    public let usage: TokenUsage
    public let actions: Int

    public init(
        id: String,
        sessionID: String,
        provider: TokenMeterProvider,
        model: String?,
        cwd: String?,
        date: Date,
        usage: TokenUsage,
        actions: Int = 0
    ) {
        self.id = id
        self.sessionID = sessionID
        self.provider = provider
        self.model = model
        self.cwd = cwd
        self.date = date
        self.usage = usage
        self.actions = max(0, actions)
    }
}

public struct TokenMeterSummary: Equatable, Sendable {
    public let usage: TokenUsage
    public let costUSD: Double?
    public let costIsEstimated: Bool
    public let hasUnpricedUsage: Bool
    public let sessions: Int
    public let actions: Int
    public let models: [String]

    public var hasUsage: Bool { usage.totalTokens > 0 }

    public init(
        usage: TokenUsage = TokenUsage(),
        costUSD: Double? = nil,
        costIsEstimated: Bool = false,
        hasUnpricedUsage: Bool = false,
        sessions: Int = 0,
        actions: Int = 0,
        models: [String] = []
    ) {
        self.usage = usage
        self.costUSD = costUSD
        self.costIsEstimated = costIsEstimated
        self.hasUnpricedUsage = hasUnpricedUsage
        self.sessions = sessions
        self.actions = actions
        self.models = models
    }
}

public struct TokenMeterSnapshot: Equatable, Sendable {
    public let generatedAt: Date
    public let overall: [UsageWindow: TokenMeterSummary]
    public let providers: [TokenMeterProvider: [UsageWindow: TokenMeterSummary]]
    public let agents: [AgentID: [UsageWindow: TokenMeterSummary]]
    public let ambiguousAttributionCount: Int

    public init(
        generatedAt: Date,
        overall: [UsageWindow: TokenMeterSummary],
        providers: [TokenMeterProvider: [UsageWindow: TokenMeterSummary]],
        agents: [AgentID: [UsageWindow: TokenMeterSummary]],
        ambiguousAttributionCount: Int = 0
    ) {
        self.generatedAt = generatedAt
        self.overall = overall
        self.providers = providers
        self.agents = agents
        self.ambiguousAttributionCount = ambiguousAttributionCount
    }

    public static let empty = TokenMeterSnapshot(
        generatedAt: .distantPast,
        overall: [:],
        providers: [:],
        agents: [:]
    )

    public func overallSummary(for window: UsageWindow) -> TokenMeterSummary {
        overall[window] ?? TokenMeterSummary()
    }

    public func providerSummary(
        for provider: TokenMeterProvider,
        window: UsageWindow
    ) -> TokenMeterSummary {
        providers[provider]?[window] ?? TokenMeterSummary()
    }

    public func agentSummary(
        for agentID: AgentID,
        window: UsageWindow
    ) -> TokenMeterSummary {
        agents[agentID]?[window] ?? TokenMeterSummary()
    }

    public func knownModels(for provider: TokenMeterProvider) -> [String] {
        Set(providers[provider]?.values.flatMap(\.models) ?? []).sorted()
    }
}
