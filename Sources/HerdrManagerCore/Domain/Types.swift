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
}

// MARK: - BlockKind

public enum BlockKind: String, Codable, Sendable, CaseIterable {
    case bashPermission = "bash_permission"
    case toolPermission = "tool_permission"
    case selectionForm = "selection_form"
    case workflowConfirm = "workflow_confirm"
    case menu
    case approval
    case probableApproval = "probable_approval"
    case unknownBlock = "unknown_block"

    /// Map from herdr matched_rule.id strings to BlockKind.
    public static func from(ruleId: String) -> BlockKind {
        switch ruleId {
        case "bash_permission_prompt": return .bashPermission
        case "generic_permission_prompt": return .toolPermission
        case "live_blocked_form": return .selectionForm
        case "dynamic_workflow_prompt": return .workflowConfirm
        case "model_picker_menu": return .menu
        case "live_strong_blocker", "osc_title_blocked": return .approval
        case "weak_blocker": return .probableApproval
        default: return .unknownBlock
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
        cwd: String = ""
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
    }
}

// MARK: - PaneReadSource

public enum PaneReadSource: String, Sendable {
    case visible
    case recent
    case recentUnwrapped = "recent_unwrapped"
    case detection
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
    public let cmdline: String?
    public let cwd: String?

    public init(pid: Int32, name: String, argv0: String?, cmdline: String?, cwd: String?) {
        self.pid = pid
        self.name = name
        self.argv0 = argv0
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

        public init(paneId: String, workspaceId: String, tabId: String, agent: String?, agentStatus: String,
                    agentSession: AgentSession?, terminalTitleStripped: String?, stateChangeSeq: UInt64?,
                    cwd: String?, foregroundCwd: String?, revision: UInt64?) {
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
        launchPending: Bool
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

// MARK: - HerdSnapshot

/// A fully-resolved view of the herd: agents (from `agent.list`, the
/// authoritative source — plain shells are excluded) plus the workspace/tab
/// labels (from `session.snapshot`) needed to describe where each one lives.
public struct HerdSnapshot: Sendable {
    public let version: String
    public let `protocol`: Int
    public let agents: [HerdrAgentInfo]
    public let workspaceNames: [String: String]   // workspaceId -> label
    public let tabNames: [String: String]         // tabId -> label
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
        focusedPaneId: String?
    ) {
        self.version = version
        self.protocol = `protocol`
        self.agents = agents
        self.workspaceNames = workspaceNames
        self.tabNames = tabNames
        self.focusedWorkspaceId = focusedWorkspaceId
        self.focusedTabId = focusedTabId
        self.focusedPaneId = focusedPaneId
    }
}

// MARK: - HerdrEvent

public enum HerdrEvent: Sendable {
    case agentStatusChanged(paneId: String, agentStatus: String, stateChangeSeq: UInt64?)
    case paneCreated(paneId: String, workspaceId: String, tabId: String)
    case paneClosed(paneId: String)
    case paneMoved(paneId: String, workspaceId: String?, tabId: String?)
    /// The full state of one pane, as delivered by the real `pane_updated`
    /// event. Carries strictly more information than `agentStatusChanged`
    /// (the old, never-actually-fired, per-pane status subscription) and is
    /// also usable to derive a plain status transition.
    case paneUpdated(HerdrAgentInfo)
    case paneFocused(paneId: String, workspaceId: String?)
    case paneExited(paneId: String)
    /// Any workspace_*/tab_*/worktree_*/layout_updated event. These change
    /// labels, not agent state — the caller should resync via `herdSnapshot()`.
    case workspacesChanged
    case connected
    case disconnected
    /// An unrecognized or no-op event that should be silently dropped.
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
