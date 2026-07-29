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
            return "💀 Process gone"
        case .unclassifiable:
            return "❓ Unknown state"
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

public struct Agent: Sendable, Identifiable {
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
        tabName: String = ""
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
    public let `protocol`: String
    public let workspaces: [Workspace]
    public let tabs: [Tab]
    public let panes: [PaneInfo]
    public let focusedWorkspaceId: String?
    public let focusedTabId: String?
    public let focusedPaneId: String?

    public init(version: String, protocol: String, workspaces: [Workspace], tabs: [Tab], panes: [PaneInfo],
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

// MARK: - HerdrEvent

public enum HerdrEvent: Sendable {
    case agentStatusChanged(paneId: String, agentStatus: String, stateChangeSeq: UInt64?)
    case paneCreated(paneId: String, workspaceId: String, tabId: String)
    case paneClosed(paneId: String)
    case paneMoved(paneId: String, workspaceId: String?, tabId: String?)
    case connected
    case disconnected
}

// MARK: - HerdrConnectionState

public enum HerdrConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
}
