import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - NDJSONClientError

public enum NDJSONClientError: Error, Sendable, CustomStringConvertible {
    case socketCreationFailed(Int32)
    case connectFailed(String, Int32)
    case sendFailed(Int32)
    case readFailed(Int32)
    case connectionClosed
    case invalidResponse(String)
    case timeout

    public var description: String {
        switch self {
        case .socketCreationFailed(let code):
            return "socket creation failed (errno \(code))"
        case .connectFailed(let path, let code):
            return "connect failed for \(path) (errno \(code))"
        case .sendFailed(let code):
            return "send failed (errno \(code))"
        case .readFailed(let code):
            return "read failed (errno \(code))"
        case .connectionClosed:
            return "connection closed"
        case .invalidResponse(let detail):
            return "invalid response: \(detail)"
        case .timeout:
            return "socket I/O timed out"
        }
    }
}

/// Bounded NDJSON framing. A missing newline or a multi-megabyte pane.read
/// used to grow `readBuffer` without limit and pin the menu-bar process.
enum NDJSONFraming {
    static let maxLineBytes = 4 * 1024 * 1024

    enum Outcome: Equatable {
        case line(Data)
        case needMore
        /// A complete line was present and discarded because it exceeded the cap.
        case skippedOversized
        /// The buffer exceeded the cap with no newline yet; caller must keep
        /// reading and discarding until a newline (or EOF).
        case stillSkipping
    }

    /// Pull one framed outcome out of `buffer`. `skipping` is true while an
    /// oversized line is being drained.
    static func consume(
        buffer: inout Data,
        skipping: inout Bool,
        maxBytes: Int = maxLineBytes
    ) -> Outcome {
        if skipping {
            if let newline = buffer.firstIndex(of: 0x0A) {
                if newline + 1 < buffer.endIndex {
                    buffer = Data(buffer[(newline + 1)...])
                } else {
                    buffer.removeAll(keepingCapacity: true)
                }
                skipping = false
                return .skippedOversized
            }
            buffer.removeAll(keepingCapacity: true)
            return .stillSkipping
        }

        if let newlineIdx = buffer.firstIndex(of: 0x0A) {
            let count = newlineIdx - buffer.startIndex + 1
            let line = Data(buffer[buffer.startIndex...newlineIdx])
            if newlineIdx + 1 < buffer.endIndex {
                buffer = Data(buffer[(newlineIdx + 1)...])
            } else {
                buffer.removeAll(keepingCapacity: true)
            }
            if count > maxBytes {
                return .skippedOversized
            }
            return .line(line)
        }

        if buffer.count > maxBytes {
            skipping = true
            buffer.removeAll(keepingCapacity: true)
            return .stillSkipping
        }
        return .needMore
    }
}

// MARK: - NDJSONClient

public final class NDJSONClient: @unchecked Sendable {
    private let socketPath: String
    /// Socket-level send/receive timeout in seconds. `0` disables the timeout
    /// (used by the dedicated subscription client, whose event stream is
    /// push-based and legitimately blocks between events). A positive value
    /// sets `SO_RCVTIMEO`/`SO_SNDTIMEO` so a stalled herdr surfaces as
    /// `.timeout` instead of blocking the caller forever.
    private let ioTimeoutSeconds: Int
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
    nonisolated(unsafe) private var skippingOversize = false
    nonisolated(unsafe) private var isConnected = false

    public init(socketPath: String, ioTimeoutSeconds: Int = 30) {
        self.socketPath = socketPath
        self.ioTimeoutSeconds = ioTimeoutSeconds
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

        var connectResult: Int32
        repeat {
            connectResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(s, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        } while connectResult < 0 && errno == EINTR

        guard connectResult == 0 else {
            close(s)
            throw NDJSONClientError.connectFailed(socketPath, errno)
        }

        fd = s
        isConnected = true
        readBuffer = Data()
        skippingOversize = false

        // Socket-level I/O timeout so a stalled herdr cannot block forever.
        // A timed-out read/write returns EAGAIN/EWOULDBLOCK, mapped to
        // `.timeout` in readLine/writeData below.
        if ioTimeoutSeconds > 0 {
            var tv = timeval(tv_sec: Int(ioTimeoutSeconds), tv_usec: Int32(0))
            _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    public func closeSocket() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        isConnected = false
        skippingOversize = false
        readBuffer = Data()
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
        } catch NDJSONClientError.sendFailed, NDJSONClientError.connectionClosed, NDJSONClientError.readFailed, NDJSONClientError.timeout {
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
    ///
    /// herdr's sockets are one-shot: it closes its end right after writing a
    /// response (see the SIGPIPE-handling comments at both CLI entry points).
    /// `sendRead` never surfaces this because it transparently reconnects and
    /// retries once on transport failure — safe for an idempotent read. A
    /// second write reusing the same connection right after a first has no
    /// such safety net and reliably fails with EPIPE: reproduced live by
    /// calling `focusWorkspace` immediately followed by `focus` (the Jump
    /// action's exact sequence) — the first write's response arrives fine,
    /// herdr closes the socket, and the second write's `send()` dies with
    /// `sendFailed(32)` before a single byte of the new request is ever
    /// written. Reconnecting unconditionally before every write closes that
    /// gap and is safe to do unconditionally (unlike retrying *after* a
    /// failed write): no bytes for the upcoming request have been sent yet,
    /// so there is nothing to double-execute.
    public func sendWrite(method: String, params: [String: Any]) throws -> [String: Any] {
        txLock.lock()
        defer { txLock.unlock() }
        closeSocket()
        try connect()
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
            let responseLine = try readLine(skipOversized: false)
            guard let responseDict = try JSONSerialization.jsonObject(with: responseLine) as? [String: Any] else {
                continue
            }
            if JSONNumber.matchesStringId(responseDict["id"], expected: id) {
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

    /// Send `events.subscribe` and block until herdr confirms it (or rejects
    /// it), THEN return the live event stream. This is deliberately synchronous
    /// and split from the read loop below: a caller that reports "connected"
    /// as soon as this call returns is reporting a *confirmed* subscription,
    /// not merely "a stream object exists" — the previous design conflated
    /// the two and reported `.connected` even when the subscribe request was
    /// about to fail (e.g. a subscription type missing a required `pane_id`),
    /// which is what caused the endless connect/disconnect flapping.
    public func subscribe(subscriptions: [String]) throws -> AsyncThrowingStream<Data, Error> {
        let params: [String: Any] = [
            "subscriptions": subscriptions.map { ["type": $0] }
        ]
        let result = try send(method: "events.subscribe", params: params)
        guard (result["type"] as? String) == "subscription_started" else {
            throw NDJSONClientError.invalidResponse("events.subscribe: unexpected response \(result)")
        }

        return AsyncThrowingStream { continuation in
            // Run the long-lived blocking read loop on a DEDICATED thread, not
            // the cooperative pool — an event stream blocks between events by
            // design, and parking that on a pool thread would starve Swift
            // concurrency. The subscription client uses ioTimeoutSeconds == 0
            // so these reads block until herdr pushes (no spurious timeouts).
            let thread = Thread {
                do {
                    while true {
                        let line = try self.readLine(skipOversized: true)
                        // Yield raw Data (Sendable) — consumer parses JSON
                        continuation.yield(line)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            thread.name = "herdr-subscribe"
            thread.start()
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
                    if errno == EINTR {
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw NDJSONClientError.timeout
                    }
                    throw NDJSONClientError.sendFailed(errno)
                }
                sent += n
            }
        }
    }

    /// Read one NDJSON line.
    ///
    /// `skipOversized` is true for the subscription stream: a huge or
    /// newline-less event is drained and dropped so it cannot look like a
    /// disconnect. Request/response traffic (`false`) still drains the
    /// oversized line so the next frame is aligned, then fails the call.
    private func readLine(skipOversized: Bool) throws -> Data {
        while true {
            lock.lock()
            let outcome = NDJSONFraming.consume(
                buffer: &readBuffer,
                skipping: &skippingOversize
            )
            lock.unlock()

            switch outcome {
            case .line(let data):
                return data
            case .skippedOversized:
                if skipOversized { continue }
                throw NDJSONClientError.invalidResponse(
                    "NDJSON line exceeded \(NDJSONFraming.maxLineBytes) bytes"
                )
            case .stillSkipping, .needMore:
                break
            }

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
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw NDJSONClientError.timeout
                }
                throw NDJSONClientError.readFailed(errno)
            }

            lock.lock()
            readBuffer.append(contentsOf: buf[0..<n])
            lock.unlock()
        }
    }
}
