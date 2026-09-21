import Foundation
import Darwin

/// Minimal herdr stand-in on a temporary UNIX socket. Like herdr, every
/// connection answers one request line and is then closed (one-shot
/// sockets), so a `LiveHerdrAdapter` pointed at it reconnects per request.
/// Stopping one server and starting another on the same path is a herdr
/// restart as the client sees it: no request fails in between.
final class FakeHerdrServer: @unchecked Sendable {
    enum Reply: Sendable {
        /// `session.snapshot` reports this protocol; `agent.list` is empty.
        case protocolVersion(Int)
        /// Every request gets a JSON-RPC error with this message.
        case error(String)
    }

    struct SetupError: Error {
        let step: String
        let code: Int32
    }

    let path: String
    private let reply: Reply
    private let listenFd: Int32
    private let lock = NSLock()
    private var stopped = false
    private let finished = DispatchSemaphore(value: 0)

    /// A short `/tmp` path: `sun_path` is 104 bytes on macOS.
    static func temporaryPath() -> String {
        "/tmp/herdr-fake-\(UUID().uuidString.prefix(8)).sock"
    }

    init(path: String, reply: Reply) throws {
        // The client writes to sockets this server has already closed.
        signal(SIGPIPE, SIG_IGN)
        self.path = path
        self.reply = reply
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SetupError(step: "socket", code: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw SetupError(step: "path length", code: 0)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            pathBytes.withUnsafeBufferPointer { buf in
                UnsafeMutableRawPointer(ptr).copyMemory(
                    from: UnsafeRawPointer(buf.baseAddress!),
                    byteCount: pathBytes.count
                )
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw SetupError(step: "bind/listen", code: code)
        }
        self.listenFd = fd

        let thread = Thread { [self] in self.serve() }
        thread.name = "fake-herdr"
        thread.start()
    }

    /// Stop accepting, then remove the socket file the way a stopped herdr
    /// leaves nothing listening.
    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        guard !wasStopped else { return }
        finished.wait()
        close(listenFd)
        unlink(path)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Poll with a short timeout so `stop()` never has to interrupt a
    /// blocked `accept`.
    private func serve() {
        defer { finished.signal() }
        while !isStopped {
            var pfd = pollfd(fd: listenFd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&pfd, 1, 50) > 0 else { continue }
            let client = Darwin.accept(listenFd, nil, nil)
            guard client >= 0 else { continue }
            answerOneRequest(on: client)
            close(client)
        }
    }

    private func answerOneRequest(on client: Int32) {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !request.contains(0x0A) {
            let n = Darwin.read(client, &buffer, buffer.count)
            guard n > 0 else { return }
            request.append(contentsOf: buffer[0..<n])
        }
        guard let newline = request.firstIndex(of: 0x0A),
              let object = try? JSONSerialization.jsonObject(with: request[..<newline]),
              let dict = object as? [String: Any] else {
            return
        }
        var response: [String: Any] = ["id": dict["id"] ?? NSNull()]
        switch reply {
        case .protocolVersion(let version):
            response["result"] = Self.result(
                method: dict["method"] as? String ?? "",
                protocolVersion: version
            )
        case .error(let message):
            response["error"] = ["code": -32603, "message": message] as [String: Any]
        }
        guard var line = try? JSONSerialization.data(withJSONObject: response) else { return }
        line.append(0x0A)
        line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(client, base, raw.count)
        }
    }

    private static func result(method: String, protocolVersion: Int) -> [String: Any] {
        switch method {
        case "session.snapshot":
            return [
                "type": "session_snapshot",
                "snapshot": [
                    "version": "fake",
                    "protocol": protocolVersion,
                    "workspaces": [] as [[String: Any]],
                    "tabs": [] as [[String: Any]],
                    "panes": [] as [[String: Any]]
                ] as [String: Any]
            ]
        case "agent.list":
            return ["type": "agent_list", "agents": [] as [[String: Any]]]
        default:
            return ["type": "ok"]
        }
    }
}
