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
