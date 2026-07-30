import Foundation

enum DwellFormatter {
    /// Format a dwell duration from `enteredAt` to now.
    /// Examples: "just now", "2m", "1h5m", "3h42m"
    static func format(enteredAt: Date) -> String {
        let interval = Date().timeIntervalSince(enteredAt)
        return format(interval: interval)
    }

    static func format(interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        guard totalSeconds > 0 else { return "now" }

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h\(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "\(totalSeconds)s"
        }
    }
}
