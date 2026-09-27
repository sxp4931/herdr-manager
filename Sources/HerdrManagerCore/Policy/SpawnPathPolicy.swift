import Foundation

// MARK: - SpawnPathPolicy

/// Pure, unit-testable predicates for the MCP `session.spawn` safety gates.
///
/// These were originally inlined in `Sources/herdr-manager-mcp/main.swift` and
/// could not be exercised without a live MCP server. Extracted here so the
/// path-component allowlist, select-index bounds, and supported-kind checks
/// can be covered by regression tests.
public enum SpawnPathPolicy: Sendable {

    /// Supported agent kinds for `session.spawn`.
    public static let supportedKinds: Set<String> = [
        "aider", "claude", "codex", "gemini", "opencode"
    ]

    /// True iff `index` is a valid menu-select index (0...20 inclusive).
    public static func isValidSelectIndex(_ index: Int) -> Bool {
        return (0...20).contains(index)
    }

    /// True iff `kind` (case-insensitive) is a supported agent kind.
    public static func isSupportedSpawnKind(_ kind: String) -> Bool {
        return supportedKinds.contains(kind.lowercased())
    }

    /// Convert a human-facing MCP session name into the name grammar Herdr
    /// accepts for an agent: lowercase, starts with a letter, and contains
    /// only ASCII letters, digits, hyphens, or underscores (max 32 chars).
    public static func canonicalAgentName(_ name: String, fallback: String) -> String {
        var result = ""
        var previousWasSeparator = false

        for scalar in name.lowercased().unicodeScalars {
            let isLetter = scalar.value >= 97 && scalar.value <= 122
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            let isUnderscore = scalar.value == 95

            if isLetter || isDigit || isUnderscore {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !result.isEmpty && !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }

        while result.last == "-" {
            result.removeLast()
        }

        if result.isEmpty {
            result = fallback.lowercased()
        }

        if let first = result.unicodeScalars.first,
           !(first.value >= 97 && first.value <= 122) {
            result = "agent-" + result
        }

        result = String(result.prefix(32))
        while result.last == "-" {
            result.removeLast()
        }

        return result.isEmpty ? "agent" : result
    }

    /// True iff `path` resolves (with symlinks expanded) to a location that
    /// sits within one of the `allowedRoots`.
    ///
    /// Comparison is done on path **components**, not string prefixes, so a
    /// sibling like `/repo-evil` does NOT match an allowed root of `/repo`.
    /// The path must exist on disk (so symlink resolution is meaningful);
    /// nonexistent paths are rejected.
    public static func isPathWithinAllowedRoots(
        _ path: String,
        allowedRoots: [String]
    ) -> Bool {
        // Expand tilde and standardize, then resolve symlinks.
        let expanded = NSString(string: path).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        let resolvedURL = URL(fileURLWithPath: standardized).resolvingSymlinksInPath()
        let resolvedPath = resolvedURL.path

        // The path must exist and be a directory.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }

        let resolvedComponents = resolvedURL.pathComponents
        for allowedRoot in allowedRoots {
            let allowedComponents = URL(fileURLWithPath: allowedRoot).pathComponents
            guard resolvedComponents.count >= allowedComponents.count else { continue }
            var match = true
            for i in 0..<allowedComponents.count {
                if resolvedComponents[i] != allowedComponents[i] {
                    match = false
                    break
                }
            }
            if match { return true }
        }
        return false
    }
}

// MARK: - SpawnBrief

/// Whether `session.spawn`'s optional brief may be submitted.
///
/// The brief is delivered with `prompt`, which writes the text and then
/// Enter. `agent.say` will not do that on its own when the pane is
/// blocked: Enter accepts the highlighted row of a permission prompt.
/// A new agent is often blocked on trust or a startup approval before
/// it is idle. That status used to satisfy the startup wait, so the
/// brief answered a prompt the caller had not seen.
///
/// Idle, working, and done may still receive it. Working stays because
/// the brief is the first task, and a new agent is working while its
/// UI comes up. `agent.say` asks a person before typing into work that
/// is already underway; this brief is that first task. Blocked, unknown,
/// and a pane the list does not contain do not receive Enter.
///
/// A throw after `agent.start` has returned is not a failed spawn. The
/// wait and the herd list withholding Enter, a closed write gate, and a
/// prompt that does not finish are results on the pane that was started.
/// Failing the tool there hid that pane, and the caller started another.
public enum SpawnBrief: Sendable {

    /// Same cap as `agent.say`. A longer brief is a caller error and is
    /// refused before a pane is created.
    public static let maxCharacters = 2000

    /// Statuses the brief may be typed into.
    public static let readyStatuses: [String] = [
        AgentStatus.idle.rawValue,
        AgentStatus.working.rawValue,
        AgentStatus.done.rawValue,
    ]

    /// Statuses that end the startup wait. `blocked` is included so a
    /// permission prompt returns immediately. It is not a ready status:
    /// the list taken after the wait decides, and a block withholds Enter.
    public static let wakeStatuses: [String] = readyStatuses + [AgentStatus.blocked.rawValue]

    public enum Outcome: Equatable, Sendable {
        case none
        case send
        case withhold(status: String)
        /// The startup wait or the herd list threw. Enter was not sent.
        /// The agent is already running; failing the spawn would hide it.
        case unread
        /// The write gate refused before `prompt`. Enter was not sent.
        case writesClosed
        /// The text write never connected. Enter was not sent. An Enter
        /// failure after the text write is `.unconfirmed`: `prompt`
        /// throws `promptEnterFailed` for that, not a connect error.
        case notConnected
        /// `prompt` threw after the list said send. Enter's own failure
        /// is `promptEnterFailed`: the text is in the pane. A herdr
        /// rejection of the text write is still `invalidResponse`, and
        /// that case stays here too. An oversized success response is
        /// the same error, and calling it "not sent" would hide text
        /// that had already landed.
        case unconfirmed
    }

    /// Nil and `""` are no brief. Any other string, including whitespace,
    /// is a brief: Enter would still submit it.
    public static func isRequested(_ brief: String?) -> Bool {
        guard let brief else { return false }
        return !brief.isEmpty
    }

    public static func exceedsLimit(_ brief: String) -> Bool {
        brief.count > maxCharacters
    }

    /// `status` nil means the pane was not in the herd list. That withholds,
    /// with an empty status, rather than sending Enter to an id the list
    /// does not show.
    public static func outcome(brief: String?, status: String?) -> Outcome {
        guard isRequested(brief) else { return .none }
        let status = status ?? ""
        if readyStatuses.contains(status) {
            return .send
        }
        return .withhold(status: status)
    }

    /// Fixed phrases. The live status is not interpolated, so a pane
    /// status cannot break the tool's JSON.
    public static func skippedReason(status: String) -> String {
        switch status {
        case AgentStatus.blocked.rawValue:
            return "agent is blocked; a brief submits Enter and was not sent"
        case AgentStatus.unknown.rawValue:
            return "agent status is unknown; a brief submits Enter and was not sent"
        case "":
            return "agent was not in the herd list; a brief submits Enter and was not sent"
        default:
            return "agent is not idle, working, or done; a brief submits Enter and was not sent"
        }
    }

    /// Fixed phrases. A socket error is not copied: its path and herdr's
    /// message would break the JSON and can carry the text that was sent.
    public static func deliveryReason(_ outcome: Outcome) -> String? {
        switch outcome {
        case .none, .send:
            return nil
        case .withhold(let status):
            return skippedReason(status: status)
        case .unread:
            return "the agent's status could not be read; a brief submits Enter and was not sent"
        case .writesClosed:
            return "writes are not enabled; a brief submits Enter and was not sent"
        case .notConnected:
            return "the prompt could not connect; a brief submits Enter and was not sent"
        case .unconfirmed:
            return "the brief was not confirmed; it is not reported as sent"
        }
    }

    /// Classify a throw from `prompt` itself. The write gate and a connect
    /// that fails before the text write did not insert anything. Enter's
    /// failure is its own error, after the text write has returned, and
    /// the brief is not reported as sent. A herdr rejection of that text
    /// write is still `invalidResponse`. So is an oversized response
    /// line. Those stay unconfirmed: calling the rejection "not sent"
    /// would also call an oversized success "not sent".
    public static func outcome(forPromptFailure error: Error) -> Outcome {
        guard let client = error as? NDJSONClientError else {
            return .unconfirmed
        }
        switch client {
        case .writesDisabled:
            return .writesClosed
        case .connectFailed, .socketCreationFailed:
            return .notConnected
        case .promptEnterFailed, .invalidResponse, .timeout, .sendFailed, .readFailed, .connectionClosed:
            return .unconfirmed
        }
    }

    public static func resultFields(for outcome: Outcome) -> String {
        switch outcome {
        case .none:
            return ""
        case .send:
            return ",\"briefSent\":true"
        case .withhold, .unread, .writesClosed, .notConnected, .unconfirmed:
            guard let reason = deliveryReason(outcome) else { return "" }
            return ",\"briefSent\":false,\"briefNotSent\":\"\(reason)\""
        }
    }

    /// The tool result after `agent.start` has returned.
    ///
    /// `agentId`, `space`, and `tab` are herdr ids. The object is built by
    /// hand, and a quote, backslash, or control character in one of them
    /// ended it. The caller then had no pane id for an agent that was
    /// already running. `placement` and `actionId` are escaped the same
    /// way. A nil `tab` omits the field. An empty tab is still a value.
    /// Brief fields are appended unchanged: those phrases are fixed
    /// and contain no quote.
    public static func startedResult(
        agentId: String,
        space: String,
        placement: String,
        tab: String?,
        actionId: String,
        brief: Outcome
    ) -> String {
        var result = "{\"agentId\":\(quoted(agentId)),\"space\":\(quoted(space)),\"placement\":\(quoted(placement))"
        if let tab {
            result += ",\"tab\":\(quoted(tab))"
        }
        result += ",\"started\":true,\"actionId\":\(quoted(actionId))"
        result += resultFields(for: brief)
        result += "}"
        return result
    }

    /// A JSON string literal, including the surrounding quotes.
    private static func quoted(_ value: String) -> String {
        "\"\(ConfirmedPaneFollow.jsonEscaped(value))\""
    }

    /// A journal token for a withheld status. Only a real `AgentStatus`
    /// raw value is copied. Anything else, including a quote, is `other`.
    public static func journalStatusToken(_ status: String) -> String {
        if status.isEmpty { return "unlisted" }
        if let known = AgentStatus(rawValue: status) { return known.rawValue }
        return "other"
    }

    public static func journalPostState(for outcome: Outcome) -> String {
        switch outcome {
        case .none:
            return "started"
        case .send:
            return "started, brief sent"
        case .withhold(let status):
            return "started, brief withheld (\(journalStatusToken(status)))"
        case .unread:
            return "started, brief withheld (unread)"
        case .writesClosed:
            return "started, brief withheld (writes)"
        case .notConnected:
            return "started, brief withheld (connect)"
        case .unconfirmed:
            return "started, brief unconfirmed"
        }
    }
}
