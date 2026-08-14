import Foundation

enum DwellFormatter {
    /// Format a dwell duration. Examples: "now", "2m", "1h5m", "3h42m".
    ///
    /// Takes an interval rather than a start date on purpose. The convenience
    /// overload that read `Date()` for itself is gone: callers now hold a
    /// clock they control (the panel's `now`), and a formatter that silently
    /// samples its own would let a row's figure and its emphasis be timed from
    /// two different instants.
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
