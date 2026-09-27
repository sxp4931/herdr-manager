import Foundation

// MARK: - AgentStatus

public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case working
    case blocked
    case done
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }
}

// MARK: - AgentKind

public enum AgentKind: Sendable, Equatable {
    case claude
    case codex
    case opencode
    case aider
    case gemini
    case custom(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw.lowercased() {
        case "claude": self = .claude
        case "codex": self = .codex
        case "opencode": self = .opencode
        case "aider": self = .aider
        case "gemini": self = .gemini
        default: self = .custom(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .claude: try container.encode("claude")
        case .codex: try container.encode("codex")
        case .opencode: try container.encode("opencode")
        case .aider: try container.encode("aider")
        case .gemini: try container.encode("gemini")
        case .custom(let s): try container.encode(s)
        }
    }

    /// Lowercase wire name, also used verbatim as the UI's row label.
    public var label: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        case .aider: return "aider"
        case .gemini: return "gemini"
        case .custom(let s): return s.lowercased()
        }
    }

    /// The runtime a row shows. `sessionAgent` wins when herdr named one.
    /// An empty string is not a name: a session object with the key omitted
    /// parses as `""`, and `.custom("")` is a different settings fingerprint
    /// from the detected kind, and a blank kind in the menu bar and herdmgr.
    /// `detected` is the non-empty `agent` the caller already accepted, or
    /// `"unknown"` when a snapshot had neither.
    public static func resolved(sessionAgent: String?, detected: String) -> AgentKind {
        .custom(AgentLabel.nonempty(sessionAgent) ?? detected)
    }
}

// MARK: - BlockKind

public enum BlockKind: String, Codable, Sendable, CaseIterable {
    case bashPermission = "bash_permission"
    case toolPermission = "tool_permission"
    case selectionForm = "selection_form"
    case workflowConfirm = "workflow_confirm"
    case menu
    case approval
    /// Enter accepts the highlighted row and Esc cancels. The next row is
    /// not "don't ask again", so `accept_once` does not apply.
    case confirmation
    case probableApproval = "probable_approval"
    case unknownBlock = "unknown_block"

    /// Map from herdr `matched_rule.id` to the prompt shape.
    ///
    /// A rule whose screen says Enter accepts the highlighted row and Esc
    /// cancels is `.confirmation`. `accept_once` (Down, then Enter) stays
    /// on the yes / don't-ask-again / no stack, where that next row is the
    /// remembered yes. A rule that says Enter selects is `.selectionForm`.
    /// A block whose key is `y` or Ctrl+C, or whose id is shared by screens
    /// that disagree about Enter, is `.probableApproval` and sends nothing.
    public static func from(ruleId: String) -> BlockKind {
        switch ruleId {
        case "bash_permission_prompt": return .bashPermission
        case "generic_permission_prompt": return .toolPermission
        case "live_blocked_form": return .selectionForm
        case "dynamic_workflow_prompt": return .workflowConfirm
        case "model_picker_menu": return .menu
        case "live_strong_blocker", "osc_title_blocked": return .approval
        case "weak_blocker": return .probableApproval

        // Enter confirms the highlighted row. Esc cancels.
        case "permission_required", "opencode_permission",
             "mcp_elicitation_prompt", "trust_directory", "startup_update",
             "apply_or_allow_change", "current_approval_panel", "legacy_approval_panel",
             "dangerous_command_approval", "clarification_prompt", "tool_confirmation",
             "permission_scope_selector", "workspace_trust_blocked", "blocked_approval",
             "plan_complete_form":
            return .confirmation

        // Enter selects. Esc cancels. `question_panel` is both Kimi and Kiro.
        case "execute_selection_blocker", "selection_menu_blocker", "selection_blocker",
             "question_panel", "question_dialog", "command_approval":
            return .selectionForm

        // Read-only. `permission_prompt` is one id for three agents, and on
        // one of them Enter denies. Cursor's key is `y`. Grok's cancel on
        // these screens is Ctrl+C, and Esc unselects the question dialog.
        case "legacy_no_prompt_blocker",
             "write_file_approval", "approval_prompt",
             "option_dialog_blocked", "permission_hints_blocked", "question_dialog_hints_blocked",
             "waiting_for_confirmation", "folder_trust_dialog", "confirmation_prompt",
             "permission_prompt", "pick_request_blocked", "workspace_trust_prompt",
             "approval_footer", "osc_title_plugin_confirmation_blocked",
             "tool_approval", "tool_approval_edit", "crew_approval",
             "tool_permission", "inline_tool_permission":
            return .probableApproval

        default: return .unknownBlock
        }
    }

    /// Keystrokes for one MCP `agent.answer` choice, or nil when this
    /// prompt shape does not take that choice. Nil sends nothing.
    ///
    /// `select` repeats Down `index` times, then Enter. A missing index is
    /// the highlighted row. A negative index is refused: `Array(repeating:count:)`
    /// traps on a negative count, and it is not a menu position.
    public func answerKeys(forChoice choice: String, index: Int?) -> [String]? {
        switch self {
        case .unknownBlock, .probableApproval:
            return nil
        case .bashPermission, .toolPermission, .approval, .workflowConfirm:
            switch choice {
            case "approve": return ["enter"]
            case "accept_once": return ["down", "enter"]
            case "deny", "cancel": return ["esc"]
            default: return nil
            }
        case .selectionForm, .menu, .confirmation:
            switch choice {
            case "select":
                let idx = index ?? 0
                guard idx >= 0 else { return nil }
                return Array(repeating: "down", count: idx) + ["enter"]
            case "approve": return ["enter"]
            case "cancel", "deny": return ["esc"]
            default: return nil
            }
        }
    }

    /// Human-readable summary for UI display.
    public var summary: String {
        switch self {
        case .bashPermission: return "bash permission prompt"
        case .toolPermission: return "tool permission prompt"
        case .selectionForm: return "selection form"
        case .workflowConfirm: return "workflow confirmation"
        case .menu: return "menu selection"
        case .approval: return "approval prompt"
        case .confirmation: return "confirmation prompt"
        case .probableApproval: return "probable approval"
        case .unknownBlock: return "unknown block"
        }
    }
}

// MARK: - BlockClassification

public struct BlockClassification: Sendable, Equatable {
    public let kind: BlockKind
    public let since: Date
    public let summary: String

    public init(kind: BlockKind, since: Date, summary: String) {
        self.kind = kind
        self.since = since
        self.summary = summary
    }
}

// MARK: - CPUState

public enum CPUState: String, Sendable, Equatable {
    case thinking    // high CPU (>50%)
    case deadlocked  // near-zero CPU (<1%)
    case ioWait      // blocked on I/O
    case unknown

    /// Classify CPU usage percentage into a CPUState.
    public static func from(cpuPercent: Double) -> CPUState {
        if cpuPercent > 50.0 { return .thinking }
        if cpuPercent < 1.0 { return .deadlocked }
        return .ioWait
    }
}

// MARK: - ReasonTone

/// Drives the colour of a verdict's reason line in the UI.
public enum ReasonTone: Sendable, Equatable {
    case danger  // needs you now (blocked / process gone)
    case warn    // worth a look (silent)
    case info    // informational
    case neutral // no strong signal
}

// MARK: - Verdict

public enum Verdict: Sendable, Equatable {
    case healthy
    case awaitingInput(BlockClassification)
    case silent(since: Date, cpu: CPUState?)
    case processGone(lastLine: String?)
    case unclassifiable(reason: String)

    // MARK: Convenience accessors

    public var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }

    public var isSilent: Bool {
        if case .silent = self { return true }
        return false
    }

    public var isProcessGone: Bool {
        if case .processGone = self { return true }
        return false
    }

    public var isAwaitingInput: Bool {
        if case .awaitingInput = self { return true }
        return false
    }

    public var isUnclassifiable: Bool {
        if case .unclassifiable = self { return true }
        return false
    }

    /// Short human-readable summary for UI display.
    public var summaryLine: String? {
        switch self {
        case .healthy:
            return nil
        case .awaitingInput(let classification):
            return "⏳ Waiting: \(classification.summary)"
        case .silent(let since, let cpu):
            let elapsed = Self.formatElapsed(since: since)
            let cpuHint: String
            switch cpu {
            case .thinking: cpuHint = "thinking"
            case .deadlocked: cpuHint = "deadlocked"
            case .ioWait: cpuHint = "i/o wait"
            case .unknown, .none: cpuHint = ""
            }
            if cpuHint.isEmpty {
                return "🔇 Silent for \(elapsed)"
            } else {
                return "🔇 Silent for \(elapsed) (\(cpuHint))"
            }
        case .processGone:
            return "⚠️ Process gone — pane returned to shell"
        case .unclassifiable:
            return "❓ Unknown state"
        }
    }

    /// Emoji-free, crafted reason line for the redesigned UI. The colour is
    /// driven separately by `reasonTone`, so the text stays clean.
    public var reasonText: String? {
        switch self {
        case .healthy:
            return nil
        case .awaitingInput(let classification):
            return "Waiting · \(classification.summary)"
        case .silent(let since, let cpu):
            let elapsed = Self.formatElapsed(since: since)
            switch cpu {
            case .thinking: return "Silent \(elapsed) · thinking hard"
            case .deadlocked: return "Silent \(elapsed) · low CPU, possibly stalled"
            case .ioWait: return "Silent \(elapsed) · i/o wait"
            case .unknown, .none: return "Silent \(elapsed) · no output"
            }
        case .processGone:
            return "Agent gone — pane is back to a shell"
        case .unclassifiable(let reason):
            return reason
        }
    }

    /// Colour tone for `reasonText`.
    public var reasonTone: ReasonTone {
        switch self {
        case .awaitingInput, .processGone: return .danger
        case .silent: return .warn
        case .unclassifiable: return .neutral
        case .healthy: return .neutral
        }
    }

    /// Simple elapsed time formatter (e.g., "7m", "1h5m").
    private static func formatElapsed(since date: Date) -> String {
        let totalSeconds = Int(Date().timeIntervalSince(date))
        guard totalSeconds > 0 else { return "0s" }
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

// MARK: - AgentID

public struct AgentID: Hashable, Sendable, Codable {
    public let raw: String

    public var workspaceId: String {
        let parts = raw.split(separator: ":", maxSplits: 1)
        return String(parts[0])
    }

    public var paneId: String {
        let parts = raw.split(separator: ":", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : ""
    }

    public init(_ raw: String) {
        self.raw = raw
    }

    public init(workspaceId: String, paneId: String) {
        self.raw = "\(workspaceId):\(paneId)"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.raw = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

// MARK: - Agent

public struct Agent: Sendable, Identifiable, Equatable {
    public static func == (lhs: Agent, rhs: Agent) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.name == rhs.name
            && lhs.displayName == rhs.displayName
            && lhs.status == rhs.status
            && lhs.stateChangeSeq == rhs.stateChangeSeq
            && lhs.enteredAt == rhs.enteredAt
            && lhs.lastOutputAt == rhs.lastOutputAt
            && lhs.verdict == rhs.verdict
            && lhs.workspaceName == rhs.workspaceName
            && lhs.tabName == rhs.tabName
            && lhs.cwd == rhs.cwd
            && lhs.sessionIdentity == rhs.sessionIdentity
    }

    public let id: AgentID
    public var kind: AgentKind
    public var name: String
    public var displayName: String
    public var status: AgentStatus
    public var stateChangeSeq: UInt64
    public var enteredAt: Date
    public var lastOutputAt: Date?
    public var verdict: Verdict
    public var workspaceName: String
    public var tabName: String
    public var cwd: String
    /// Who is in this pane, without the pane id. Nil when herdr has not
    /// named a session. Not part of the settings fingerprint: that string
    /// is the kind, and a relaunch matches an older dwell file by it.
    public var sessionIdentity: String?

    public init(
        id: AgentID,
        kind: AgentKind = .custom("unknown"),
        name: String = "",
        displayName: String = "",
        status: AgentStatus = .unknown,
        stateChangeSeq: UInt64 = 0,
        enteredAt: Date = Date(),
        lastOutputAt: Date? = nil,
        verdict: Verdict = .unclassifiable(reason: "not yet diagnosed"),
        workspaceName: String = "",
        tabName: String = "",
        cwd: String = "",
        sessionIdentity: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.displayName = displayName
        self.status = status
        self.stateChangeSeq = stateChangeSeq
        self.enteredAt = enteredAt
        self.lastOutputAt = lastOutputAt
        self.verdict = verdict
        self.workspaceName = workspaceName
        self.tabName = tabName
        self.cwd = cwd
        self.sessionIdentity = sessionIdentity
    }
}

// MARK: - PaneReadSource

/// herdr's `pane.read` source.
///
/// `agent.tail` defaults a missing argument to `detection`. A present
/// string has to be one of the four wire names. Blank and any other word
/// used to return the detection buffer, so a caller that asked for
/// scrollback read the screen herdr classifies on.
public enum PaneReadSource: String, Equatable, Sendable {
    case visible
    case recent
    case recentUnwrapped = "recent_unwrapped"
    case detection

    /// The words a rejection lists, in schema order.
    public static let wireNames = "visible, recent, recent_unwrapped, detection"

    public enum ArgumentParse: Equatable, Sendable {
        case parsed(PaneReadSource)
        /// The argument was present and is not one of the four wire names.
        /// Blank is included: omitting the argument is the default, and an
        /// empty string is not.
        case unrecognized(String)
    }

    /// Trim and case-fold. Nil is the documented default. An empty string
    /// is unrecognized, so it is not treated as that default.
    public static func parseArgument(_ raw: String?) -> ArgumentParse {
        guard let raw else { return .parsed(.detection) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unrecognized(trimmed) }
        guard let source = PaneReadSource(rawValue: trimmed.lowercased()) else {
            return .unrecognized(trimmed)
        }
        return .parsed(source)
    }
}

// MARK: - PaneReadResult

public struct PaneReadResult: Sendable {
    public let text: String
    public let source: String

    public init(text: String, source: String) {
        self.text = text
        self.source = source
    }
}

// MARK: - AgentExplainResult

public struct AgentExplainResult: Sendable {
    public let agent: String?
    public let state: String?
    public let matchedRuleId: String?
    public let matchedRulePriority: Int?
    public let screenDetectionSkipped: Bool

    public init(agent: String?, state: String?, matchedRuleId: String?, matchedRulePriority: Int? = nil, screenDetectionSkipped: Bool) {
        self.agent = agent
        self.state = state
        self.matchedRuleId = matchedRuleId
        self.matchedRulePriority = matchedRulePriority
        self.screenDetectionSkipped = screenDetectionSkipped
    }
}

// MARK: - ProcessInfoResult

public struct ProcessInfoResult: Sendable {
    public let shellPid: Int32?
    public let foregroundProcesses: [ForegroundProcess]

    public init(shellPid: Int32?, foregroundProcesses: [ForegroundProcess]) {
        self.shellPid = shellPid
        self.foregroundProcesses = foregroundProcesses
    }
}

// MARK: - ForegroundProcess

public struct ForegroundProcess: Sendable {
    public let pid: Int32
    public let name: String
    public let argv0: String?
    /// `pane.process_info`'s `argv`, when herdr sent one. Nil when the
    /// field was absent, empty, or not an array of strings. The crash
    /// check uses it to tell a shell that is launching an agent from the
    /// shell left behind after the agent exited.
    public let argv: [String]?
    public let cmdline: String?
    public let cwd: String?

    public init(
        pid: Int32,
        name: String,
        argv0: String?,
        cmdline: String?,
        cwd: String?,
        argv: [String]? = nil
    ) {
        self.pid = pid
        self.name = name
        self.argv0 = argv0
        self.argv = argv
        self.cmdline = cmdline
        self.cwd = cwd
    }
}

// MARK: - HerdrSnapshot

public struct HerdrSnapshot: Sendable {
    public let version: String
    public let `protocol`: Int
    public let workspaces: [Workspace]
    public let tabs: [Tab]
    public let panes: [PaneInfo]
    public let focusedWorkspaceId: String?
    public let focusedTabId: String?
    public let focusedPaneId: String?

    public init(version: String, protocol: Int, workspaces: [Workspace], tabs: [Tab], panes: [PaneInfo],
                focusedWorkspaceId: String?, focusedTabId: String?, focusedPaneId: String?) {
        self.version = version
        self.protocol = `protocol`
        self.workspaces = workspaces
        self.tabs = tabs
        self.panes = panes
        self.focusedWorkspaceId = focusedWorkspaceId
        self.focusedTabId = focusedTabId
        self.focusedPaneId = focusedPaneId
    }

    /// Label lookup that never traps on duplicate or empty ids from a
    /// malformed snapshot. Empty keys are dropped; later duplicates win.
    public static func uniqueNameMap(_ pairs: [(String, String)]) -> [String: String] {
        Dictionary(pairs.filter { !$0.0.isEmpty }, uniquingKeysWith: { _, last in last })
    }

    public var workspaceNameMap: [String: String] {
        Self.uniqueNameMap(workspaces.map { ($0.workspaceId, $0.name) })
    }

    public var tabNameMap: [String: String] {
        Self.uniqueNameMap(tabs.map { ($0.tabId, $0.name) })
    }

    public struct Workspace: Sendable {
        public let workspaceId: String
        public let name: String

        public init(workspaceId: String, name: String) {
            self.workspaceId = workspaceId
            self.name = name
        }
    }

    public struct Tab: Sendable {
        public let tabId: String
        public let workspaceId: String
        public let name: String

        public init(tabId: String, workspaceId: String, name: String) {
            self.tabId = tabId
            self.workspaceId = workspaceId
            self.name = name
        }
    }

    public struct PaneInfo: Sendable {
        public let paneId: String
        public let workspaceId: String
        public let tabId: String
        public let agent: String?
        public let agentStatus: String
        public let agentSession: AgentSession?
        public let terminalTitleStripped: String?
        public let stateChangeSeq: UInt64?
        public let cwd: String?
        public let foregroundCwd: String?
        public let revision: UInt64?
        /// `herdr pane rename`. Nil when the snapshot omitted it.
        public let label: String?

        public init(paneId: String, workspaceId: String, tabId: String, agent: String?, agentStatus: String,
                    agentSession: AgentSession?, terminalTitleStripped: String?, stateChangeSeq: UInt64?,
                    cwd: String?, foregroundCwd: String?, revision: UInt64?, label: String? = nil) {
            self.paneId = paneId
            self.workspaceId = workspaceId
            self.tabId = tabId
            self.agent = agent
            self.agentStatus = agentStatus
            self.agentSession = agentSession
            self.terminalTitleStripped = terminalTitleStripped
            self.stateChangeSeq = stateChangeSeq
            self.cwd = cwd
            self.foregroundCwd = foregroundCwd
            self.revision = revision
            self.label = label
        }
    }

    public struct AgentSession: Sendable {
        public let source: String
        public let agent: String
        public let kind: String
        public let value: String

        public init(source: String, agent: String, kind: String, value: String) {
            self.source = source
            self.agent = agent
            self.kind = kind
            self.value = value
        }

        /// `source|agent|kind|value`, or nil when `value` is empty. The
        /// same string as `HerdrAgentInfo.sessionIdentity`.
        public var identity: String? {
            guard !value.isEmpty else { return nil }
            return "\(source)|\(agent)|\(kind)|\(value)"
        }
    }
}

// MARK: - HerdrAgentInfo

/// One agent as reported by herdr's `agent.list`. This is the source of truth
/// for "is this pane actually running an agent" and carries `stateChangeSeq`,
/// which plain `session.snapshot` panes do not.
public struct HerdrAgentInfo: Sendable, Equatable {
    public let paneId: String
    public let workspaceId: String
    public let tabId: String
    public let agent: String?            // detected agent kind, e.g. "claude"
    public let displayAgent: String?
    public let name: String?
    public let title: String?            // herdr-reported title (report_metadata)
    public let terminalTitleStripped: String?
    public let agentStatus: String
    public let agentSession: HerdrSnapshot.AgentSession?
    public let focused: Bool
    public let stateChangeSeq: UInt64
    public let cwd: String?
    public let foregroundCwd: String?
    public let revision: UInt64?
    public let tokens: [String: String]
    public let stateLabels: [String: String]
    public let interactiveReady: Bool
    public let launchPending: Bool
    /// `PaneInfo.label`: `herdr pane rename`. `agent.list` does not carry
    /// it. Nil means this payload omitted the field, not that the label
    /// was cleared — a session snapshot is what clears it.
    public let paneLabel: String?

    public init(
        paneId: String,
        workspaceId: String,
        tabId: String,
        agent: String?,
        displayAgent: String?,
        name: String?,
        title: String?,
        terminalTitleStripped: String?,
        agentStatus: String,
        agentSession: HerdrSnapshot.AgentSession?,
        focused: Bool,
        stateChangeSeq: UInt64,
        cwd: String?,
        foregroundCwd: String?,
        revision: UInt64?,
        tokens: [String: String],
        stateLabels: [String: String],
        interactiveReady: Bool,
        launchPending: Bool,
        paneLabel: String? = nil
    ) {
        self.paneId = paneId
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.agent = agent
        self.displayAgent = displayAgent
        self.name = name
        self.title = title
        self.terminalTitleStripped = terminalTitleStripped
        self.agentStatus = agentStatus
        self.agentSession = agentSession
        self.focused = focused
        self.stateChangeSeq = stateChangeSeq
        self.cwd = cwd
        self.foregroundCwd = foregroundCwd
        self.revision = revision
        self.tokens = tokens
        self.stateLabels = stateLabels
        self.interactiveReady = interactiveReady
        self.launchPending = launchPending
        self.paneLabel = paneLabel
    }

    /// Who is in this pane, for write revalidation. Prefers herdr's
    /// agent-session id (`source|agent|kind|value`) so two agents of the
    /// same kind in the same pane still differ. An empty session value is
    /// not that id. herdr omits `agent_session` when no native session is
    /// stored, and a present object whose value is `""` is the same
    /// observation. Treating the object as a session ignored the title, so
    /// two session-less occupants in one pane compared equal, and a list
    /// that included the empty object disagreed with one that left it off.
    /// That reset the answer cap and refused the write, or let the write
    /// through. Falls back to kind and title only when no session id is
    /// present. An empty title, name, or terminal title is not a label:
    /// herdr sends `""` for a cleared field, and treating it as present
    /// made this same occupant look new. `display_agent` stays out of this
    /// string. It is a presentation label, and the fingerprints already
    /// stored on pending actions do not include it. The pane label from
    /// `herdr pane rename` is the same kind of fact and stays out too.
    /// The string is the value stored on pending actions as `_fp_occupant`.
    /// The pane id is
    /// part of the string, so a cross-workspace move does not compare equal.
    /// A value that is only whitespace is still an id.
    public var occupantFingerprint: String {
        if let identity = agentSession?.identity {
            return "session|\(identity)|\(paneId)"
        }
        let kind = agent ?? "unknown"
        // Same absence rule as the row's name, minus `display_agent`.
        let label = AgentLabel.preferred(
            title: title,
            displayAgent: nil,
            name: name,
            terminalTitleStripped: terminalTitleStripped
        ) ?? kind
        return "fallback|\(kind)|\(label)|\(paneId)"
    }

    /// Session identity without the pane id. `occupantFingerprint` changes
    /// on a move; this is the part that stays put. An empty session value
    /// is not an identity: several panes look like that, and matching them
    /// would glue unrelated agents together.
    public var sessionIdentity: String? {
        agentSession?.identity
    }

    /// Directory a new tab or split should start in. The foreground
    /// directory wins, then the pane's cwd. An empty string is not a
    /// directory: herdr sends `""` for a cleared field, and `"" ??` the
    /// real cwd handed that empty string to `tab.create` and `pane.split`.
    public var workingDirectory: String? {
        AgentLabel.nonempty(foregroundCwd) ?? AgentLabel.nonempty(cwd)
    }

    public static func == (lhs: HerdrAgentInfo, rhs: HerdrAgentInfo) -> Bool {
        lhs.paneId == rhs.paneId
            && lhs.workspaceId == rhs.workspaceId
            && lhs.tabId == rhs.tabId
            && lhs.agent == rhs.agent
            && lhs.displayAgent == rhs.displayAgent
            && lhs.name == rhs.name
            && lhs.title == rhs.title
            && lhs.terminalTitleStripped == rhs.terminalTitleStripped
            && lhs.agentStatus == rhs.agentStatus
            && lhs.focused == rhs.focused
            && lhs.stateChangeSeq == rhs.stateChangeSeq
            && lhs.cwd == rhs.cwd
            && lhs.foregroundCwd == rhs.foregroundCwd
            && lhs.revision == rhs.revision
            && lhs.tokens == rhs.tokens
            && lhs.stateLabels == rhs.stateLabels
            && lhs.interactiveReady == rhs.interactiveReady
            && lhs.launchPending == rhs.launchPending
    }
}

// MARK: - AgentLabel

/// The one line the menu bar, herdmgr, and MCP use as an agent's name.
///
/// herdr's agents panel labels a row with the metadata `display_agent`,
/// then the name from `herdr agent rename` or `agent start`, then the
/// detected kind. The metadata `title` is a separate presentation string
/// (the pane border). This row has one line, so that title still leads
/// when a hook set it. The name from `herdr agent rename` is how the
/// agent is addressed, so it leads the pane label from `herdr pane
/// rename`. That label leads the stripped terminal title: the title
/// changes while the agent works, and the label is the name the person
/// set to tell two panes apart. An empty string is not a name: a cleared
/// field arrives as `""`, and treating it as present blanked the row.
public enum AgentLabel: Sendable {
    public static func preferred(
        title: String?,
        displayAgent: String?,
        name: String?,
        terminalTitleStripped: String?,
        paneLabel: String? = nil
    ) -> String? {
        nonempty(title)
            ?? nonempty(displayAgent)
            ?? nonempty(name)
            ?? nonempty(paneLabel)
            ?? nonempty(terminalTitleStripped)
    }

    public static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - SessionIdentity

/// Whether two observations name different occupants.
///
/// `HerdrAgentInfo.sessionIdentity` is the string. A nil or empty side is
/// not a change: `pane_updated` often omits `agent_session`, and the first
/// list that names one is still the occupant already on the row. Two
/// non-empty strings that differ are different occupants, including a value
/// that only continues the other (`abc` and `abc|extra`).
public enum SessionIdentity {
    public static func replaced(stored: String?, incoming: String?) -> Bool {
        guard let stored, !stored.isEmpty, let incoming, !incoming.isEmpty else {
            return false
        }
        return stored != incoming
    }

    /// The identity to keep after this observation. A named `incoming`
    /// wins. A read that leaves the field off keeps `stored`. Empty is
    /// not an identity, so it does not clear the one already stored.
    public static func carried(stored: String?, incoming: String?) -> String? {
        if let incoming, !incoming.isEmpty { return incoming }
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }
}

// MARK: - HerdSnapshot

/// A fully-resolved view of the herd: agents (from `agent.list`, the
/// authoritative source — plain shells are excluded) plus the workspace/tab
/// labels and pane labels (from `session.snapshot`) needed to describe
/// where each one lives and what the person named the pane.
public struct HerdSnapshot: Sendable {
    public let version: String
    public let `protocol`: Int
    public let agents: [HerdrAgentInfo]
    public let workspaceNames: [String: String]   // workspaceId -> label
    public let tabNames: [String: String]         // tabId -> label
    /// Nonempty `PaneInfo.label` values from the session snapshot.
    /// `agent.list` does not carry this field.
    public let paneLabels: [String: String]
    /// Pane ids the session snapshot listed. A listed id with no
    /// `paneLabels` entry has no manual label. Empty when this snapshot
    /// was built without one, which is not a clear.
    public let snapshotPaneIds: Set<String>
    public let focusedWorkspaceId: String?
    public let focusedTabId: String?
    public let focusedPaneId: String?

    public init(
        version: String,
        protocol: Int,
        agents: [HerdrAgentInfo],
        workspaceNames: [String: String],
        tabNames: [String: String],
        focusedWorkspaceId: String?,
        focusedTabId: String?,
        focusedPaneId: String?,
        paneLabels: [String: String] = [:],
        snapshotPaneIds: Set<String> = []
    ) {
        self.version = version
        self.protocol = `protocol`
        self.agents = agents
        self.workspaceNames = workspaceNames
        self.tabNames = tabNames
        self.paneLabels = paneLabels
        self.snapshotPaneIds = snapshotPaneIds
        self.focusedWorkspaceId = focusedWorkspaceId
        self.focusedTabId = focusedTabId
        self.focusedPaneId = focusedPaneId
    }

    /// Agents as the CLI and other snapshot clients should display them.
    /// Drops empty pane ids and plain shells; uses `agent.list`'s seq.
    public func displayAgents(now: Date = Date()) -> [Agent] {
        agents.compactMap { displayAgent(for: $0, now: now) }
    }

    /// The display row for one `agent.list` entry, labelled from this
    /// snapshot, or nil for a plain shell or an entry with no pane id.
    public func displayAgent(for info: HerdrAgentInfo, now: Date = Date()) -> Agent? {
        guard !info.paneId.isEmpty else { return nil }
        guard let agentKind = info.agent, !agentKind.isEmpty else { return nil }
        let kind = AgentKind.resolved(sessionAgent: info.agentSession?.agent, detected: agentKind)
        let name = AgentLabel.preferred(
            title: info.title,
            displayAgent: info.displayAgent,
            name: info.name,
            terminalTitleStripped: info.terminalTitleStripped,
            paneLabel: paneLabels[info.paneId]
        ) ?? agentKind
        let status = AgentStatus(rawValue: info.agentStatus) ?? .unknown
        return Agent(
            id: AgentID(info.paneId),
            kind: kind,
            name: name,
            displayName: name,
            status: status,
            stateChangeSeq: info.stateChangeSeq,
            enteredAt: now,
            lastOutputAt: nil,
            verdict: Self.displayVerdict(for: status, now: now),
            workspaceName: workspaceNames[info.workspaceId] ?? info.workspaceId,
            tabName: tabNames[info.tabId] ?? info.tabId,
            cwd: AgentLabel.nonempty(info.foregroundCwd) ?? AgentLabel.nonempty(info.cwd) ?? "",
            sessionIdentity: info.sessionIdentity
        )
    }

    /// The verdict a row shows for `status` before any diagnosis.
    static func displayVerdict(for status: AgentStatus, now: Date) -> Verdict {
        switch status {
        case .blocked:
            return .awaitingInput(BlockClassification(
                kind: .unknownBlock, since: now, summary: "blocked"
            ))
        case .unknown:
            return .unclassifiable(reason: "unknown status")
        case .idle, .working, .done:
            return .healthy
        }
    }
}

// MARK: - HerdrEvent

public enum HerdrEvent: Sendable {
    case agentStatusChanged(paneId: String, agentStatus: String, stateChangeSeq: UInt64?)
    case paneCreated(paneId: String, workspaceId: String, tabId: String)
    case paneClosed(paneId: String)
    /// A pane changed tabs or workspaces. Cross-workspace moves assign a new
    /// public id (`pane.paneId`) and do not emit close or create.
    /// `previousPaneId` is the id the row had; it is empty or equal to the
    /// new id when the id did not change. The created labels name a
    /// workspace or tab this move just made, which the last snapshot
    /// cannot know yet.
    case paneMoved(
        previousPaneId: String,
        pane: HerdrAgentInfo,
        createdWorkspaceLabel: String?,
        createdTabLabel: String?
    )
    /// The full state of one pane, as delivered by the real `pane_updated`
    /// event. Carries strictly more information than `agentStatusChanged`
    /// (the old, never-actually-fired, per-pane status subscription) and is
    /// also usable to derive a plain status transition.
    case paneUpdated(HerdrAgentInfo)
    case paneFocused(paneId: String, workspaceId: String?)
    case paneExited(paneId: String)
    /// `workspace.renamed`. The label is on the event. A herd refetch is how
    /// a created or closed container is learned; a rename does not need one,
    /// and the request socket can be down while this event is still arriving.
    case workspaceRenamed(workspaceId: String, label: String)
    /// `tab.renamed`. Same as a workspace rename: the label is already here.
    case tabRenamed(tabId: String, label: String)
    /// Any other workspace_*/tab_*/worktree_*/layout_updated event. These
    /// can add or drop a container — the caller should resync via
    /// `herdSnapshot()`. A rename is not in this case, and neither is a
    /// focus: `workspace_focused` and `tab_focused` do not change the set.
    case workspacesChanged
    case connected
    case disconnected
    /// An unrecognized event, or a container focus (`workspace_focused`,
    /// `tab_focused`). Neither changes a row. A layout refetch is
    /// `workspacesChanged`.
    case ignored
}

// MARK: - WorkspaceCreation

/// Result of a successful `workspace.create` call to herdr.
public struct WorkspaceCreation: Sendable, Codable, Equatable {
    public let workspaceId: String
    public let rootPaneId: String
    public let tabId: String?

    public init(workspaceId: String, rootPaneId: String, tabId: String? = nil) {
        self.workspaceId = workspaceId
        self.rootPaneId = rootPaneId
        self.tabId = tabId
    }
}

// MARK: - HerdrConnectionState

public enum HerdrConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
}
