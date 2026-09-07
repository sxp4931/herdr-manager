import Foundation
import Testing
@testable import HerdrManagerCore

// MARK: - AgentStatus Codable Tests

@Suite("AgentStatus Codable")
struct AgentStatusTests {
    @Test("Round-trip encode/decode for known statuses")
    func roundTrip() async throws {
        let statuses: [AgentStatus] = [.idle, .working, .blocked, .done, .unknown]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for status in statuses {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(AgentStatus.self, from: data)
            #expect(decoded == status)
        }
    }

    @Test("Decode from lowercase string")
    func decodeFromString() async throws {
        let json = #""blocked""#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AgentStatus.self, from: data)
        #expect(decoded == .blocked)
    }

    @Test("Unknown string maps to .unknown")
    func unknownString() async throws {
        let json = #""something_new""#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AgentStatus.self, from: data)
        #expect(decoded == .unknown)
    }
}

// MARK: - AgentID Tests

@Suite("AgentID")
struct AgentIDTests {
    @Test("Format workspaceId:paneId")
    func format() {
        let id = AgentID(workspaceId: "w5", paneId: "p1")
        #expect(id.raw == "w5:p1")
        #expect(id.workspaceId == "w5")
        #expect(id.paneId == "p1")
    }

    @Test("Parse from raw string")
    func parseRaw() {
        let id = AgentID("w3:p7")
        #expect(id.workspaceId == "w3")
        #expect(id.paneId == "p7")
    }

    @Test("Equality and hashing")
    func equality() {
        let a = AgentID("w1:p1")
        let b = AgentID(workspaceId: "w1", paneId: "p1")
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }
}

// MARK: - SecretRedactor Tests

@Suite("SecretRedactor")
struct SecretRedactorTests {
    @Test("Redacts OpenAI sk- keys")
    func redactsSkKey() {
        let redactor = SecretRedactor()
        let text = "my key is sk-abcdefghijklmnopqrstuvwxyz1234 ok"
        let result = redactor.redact(text)
        #expect(result.redactionCount >= 1)
        #expect(!result.redactedText.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        #expect(result.redactedText.contains("sk-[REDACTED]"))
    }

    @Test("Redacts GitHub tokens")
    func redactsGhp() {
        let redactor = SecretRedactor()
        let text = "token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let result = redactor.redact(text)
        #expect(result.redactionCount >= 1)
        #expect(!result.redactedText.contains("ghp_ABCDEF"))
    }

    @Test("Redacts AWS keys")
    func redactsAKIA() {
        let redactor = SecretRedactor()
        let text = "aws_key=AKIAIOSFODNN7EXAMPLE"
        let result = redactor.redact(text)
        #expect(result.redactionCount >= 1)
        #expect(!result.redactedText.contains("AKIAIOSFODNN7"))
    }

    @Test("Redacts Bearer tokens")
    func redactsBearer() {
        let redactor = SecretRedactor()
        let text = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.test.sig"
        let result = redactor.redact(text)
        #expect(result.redactionCount >= 1)
        #expect(result.redactedText.contains("Bearer [REDACTED]"))
    }

    @Test("No false positives on clean text")
    func cleanText() {
        let redactor = SecretRedactor()
        let text = "Hello world, this is a normal message."
        let result = redactor.redact(text)
        #expect(result.redactionCount == 0)
        #expect(result.redactedText == text)
    }

    @Test("Redacts xAI API keys")
    func redactsXAIKey() {
        let redactor = SecretRedactor()
        let text = "export XAI_API_KEY=xai-abcdefghijklmnopqrstuvwxyz0123456789"
        let result = redactor.redact(text)
        #expect(result.redactionCount >= 1)
        #expect(!result.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(result.redactedText.contains("xai-[REDACTED]"))
    }

    @Test("Redacts GitHub fine-grained PATs")
    func redactsGithubPat() {
        let redactor = SecretRedactor()
        let text = "token=github_pat_11AAAAAAA0123456789abcdefghijklmnopqrstuv"
        let result = redactor.redact(text)
        #expect(result.redactionCount >= 1)
        #expect(!result.redactedText.contains("11AAAAAAA0123456789"))
        #expect(result.redactedText.contains("github_pat_[REDACTED]") || result.redactedText.contains("token=[REDACTED]"))
    }

    @Test("Redacts Anthropic and OpenAI project keys that the generic sk- pattern misses")
    func redactsHyphenatedSkKeys() {
        let redactor = SecretRedactor()
        let ant = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCD"
        let proj = "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789ABCD"
        let result = redactor.redact("ant=\(ant) proj=\(proj)")
        #expect(result.redactionCount >= 2)
        #expect(!result.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
        #expect(result.redactedText.contains("sk-ant-[REDACTED]"))
        #expect(result.redactedText.contains("sk-proj-[REDACTED]"))
    }

    @Test("Redacts GitHub OAuth and App server tokens")
    func redactsGithubOAuthAndAppTokens() {
        let redactor = SecretRedactor()
        let gho = "gho_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let ghs = "ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let result = redactor.redact("oauth=\(gho) app=\(ghs)")
        #expect(result.redactionCount >= 2)
        #expect(!result.redactedText.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"))
        #expect(result.redactedText.contains("gho_[REDACTED]"))
        #expect(result.redactedText.contains("ghs_[REDACTED]"))
    }

    @Test("Redacts OpenAI service-account keys and GitHub user-to-server tokens")
    func redactsServiceAccountAndGithubUserTokens() {
        let redactor = SecretRedactor()
        let svc = "sk-svcacct-abcdefghijklmnopqrstuvwxyz0123456789ABCD"
        let ghu = "ghu_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let ghr = "ghr_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let result = redactor.redact("svc=\(svc) user=\(ghu) refresh=\(ghr)")
        #expect(result.redactionCount >= 3)
        #expect(!result.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
        #expect(!result.redactedText.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"))
        #expect(result.redactedText.contains("sk-svcacct-[REDACTED]"))
        #expect(result.redactedText.contains("ghu_[REDACTED]"))
        #expect(result.redactedText.contains("ghr_[REDACTED]"))
    }

    @Test("Redacts OpenRouter, Stripe, and Slack tokens the generic sk- pattern misses")
    func redactsOpenRouterStripeAndSlackTokens() {
        let redactor = SecretRedactor()
        // Build fixtures via concatenation so the file has no contiguous secret-shaped literals
        // (MCP/GitHub secret scanners block sk_live_ / xoxb- string literals).
        let openRouter = "sk" + "-or-v1-" + "abcdefghijklmnopqrstuvwxyz0123456789ABCD"
        let stripeLive = "sk" + "_live_" + "abcdefghijklmnopqrstuvwxyz0123"
        let slack = "xox" + "b-" + "123456789012-" + "abcdefghijklmnopqrstuvwx"
        let result = redactor.redact("or=\(openRouter) stripe=\(stripeLive) slack=\(slack)")
        #expect(result.redactionCount >= 3)
        #expect(!result.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
        #expect(!result.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123"))
        #expect(!result.redactedText.contains("abcdefghijklmnopqrstuvwx"))
        #expect(result.redactedText.contains("sk-or-[REDACTED]"))
        #expect(result.redactedText.contains("sk" + "_live_[REDACTED]"))
        #expect(result.redactedText.contains("xox[REDACTED]"))
    }
}

// MARK: - DwellTracker Tests

@Suite("DwellTracker")
struct DwellTrackerTests {
    @Test("Update and retrieve entry")
    func updateAndRetrieve() {
        let tracker = DwellTracker()
        let id = AgentID("w1:p1")
        let now = Date()
        tracker.update(agentId: id, status: .blocked, enteredAt: now, lastOutputAt: now)

        let entry = tracker.entry(for: id)
        #expect(entry != nil)
        #expect(entry?.status == .blocked)
    }

    @Test("Remove entry")
    func removeEntry() {
        let tracker = DwellTracker()
        let id = AgentID("w1:p1")
        tracker.update(agentId: id, status: .idle, enteredAt: Date(), lastOutputAt: nil)
        tracker.remove(agentId: id)
        #expect(tracker.entry(for: id) == nil)
    }
}

// MARK: - DwellTracker Persistence Tests

@Suite("DwellTracker persistence")
struct DwellTrackerPersistenceTests {

    @Test("save() then load(currentAgents:) round-trips entries")
    func saveAndLoadRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("dwell-state.json")

        let tracker1 = DwellTracker(fileURL: fileURL)
        let agentId = AgentID("w1:p1")
        let now = Date()
        tracker1.update(
            agentId: agentId,
            status: .working,
            enteredAt: now,
            lastOutputAt: now,
            occupantFingerprint: "claude",
            stateChangeSeq: 5
        )
        tracker1.save()

        // Create a new tracker and load
        let tracker2 = DwellTracker(fileURL: fileURL)
        let currentAgents: [AgentID: Agent] = [
            agentId: Agent(
                id: agentId,
                kind: .claude,
                status: .working,
                stateChangeSeq: 5
            )
        ]
        let restored = tracker2.load(currentAgents: currentAgents)
        #expect(restored.count == 1)

        let entry = tracker2.entry(for: agentId)
        #expect(entry != nil)
        #expect(entry?.status == .working)
        #expect(entry?.occupantFingerprint == "claude")
        #expect(entry?.stateChangeSeq == 5)

        // Cleanup
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Restore guard: fingerprint mismatch discards entry")
    func fingerprintMismatchDiscardsEntry() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("dwell-state.json")

        let tracker1 = DwellTracker(fileURL: fileURL)
        let agentId = AgentID("w1:p1")
        let now = Date()
        tracker1.update(
            agentId: agentId,
            status: .working,
            enteredAt: now,
            lastOutputAt: now,
            occupantFingerprint: "claude",
            stateChangeSeq: 5
        )
        tracker1.save()

        // Load with a different fingerprint (opencode instead of claude)
        let tracker2 = DwellTracker(fileURL: fileURL)
        let currentAgents: [AgentID: Agent] = [
            agentId: Agent(
                id: agentId,
                kind: .opencode, // Different kind!
                status: .working,
                stateChangeSeq: 5
            )
        ]
        let restored = tracker2.load(currentAgents: currentAgents)
        #expect(restored.count == 0, "Entry should be discarded when fingerprint doesn't match")
        #expect(tracker2.entry(for: agentId) == nil)

        // Cleanup
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Restore guard: stateChangeSeq mismatch discards entry")
    func stateChangeSeqMismatchDiscardsEntry() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("dwell-state.json")

        let tracker1 = DwellTracker(fileURL: fileURL)
        let agentId = AgentID("w1:p1")
        let now = Date()
        tracker1.update(
            agentId: agentId,
            status: .working,
            enteredAt: now,
            lastOutputAt: now,
            occupantFingerprint: "claude",
            stateChangeSeq: 5
        )
        tracker1.save()

        // Load with a different stateChangeSeq (10 instead of 5)
        let tracker2 = DwellTracker(fileURL: fileURL)
        let currentAgents: [AgentID: Agent] = [
            agentId: Agent(
                id: agentId,
                kind: .claude,
                status: .working,
                stateChangeSeq: 10 // Different seq!
            )
        ]
        let restored = tracker2.load(currentAgents: currentAgents)
        #expect(restored.count == 0, "Entry should be discarded when stateChangeSeq doesn't match")
        #expect(tracker2.entry(for: agentId) == nil)

        // Cleanup
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("load ignores an oversized dwell-state file")
    func loadRejectsOversize() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("dwell-state.json")
        try Data(repeating: 0x61, count: DwellTracker.maxFileBytes + 1).write(to: fileURL)

        let tracker = DwellTracker(fileURL: fileURL)
        let restored = tracker.load(currentAgents: [
            AgentID("w1:p1"): Agent(id: AgentID("w1:p1"), kind: .claude, status: .working)
        ])
        #expect(restored.isEmpty)
        #expect(tracker.entry(for: AgentID("w1:p1")) == nil)
    }

    @Test("save does not overwrite an oversized dwell-state file")
    func saveDoesNotWipeOversizedFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("dwell-state.json")
        let marker = Data(repeating: 0x61, count: DwellTracker.maxFileBytes + 1)
        try marker.write(to: fileURL)

        let tracker = DwellTracker(fileURL: fileURL)
        _ = tracker.load(currentAgents: [:])
        tracker.update(
            agentId: AgentID("w1:p1"),
            status: .working,
            enteredAt: Date(),
            lastOutputAt: nil,
            occupantFingerprint: "claude",
            stateChangeSeq: 1
        )
        tracker.save()
        let leftover = try Data(contentsOf: fileURL)
        #expect(leftover.count == marker.count)
    }
}
