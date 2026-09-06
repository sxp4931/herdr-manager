import Foundation

// MARK: - HerdrAdapter Protocol

public protocol HerdrAdapter: Sendable {
    func snapshot() async throws -> HerdrSnapshot
    func read(paneId: String, source: PaneReadSource, lines: Int?) async throws -> PaneReadResult
    func explain(paneId: String) async throws -> AgentExplainResult
    func processInfo(paneId: String) async throws -> ProcessInfoResult
    func focus(paneId: String) async throws
    func events() -> AsyncStream<HerdrEvent>
    var connectionState: HerdrConnectionState { get }

    // MARK: - Write methods
    func sendKeys(paneId: String, keys: [String]) async throws
    func prompt(paneId: String, text: String) async throws
    func closePane(paneId: String) async throws
    func createWorkspace(cwd: String, label: String?) async throws -> WorkspaceCreation
    func startAgent(paneId: String, kind: String, name: String) async throws
    func waitStatus(paneId: String, until: [String], timeoutMs: Int) async throws -> Bool
    func reportMetadata(paneId: String, source: String, tokens: [String: String], ttlMs: Int) async throws
}

public extension HerdrAdapter {
    func read(paneId: String, source: PaneReadSource) async throws -> PaneReadResult {
        try await read(paneId: paneId, source: source, lines: nil)
    }
}

// MARK: - LiveHerdrAdapter

/// Two sockets, by design. `reqClient` carries request/response traffic
/// (snapshot, explain, reads, writes) — one short transaction at a time,
/// serialized inside the client. `subClient` is dedicated to the long-lived
/// `events.subscribe` stream and is NEVER used for requests. Sharing one socket
/// between a blocking event read-loop and concurrent requests raced two readers
/// on a single file descriptor, corrupting the NDJSON framing and flapping the
/// connection — which both stalled live updates and reflowed the menu bar.
public final class LiveHerdrAdapter: HerdrAdapter, @unchecked Sendable {
    private let reqClient: NDJSONClient
    private let subClient: NDJSONClient
    /// Dedicated serial queue for blocking socket I/O. Runs request transactions
    /// off the cooperative pool and off the main actor so a stalled herdr socket
    /// can never freeze the menu-bar UI or starve Swift concurrency's threads.
    /// Serial (like the client's txLock) so transactions never interleave.
    private let ioQueue = DispatchQueue(label: "HerdrManager.adapterIO", qos: .userInitiated)
    private let stateLock = NSLock()
    private var _connectionState: HerdrConnectionState = .disconnected
    private var _latestProtocolVersion: Int = 0
    private var eventContinuation: AsyncStream<HerdrEvent>.Continuation?
    private let eventStream: AsyncStream<HerdrEvent>
    private var eventLoopTask: Task<Void, Never>?

    public init(socketPath: String) {
        // Request client: bounded I/O timeout so a stalled herdr errors out
        // (.timeout) instead of blocking forever.
        self.reqClient = NDJSONClient(socketPath: socketPath, ioTimeoutSeconds: 30)
        // Subscription client: no timeout — the event stream is push-based and
        // legitimately blocks between events.
        self.subClient = NDJSONClient(socketPath: socketPath, ioTimeoutSeconds: 0)
        var continuation: AsyncStream<HerdrEvent>.Continuation?
        self.eventStream = AsyncStream { cont in
            continuation = cont
        }
        self.eventContinuation = continuation
    }

    /// Run blocking socket I/O on the dedicated `ioQueue`, off the cooperative
    /// pool and off the main actor. The body must do its own parsing and return
    /// a `Sendable` result so no non-Sendable value (e.g. `[String: Any]`)
    /// crosses the thread boundary. Combined with the socket-level timeouts, a
    /// hung herdr surfaces as `.timeout` rather than blocking indefinitely.
    private func onIO<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            ioQueue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
