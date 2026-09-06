import Foundation
import HerdrManagerCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Entry Point

@main
struct MCPServerMain {
    static func main() async {
        // Prevent SIGPIPE crashes when stdout reader disconnects
        signal(SIGPIPE, SIG_IGN)

        // Resolve herdr socket path
        let socketPath = LiveHerdrAdapter.resolveSocketPath()

        let adapter = LiveHerdrAdapter(socketPath: socketPath)
        let server = MCPServer(adapter: adapter)
        await server.run()
    }
}

// MARK: - Revalidation Errors

private enum MCPRevalidationError: Error, CustomStringConvertible {
    case paneGone(String)
    case occupantChanged(expected: String, current: String)
    case seqAdvanced(expected: UInt64, current: UInt64)
    case statusChanged(expected: String, current: String)
    case writesDisabled(String)

    var description: String {
        switch self {
        case .paneGone(let paneId):
            return "Pane \(paneId) no longer exists — occupant may have been replaced"
        case .occupantChanged(let expected, let current):
            return "Pane occupant changed since approval (expected: \(expected), current: \(current))"
        case .seqAdvanced(let expected, let current):
            return "State change seq advanced since approval (expected: \(expected), current: \(current))"
        case .statusChanged(let expected, let current):
            return "Agent status changed since approval (expected: \(expected), current: \(current))"
        case .writesDisabled(let reason):
            return "Writes not enabled: \(reason)"
        }
    }
}

private struct AgentResolutionError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Rate Limiter

actor RateLimiter {
    private var perAgent: [String: [Date]] = [:]
    private var globalTimestamps: [Date] = []

    private let perAgentLimit = 20
    private let globalLimit = 100
    private let window: TimeInterval = 60

    init() {}

    /// Check if a call is allowed. Returns (allowed, retrySeconds).
    func check(agentId: String? = nil) async -> (allowed: Bool, retrySeconds: Int) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-window)

        // Prune old entries
        globalTimestamps.removeAll { $0 < cutoff }
        if let agentId {
            perAgent[agentId]?.removeAll { $0 < cutoff }
        }

        // Check global limit
        if globalTimestamps.count >= globalLimit {
            let oldest = globalTimestamps.first ?? now
            let retry = Int(oldest.addingTimeInterval(window).timeIntervalSince(now)) + 1
            return (false, max(retry, 1))
        }

        // Check per-agent limit
        if let agentId {
            let agentTimes = perAgent[agentId] ?? []
            if agentTimes.count >= perAgentLimit {
                let oldest = agentTimes.first ?? now
                let retry = Int(oldest.addingTimeInterval(window).timeIntervalSince(now)) + 1
                return (false, max(retry, 1))
            }
        }

        // Record
        globalTimestamps.append(now)
        if let agentId {
            perAgent[agentId, default: []].append(now)
        }

        return (true, 0)
    }
}

// MARK: - MCP Server

actor MCPServer {
    private let adapter: LiveHerdrAdapter
    private let redactor = SecretRedactor()
    private let rateLimiter = RateLimiter()
    private let diagnoser = Diagnoser()
    private let policy = PolicyEngine()
    private let journal = Journal()
    private let actionStore = ActionStore()
    private let sharedActionStore = SharedActionStore()

    // nonisolated(unsafe): only accessed from nonisolated writeResponse/writeRaw
    // which serialize via the lock.
    nonisolated(unsafe) private var stdoutLock = NSLock()

    init(adapter: LiveHerdrAdapter) {
        self.adapter = adapter
    }

    // MARK: - Run Loop

    func run() async {
        let (stream, continuation) = AsyncStream<String>.makeStream()

        // Read stdin on a detached task to avoid blocking the cooperative pool
        let stdinTask = Task.detached(priority: .userInitiated) {
            while let line = readLine() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    continuation.yield(trimmed)
                }
            }
            continuation.finish()
        }

        // Process each JSON-RPC line CONCURRENTLY. A long-running tools/call
        // (e.g. a 120s confirmation wait) must not block ping, reads, or
        // action.status. Each request runs in its own child task; responses are
        // id-correlated and stdout writes are serialized by stdoutLock, so
        // out-of-order responses are valid for JSON-RPC over stdio. The actor
        // serializes shared state and interleaves tasks at suspension points
        // (the confirmation poll sleeps, releasing the actor to serve others).
        for await line in stream {
            Task { await self.handleLine(line) }
        }

        stdinTask.cancel()
    }
