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

    /// The identity of what `format(interval:)` would print, as an integer.
    ///
    /// Two intervals with the same tick render the same text, so a caller can
    /// ask "would advancing my clock change anything?" without formatting —
    /// no strings built, no allocation, just the integer arithmetic the
    /// formatter was going to do anyway. The panel uses it to decide whether a
    /// clock tick is worth publishing: the alternative is re-rendering the
    /// whole panel to discover that nothing moved.
    ///
    /// The encoding mirrors the formatter's own granularity — seconds below a
    /// minute, whole minutes above it (hours are just minutes regrouped) —
    /// with the two ranges kept apart so no second can collide with a minute.
    static func displayTick(interval: TimeInterval) -> Int {
        let totalSeconds = Int(interval)
        guard totalSeconds > 0 else { return 0 }
        return totalSeconds < 60 ? totalSeconds : 60 + totalSeconds / 60
    }
}
