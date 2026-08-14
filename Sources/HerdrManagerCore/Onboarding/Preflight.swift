import Foundation

// MARK: - Status

/// Outcome of one setup check. Colour, glyph, and word are resolved together
/// in the UI (`SetupFace`) so a new case cannot land without all three.
public enum PreflightStatus: String, Sendable, Equatable, CaseIterable {
    case checking
    case pass
    case warn
    case waiting
    case fail
}

// MARK: - Check

public struct PreflightCheck: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case herdrInstalled
        case herdrRunning
        case connected
        case protocolSupported
        case agentsVisible

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .herdrInstalled: return "herdr installed"
            case .herdrRunning: return "herdr running"
            case .connected: return "Shepherd connected"
            case .protocolSupported: return "Protocol supported"
            case .agentsVisible: return "Agents visible"
            }
        }
    }

    public let id: Kind
    public let title: String
    public let status: PreflightStatus
    /// Mono detail line: resolved path, protocol number, agent count. nil when
    /// there is nothing truthful to show. NEVER a placeholder.
    public let detail: String?
    /// One plain sentence, shown only when the check is not passing.
    public let explanation: String?
    /// Exact copyable shell command, or nil.
    public let remedyCommand: String?
    public let remedyURL: URL?

    public init(
        id: Kind,
        title: String,
        status: PreflightStatus,
        detail: String?,
        explanation: String?,
        remedyCommand: String?,
        remedyURL: URL?
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.explanation = explanation
        self.remedyCommand = remedyCommand
        self.remedyURL = remedyURL
    }
}

// MARK: - Report

public struct PreflightReport: Sendable, Equatable {
    public let checks: [PreflightCheck]
    public let generatedAt: Date

    public init(checks: [PreflightCheck], generatedAt: Date) {
        self.checks = checks
        self.generatedAt = generatedAt
    }

    /// The first check that is not `.pass` — the one the UI expands.
    public var firstUnresolved: PreflightCheck? {
        checks.first { $0.status != .pass }
    }

    public var allClear: Bool {
        checks.allSatisfy { $0.status == .pass }
    }

    /// In-flight placeholder: every check is `.checking`. Used by the UI
    /// while a run is underway so it never presents a prior report as current.
    public static func checking(generatedAt: Date = Date()) -> PreflightReport {
        PreflightReport(
            checks: PreflightCheck.Kind.allCases.map { kind in
                PreflightCheck(
                    id: kind,
                    title: kind.title,
                    status: .checking,
                    detail: nil,
                    explanation: nil,
                    remedyCommand: nil,
                    remedyURL: nil
                )
            },
            generatedAt: generatedAt
        )
    }
}

// MARK: - Environment

/// Injected so tests are deterministic — no real filesystem, no real socket,
/// no subprocesses.
public protocol PreflightEnvironment: Sendable {
    /// Absolute path of `name` if findable, plus whether it was found on the
    /// inherited PATH (false means it was only found by scanning well-known
    /// install locations).
    func locateExecutable(named name: String) async -> (path: String, onInheritedPath: Bool)?
    func fileExists(atPath path: String) -> Bool
    /// nil when a handshake could not be completed at all.
    func probeProtocol(socketPath: String) async -> Int?
}

// MARK: - Runner

public actor PreflightRunner {
    private let environment: any PreflightEnvironment
    private let socketPath: String
    private let supportedProtocols: ClosedRange<Int>

    public init(
        environment: any PreflightEnvironment,
        socketPath: String,
        supportedProtocols: ClosedRange<Int>
    ) {
        self.environment = environment
        self.socketPath = socketPath
        self.supportedProtocols = supportedProtocols
    }

    public func run(agentCount: Int) async -> PreflightReport {
        var checks: [PreflightCheck] = []

        let installed = await checkInstalled()
        checks.append(installed)

        let running = checkRunning()
        checks.append(running)

        // A missing socket cannot be handshaked. Warn (PATH) never blocks
        // later checks; fail on running does, because there is nothing
        // truthful to say about a handshake we did not attempt.
        guard running.status != .fail else {
            checks.append(contentsOf: Self.unevaluated(from: .connected))
            return PreflightReport(checks: checks, generatedAt: Date())
        }

        let probed = await environment.probeProtocol(socketPath: socketPath)
        let connected = checkConnected(protocolVersion: probed)
        checks.append(connected)

        guard connected.status != .fail, let proto = probed else {
            checks.append(contentsOf: Self.unevaluated(from: .protocolSupported))
            return PreflightReport(checks: checks, generatedAt: Date())
        }

        checks.append(checkProtocol(proto))
        checks.append(checkAgents(agentCount))
        return PreflightReport(checks: checks, generatedAt: Date())
    }

    // MARK: Individual checks

    private func checkInstalled() async -> PreflightCheck {
        let kind = PreflightCheck.Kind.herdrInstalled
        guard let found = await environment.locateExecutable(named: "herdr") else {
            return PreflightCheck(
                id: kind,
                title: kind.title,
                status: .fail,
                detail: nil,
                explanation: "Shepherd has nothing to watch without herdr. It runs your agent panes; Shepherd reads their state.",
                remedyCommand: "brew install herdr",
                remedyURL: URL(string: "https://herdr.dev")
            )
        }
        if found.onInheritedPath {
            return PreflightCheck(
                id: kind,
                title: kind.title,
                status: .pass,
                detail: found.path,
                explanation: nil,
                remedyCommand: nil,
                remedyURL: nil
            )
        }
        return PreflightCheck(
            id: kind,
            title: kind.title,
            status: .warn,
            detail: found.path,
            explanation: "herdr is installed at this path but is not on the PATH a Finder-launched app inherits. Shepherd found it anyway; commands you run in Terminal will work normally.",
            remedyCommand: nil,
            remedyURL: nil
        )
    }

    private func checkRunning() -> PreflightCheck {
        let kind = PreflightCheck.Kind.herdrRunning
        if environment.fileExists(atPath: socketPath) {
            return PreflightCheck(
                id: kind,
                title: kind.title,
                status: .pass,
                detail: socketPath,
                explanation: nil,
                remedyCommand: nil,
                remedyURL: nil
            )
        }
        return PreflightCheck(
            id: kind,
            title: kind.title,
            status: .fail,
            detail: socketPath,
            explanation: "herdr is installed but no session is running. Start it where your work lives.",
            remedyCommand: "herdr",
            remedyURL: nil
        )
    }

    private func checkConnected(protocolVersion: Int?) -> PreflightCheck {
        let kind = PreflightCheck.Kind.connected
        if protocolVersion != nil {
            return PreflightCheck(
                id: kind,
                title: kind.title,
                status: .pass,
                detail: nil,
                explanation: nil,
                remedyCommand: nil,
                remedyURL: nil
            )
        }
        return PreflightCheck(
            id: kind,
            title: kind.title,
            status: .fail,
            detail: socketPath,
            explanation: "The socket exists but Shepherd could not complete a handshake. herdr may be starting up, or the socket may be stale.",
            remedyCommand: "herdr status",
            remedyURL: nil
        )
    }

    private func checkProtocol(_ proto: Int) -> PreflightCheck {
        let kind = PreflightCheck.Kind.protocolSupported
        if supportedProtocols.contains(proto) {
            return PreflightCheck(
                id: kind,
                title: kind.title,
                status: .pass,
                detail: "protocol \(proto)",
                explanation: nil,
                remedyCommand: nil,
                remedyURL: nil
            )
        }
        let rangeText = Self.describe(supportedProtocols)
        return PreflightCheck(
            id: kind,
            title: kind.title,
            status: .warn,
            detail: "protocol \(proto)",
            explanation: "Shepherd speaks protocol \(rangeText); this herdr reports \(proto). Reading stays on; sending replies and stopping agents are disabled — read-only.",
            remedyCommand: "brew upgrade herdr",
            remedyURL: nil
        )
    }

    private func checkAgents(_ count: Int) -> PreflightCheck {
        let kind = PreflightCheck.Kind.agentsVisible
        if count > 0 {
            let noun = count == 1 ? "agent" : "agents"
            return PreflightCheck(
                id: kind,
                title: kind.title,
                status: .pass,
                detail: "\(count) \(noun)",
                explanation: nil,
                remedyCommand: nil,
                remedyURL: nil
            )
        }
        return PreflightCheck(
            id: kind,
            title: kind.title,
            status: .waiting,
            detail: nil,
            explanation: "Connected. Nothing is running yet. Start an agent in herdr and it appears here within a second.",
            remedyCommand: nil,
            remedyURL: nil
        )
    }

    /// Remaining checks that were not evaluated, in declaration order from
    /// `from` onward. `.waiting` rather than `.fail` or `.checking`: we did
    /// not look, so there is nothing truthful to report.
    private static func unevaluated(from start: PreflightCheck.Kind) -> [PreflightCheck] {
        let kinds = PreflightCheck.Kind.allCases
        guard let idx = kinds.firstIndex(of: start) else { return [] }
        return kinds[idx...].map { kind in
            PreflightCheck(
                id: kind,
                title: kind.title,
                status: .waiting,
                detail: nil,
                explanation: nil,
                remedyCommand: nil,
                remedyURL: nil
            )
        }
    }

    static func describe(_ range: ClosedRange<Int>) -> String {
        if range.upperBound == Int.max {
            return "\(range.lowerBound)+"
        }
        if range.lowerBound == range.upperBound {
            return "\(range.lowerBound)"
        }
        return "\(range.lowerBound)–\(range.upperBound)"
    }
}

// MARK: - System environment

/// Real filesystem / socket implementation. Does not spawn a login shell
/// and does not execute `herdr` itself.
public struct SystemPreflightEnvironment: PreflightEnvironment {
    public init() {}

    public func locateExecutable(named name: String) async -> (path: String, onInheritedPath: Bool)? {
        let env = ProcessInfo.processInfo.environment
        let inheritedPATH = env["PATH"] ?? ""
        for dir in inheritedPATH.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(name)
            if Self.isExecutableFile(atPath: candidate) {
                return (candidate, true)
            }
        }

        let home = env["HOME"] ?? NSHomeDirectory()
        let wellKnown = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            (home as NSString).appendingPathComponent(".local/bin"),
            "/usr/bin",
            "/bin",
        ]
        for dir in wellKnown {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if Self.isExecutableFile(atPath: candidate) {
                return (candidate, false)
            }
        }
        return nil
    }

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func probeProtocol(socketPath: String) async -> Int? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.handshake(socketPath: socketPath))
            }
        }
    }

    /// `isExecutableFile` is true for directories on Unix; we need a file.
    private static func isExecutableFile(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private static func handshake(socketPath: String) -> Int? {
        let client = NDJSONClient(socketPath: socketPath, ioTimeoutSeconds: 5)
        defer { client.closeSocket() }
        do {
            try client.connect()
            let result = try client.sendRead(method: "session.snapshot", params: [:])
            let snap = try LiveHerdrAdapter.parseSnapshot(result)
            return snap.protocol
        } catch {
            return nil
        }
    }
}
