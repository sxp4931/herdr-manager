import Foundation
import HerdrManagerCore

enum UsageFormatter {
    static func tokens(_ value: Int64) -> String {
        let value = max(0, value)
        switch value {
        case 1_000_000...:
            return String(format: "%.2fM", Double(value) / 1_000_000.0)
        case 1_000...:
            return String(format: "%.1fk", Double(value) / 1_000.0)
        default:
            return "\(value)"
        }
    }

    static func cost(_ summary: TokenMeterSummary) -> String {
        guard let value = summary.costUSD else { return "n/a" }
        let amount: String
        if value > 0 && value < 0.01 {
            amount = "<$0.01"
        } else {
            amount = String(format: "$%.2f", value)
        }
        let estimatePrefix = summary.costIsEstimated ? "~" : ""
        let partialSuffix = summary.hasUnpricedUsage ? " partial" : ""
        return "\(estimatePrefix)\(amount)\(partialSuffix)"
    }

    static func tokenBreakdown(_ summary: TokenMeterSummary) -> String {
        let usage = summary.usage
        if usage.isSplit {
            return "in \(tokens(usage.inputTokens)) · out \(tokens(usage.outputTokens))"
        }
        return "total \(tokens(usage.totalTokens))"
    }

    static func modelNames(_ summary: TokenMeterSummary) -> String? {
        guard !summary.models.isEmpty else { return nil }
        return summary.models.joined(separator: " · ")
    }
}
