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
