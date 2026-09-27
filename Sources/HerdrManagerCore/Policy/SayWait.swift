import Foundation

// MARK: - SayWait

/// Whether `agent.say` may wait after it submits text.
///
/// `wait_for` used to be forwarded to `agent.wait` only after
/// `agent.prompt` had already written the text and Enter. herdr matches
/// `until` exactly, so `Idle` is not `idle` and the call waits out
/// `timeout_ms`. `working` is a real status and settles while the turn
/// is still running. The tool's settled statuses are `idle`, `done`,
/// and `blocked`. A word herdr does not use does the same full wait,
/// and the tool then reports timeout.
///
/// The request socket stops a silent read after
/// `NDJSONClient.requestIOTimeoutSeconds`. A wait of that length or
/// longer loses the race and comes back as a socket error, which the
/// tool used to report as `agent.say failed` after the text was already
/// in the pane. The cap sits `socketMarginMs` under that budget so
/// herdr can answer `settled: false` first.
public enum SayWait: Sendable {

    /// Schema order. `working` and `unknown` are not settled results.
    public static let acceptedStatuses: [String] = [
        AgentStatus.idle.rawValue,
        AgentStatus.done.rawValue,
        AgentStatus.blocked.rawValue,
    ]

    /// The words a rejection lists.
    public static let statusWords = acceptedStatuses.joined(separator: ", ")

    /// How far under the request socket's silence budget a wait stays.
    /// The socket and herdr start their clocks a moment apart, and the
    /// response still has to arrive before the read gives up.
    public static let socketMarginMs = 5_000

    /// Longest `timeout_ms` passed to `agent.wait`.
    public static let maxTimeoutMs = NDJSONClient.requestIOTimeoutSeconds * 1_000 - socketMarginMs

    /// Used when a wait was asked for and `timeout_ms` was omitted or
    /// was not an integer. The previous default was 30000, which meets
    /// the socket.
    public static let defaultTimeoutMs = maxTimeoutMs

    public static let sentToken = "sent"
    public static let settledToken = "settled"
    public static let timeoutToken = "timeout"
    public static let waitFailedToken = "wait_failed"

    /// Fixed. The live socket error is not copied: it can contain a
    /// quote, and the result has to say the prompt was already submitted.
    public static let waitFailedNote = "prompt already sent; read the agent before sending it again"

    public enum Decision: Equatable, Sendable {
        /// No wait was asked for. `timeoutMs` is ignored, including a
        /// value that would be refused on a real wait.
        case none
        case wait(status: String, timeoutMs: Int)
        case blankStatus
        case unrecognizedStatus(String)
        case timeoutOutOfRange(Int)
    }

    /// `status` nil is the missing argument, including a non-string
    /// value the caller already failed to read as a string. An empty
    /// string is not that default.
    public static func decide(status: String?, timeoutMs: Int?) -> Decision {
        guard let status else { return .none }
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .blankStatus }
        let folded = trimmed.lowercased()
        guard acceptedStatuses.contains(folded) else {
            return .unrecognizedStatus(trimmed)
        }
        let timeout = timeoutMs ?? defaultTimeoutMs
        guard timeout >= 1, timeout <= maxTimeoutMs else {
            return .timeoutOutOfRange(timeout)
        }
        return .wait(status: folded, timeoutMs: timeout)
    }

    /// Nil when the say may proceed. Every other decision is a caller
    /// error and names that nothing was sent.
    public static func rejection(_ decision: Decision) -> String? {
        switch decision {
        case .none, .wait:
            return nil
        case .blankStatus:
            return invalidStatus("")
        case .unrecognizedStatus(let text):
            return invalidStatus(text)
        case .timeoutOutOfRange(let milliseconds):
            return "Invalid timeout_ms \(milliseconds). Must be from 1 to \(maxTimeoutMs). No input sent."
        }
    }

    public static func outcomeToken(settled: Bool) -> String {
        settled ? settledToken : timeoutToken
    }

    /// The `outcome` field, and the note that belongs on a wait which
    /// threw after the prompt. `token` is one of the constants above.
    public static func outcomeSuffix(for token: String) -> String {
        if token == waitFailedToken {
            return "\"outcome\":\"\(waitFailedToken)\",\"waitNote\":\"\(waitFailedNote)\""
        }
        return "\"outcome\":\"\(token)\""
    }

    private static func invalidStatus(_ text: String) -> String {
        "Invalid wait_for '\(text)'. Must be one of: \(statusWords). No input sent."
    }
}
