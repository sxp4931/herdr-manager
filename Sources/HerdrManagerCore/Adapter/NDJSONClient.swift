import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - NDJSONClientError

public enum NDJSONClientError: Error, Sendable {
    case socketCreationFailed(Int32)
    case connectFailed(String, Int32)
    case sendFailed(Int32)
    case readFailed(Int32)
    case connectionClosed
    case invalidResponse(String)
    case timeout
}

// MARK: - NDJSONClient

public final class NDJSONClient: @unchecked Sendable {
    private let socketPath: String
    nonisolated(unsafe) private var fd: Int32 = -1
    private let lock = NSLock()
    // Serializes whole request/response transactions so two concurrent `send`
    // callers never interleave their write+read on the same socket (which would
    // append out-of-order byte chunks to `readBuffer` and corrupt framing).
    // `send`/`sendOnce` are synchronous (blocking I/O, no `await`), so holding
    // this non-async lock across them never crosses a suspension point.
    private let txLock = NSLock()
    nonisolated(unsafe) private var requestId: UInt64 = 0
    nonisolated(unsafe) private var readBuffer = Data()
    nonisolated(unsafe) private var isConnected = false

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        closeSocket()
    }

    // MARK: - Connection

    public func connect() throws {
        lock.lock()
        defer { lock.unlock() }

        if isConnected { return }

        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else {
            throw NDJSONClientError.socketCreationFailed(errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLen else {
            close(s)
            throw NDJSONClientError.connectFailed(socketPath, 0)
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            pathBytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: UnsafeRawPointer(buf.baseAddress!), byteCount: pathBytes.count)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(s, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            close(s)
            throw NDJSONClientError.connectFailed(socketPath, errno)
        }

        fd = s
        isConnected = true
        readBuffer = Data()
    }

    public func closeSocket() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        isConnected = false
    }

    public var connected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isConnected
    }

    // MARK: - Send & Receive

    private func nextRequestId() -> String {
        lock.lock()
        defer { lock.unlock() }
        requestId += 1
        return "\(requestId)"
    }

    /// Synchronous idempotent read: reconnect + retry once on transport failure.
    /// Safe because reads do not mutate herdr state. Must be called off the main
    /// actor (callers are in async contexts).
    public func sendRead(method: String, params: [String: Any]) throws -> [String: Any] {
        txLock.lock()
        defer { txLock.unlock() }
        do {
            return try sendOnce(method: method, params: params)
        } catch NDJSONClientError.sendFailed, NDJSONClientError.connectionClosed, NDJSONClientError.readFailed {
            // herdr closes the connection after each response (one-shot protocol).
            // Reconnect and retry once — safe for idempotent reads.
            closeSocket()
            try connect()
            return try sendOnce(method: method, params: params)
        }
    }

    /// Synchronous non-idempotent write: reconnect if needed but do NOT retry
    /// the send after bytes may have reached herdr, because a partial write
    /// could have already mutated state. Surface the error to the caller.
    /// Must be called off the main actor (callers are in async contexts).
    public func sendWrite(method: String, params: [String: Any]) throws -> [String: Any] {
        txLock.lock()
        defer { txLock.unlock() }
        do {
            return try sendOnce(method: method, params: params)
        } catch let originalError {
            // Transport broke — write may or may not have landed.
            // Reconnect so the next call has a live socket, but do NOT retry —
            // the original bytes may have been partially written.
            closeSocket()
            try? connect()
            throw originalError
        }
    }

    /// Backwards-compatible wrapper: idempotent read path. Prefer `sendRead` /
    /// `sendWrite` at call sites so the retry semantics are explicit.
    public func send(method: String, params: [String: Any]) throws -> [String: Any] {
        return try sendRead(method: method, params: params)
    }

    private func sendOnce(method: String, params: [String: Any]) throws -> [String: Any] {
        let id = nextRequestId()

        let request: [String: Any] = [
            "method": method,
            "params": params,
            "id": id
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: request)
        var line = jsonData
        line.append(0x0A) // newline

        try writeData(line)

        // Read lines until we get a response with matching id
        while true {
            let responseLine = try readLine()
            guard let responseDict = try JSONSerialization.jsonObject(with: responseLine) as? [String: Any] else {
                continue
            }
            if let responseId = responseDict["id"] as? String, responseId == id {
                if let error = responseDict["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw NDJSONClientError.invalidResponse(message)
                }
                if let result = responseDict["result"] as? [String: Any] {
                    return result
                }
                // Some responses may have the result at top level
                return responseDict
            }
            // Not our response — could be an event; skip for now
        }
    }

    public func subscribe(subscriptions: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let params: [String: Any] = [
                        "subscriptions": subscriptions.map { ["type": $0] }
                    ]
                    _ = try self.send(method: "events.subscribe", params: params)

                    // Now read events continuously
                    while true {
                        let line = try self.readLine()
                        // Yield raw Data (Sendable) — consumer parses JSON
                        continuation.yield(line)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Low-level I/O

    private func writeData(_ data: Data) throws {
        lock.lock()
        guard fd >= 0 else {
            lock.unlock()
            throw NDJSONClientError.connectionClosed
        }
        let currentFd = fd
        lock.unlock()

        try data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            let total = data.count
            while sent < total {
                let n = Darwin.write(currentFd, base.advanced(by: sent), total - sent)
                if n < 0 {
                    throw NDJSONClientError.sendFailed(errno)
                }
                sent += n
            }
        }
    }

    private func readLine() throws -> Data {
        while true {
            // Check if we already have a complete line in the buffer
            lock.lock()
            if let newlineIdx = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[readBuffer.startIndex...newlineIdx]
                // Safe slicing: if newlineIdx is the last index, (newlineIdx + 1) == endIndex
                // and readBuffer[endIndex...] is a valid empty slice
                let remaining = (newlineIdx + 1 < readBuffer.endIndex) 
                    ? Data(readBuffer[(newlineIdx + 1)...]) 
                    : Data()
                readBuffer = remaining
                lock.unlock()
                return Data(line)
            }
            lock.unlock()

            lock.lock()
            guard fd >= 0 else {
                lock.unlock()
                throw NDJSONClientError.connectionClosed
            }
            let currentFd = fd
            lock.unlock()

            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(currentFd, &buf, buf.count)
            if n == 0 {
                throw NDJSONClientError.connectionClosed
            }
            if n < 0 {
                throw NDJSONClientError.readFailed(errno)
            }
            
            lock.lock()
            readBuffer.append(contentsOf: buf[0..<n])
            lock.unlock()
        }
    }
}
