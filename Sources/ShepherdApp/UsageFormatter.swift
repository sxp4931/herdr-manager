import Foundation
import HerdrManagerCore

enum UsageFormatter {
    static func tokens(_ value: Int64) -> String {
        let value = max(0, value)
        switch value {
        case 1_000_000_000...:
            return String(format: "%.2fB", Double(value) / 1_000_000_000.0)
        case 1_000_000...:
            return String(format: "%.2fM", Double(value) / 1_000_000.0)
        case 1_000...:
            return String(format: "%.1fk", Double(value) / 1_000.0)
        default:
            return "\(value)"
        }
    }

    /// Locale-aware currency with grouping. `String(format:)` has no grouping
    /// separator, so a $12,345.67 week rendered as "$12345.67" — hard to
    /// verify at a glance. Negative costs are impossible by construction, but
    /// clamp defensively so a bad log can never render a "-$" figure.
    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static func currency(_ value: Double) -> String {
        currencyFormatter.string(from: NSNumber(value: max(0, value)))
            ?? String(format: "$%.2f", value)
    }

    static func cost(_ summary: TokenMeterSummary) -> String {
        guard let value = summary.costUSD else { return "n/a" }
        let amount: String
        if value > 0 && value < 0.01 {
            amount = "<$0.01"
        } else {
            amount = currency(value)
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
