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
