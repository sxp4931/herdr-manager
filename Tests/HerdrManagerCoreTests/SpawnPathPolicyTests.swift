import Foundation
import Testing
@testable import HerdrManagerCore

// MARK: - SpawnPathPolicy Tests

@Suite("SpawnPathPolicy.isValidSelectIndex")
struct SpawnPathPolicySelectIndexTests {

    @Test("Valid indices 0 and 20 are accepted")
    func validIndices() {
        #expect(SpawnPathPolicy.isValidSelectIndex(0))
        #expect(SpawnPathPolicy.isValidSelectIndex(20))
        #expect(SpawnPathPolicy.isValidSelectIndex(10))
    }

    @Test("Invalid indices -1 and 21 are rejected")
    func invalidIndices() {
        #expect(!SpawnPathPolicy.isValidSelectIndex(-1))
        #expect(!SpawnPathPolicy.isValidSelectIndex(21))
        #expect(!SpawnPathPolicy.isValidSelectIndex(100))
    }
}

@Suite("SpawnPathPolicy.isSupportedSpawnKind")
struct SpawnPathPolicySupportedKindTests {

    @Test("Supported kinds are accepted")
    func supportedKinds() {
        #expect(SpawnPathPolicy.isSupportedSpawnKind("claude"))
        #expect(SpawnPathPolicy.isSupportedSpawnKind("codex"))
        #expect(SpawnPathPolicy.isSupportedSpawnKind("opencode"))
        #expect(SpawnPathPolicy.isSupportedSpawnKind("aider"))
        #expect(SpawnPathPolicy.isSupportedSpawnKind("gemini"))
    }

    @Test("Unsupported kinds are rejected")
    func unsupportedKinds() {
        #expect(!SpawnPathPolicy.isSupportedSpawnKind("evil"))
        #expect(!SpawnPathPolicy.isSupportedSpawnKind("unknown"))
        #expect(!SpawnPathPolicy.isSupportedSpawnKind(""))
    }

    @Test("Case-insensitive matching")
    func caseInsensitive() {
        #expect(SpawnPathPolicy.isSupportedSpawnKind("CLAUDE"))
        #expect(SpawnPathPolicy.isSupportedSpawnKind("Claude"))
        #expect(SpawnPathPolicy.isSupportedSpawnKind("OPENCODE"))
    }
}

@Suite("SpawnPathPolicy.canonicalAgentName")
struct SpawnPathPolicyAgentNameTests {

    @Test("Normalizes a human-facing MCP name")
    func normalizesHumanFacingName() {
        let result = SpawnPathPolicy.canonicalAgentName(
            "Cuedora website media upgrade",
            fallback: "claude"
        )
        #expect(result == "cuedora-website-media-upgrade")
    }

    @Test("Prefixes names that do not start with a letter")
    func prefixesInvalidStart() {
        let result = SpawnPathPolicy.canonicalAgentName("5th pass", fallback: "claude")
        #expect(result == "agent-5th-pass")
    }

    @Test("Uses the fallback for an empty name and caps length")
    func fallbackAndLength() {
        #expect(SpawnPathPolicy.canonicalAgentName("  ", fallback: "claude") == "claude")

        let longName = String(repeating: "a", count: 64)
        let result = SpawnPathPolicy.canonicalAgentName(longName, fallback: "claude")
        #expect(result.count == 32)
        #expect(result.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
}

@Suite("SpawnPathPolicy.isPathWithinAllowedRoots")
struct SpawnPathPolicyPathTests {

    @Test("Path within allowed root is accepted")
    func pathWithinAllowedRoot() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let subDir = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let result = SpawnPathPolicy.isPathWithinAllowedRoots(
            subDir.path,
            allowedRoots: [tempDir.path]
        )
        #expect(result, "Subdirectory should be within allowed root")
    }

    @Test("Sibling path with similar prefix is rejected")
    func siblingPathRejected() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create /tmp/.../repo and /tmp/.../repo-evil
        let repoDir = tempDir.appendingPathComponent("repo")
        let evilDir = tempDir.appendingPathComponent("repo-evil")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: evilDir, withIntermediateDirectories: true)

        let result = SpawnPathPolicy.isPathWithinAllowedRoots(
            evilDir.path,
            allowedRoots: [repoDir.path]
        )
        #expect(!result, "Sibling path /repo-evil should NOT match allowed root /repo")
    }

    @Test("Nonexistent path is rejected")
    func nonexistentPathRejected() {
        let result = SpawnPathPolicy.isPathWithinAllowedRoots(
            "/nonexistent/path/that/does/not/exist",
            allowedRoots: ["/tmp"]
        )
        #expect(!result, "Nonexistent path should be rejected")
    }

    @Test("Path outside allowed roots is rejected")
    func pathOutsideAllowedRoots() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = SpawnPathPolicy.isPathWithinAllowedRoots(
            tempDir.path,
            allowedRoots: ["/some/other/root"]
        )
        #expect(!result, "Path outside allowed roots should be rejected")
    }

    @Test("Exact match of allowed root is accepted")
    func exactMatchAccepted() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = SpawnPathPolicy.isPathWithinAllowedRoots(
            tempDir.path,
            allowedRoots: [tempDir.path]
        )
        #expect(result, "Exact match of allowed root should be accepted")
    }
}

@Suite("Spawn brief")
struct SpawnBriefTests {

    @Test("Idle, working, and done may receive the brief")
    func sendsIntoALiveAgent() {
        #expect(SpawnBrief.readyStatuses == ["idle", "working", "done"])
        #expect(!SpawnBrief.readyStatuses.contains("blocked"))
        #expect(SpawnBrief.wakeStatuses == ["idle", "working", "done", "blocked"])
        for status in SpawnBrief.readyStatuses {
            #expect(SpawnBrief.outcome(brief: "fix the tests", status: status) == .send)
        }
    }

    @Test("A block does not receive Enter")
    func withholdsOnABlock() {
        #expect(SpawnBrief.outcome(brief: "fix the tests", status: "blocked") == .withhold(status: "blocked"))
        #expect(SpawnBrief.outcome(brief: " ", status: "blocked") == .withhold(status: "blocked"))
        #expect(SpawnBrief.outcome(brief: "fix the tests", status: "unknown") == .withhold(status: "unknown"))
        #expect(SpawnBrief.outcome(brief: "fix the tests", status: nil) == .withhold(status: ""))
        #expect(SpawnBrief.outcome(brief: "fix the tests", status: "Blocked") == .withhold(status: "Blocked"))
    }

    @Test("No brief is not a withhold")
    func absentBrief() {
        #expect(!SpawnBrief.isRequested(nil))
        #expect(!SpawnBrief.isRequested(""))
        #expect(SpawnBrief.isRequested(" "))
        #expect(SpawnBrief.outcome(brief: nil, status: "blocked") == .none)
        #expect(SpawnBrief.outcome(brief: "", status: "working") == .none)
        #expect(SpawnBrief.resultFields(for: .none) == "")
        #expect(SpawnBrief.journalPostState(for: .none) == "started")
    }

    @Test("The tool result does not interpolate the live status")
    func resultStaysJSON() {
        #expect(SpawnBrief.resultFields(for: .send) == ",\"briefSent\":true")
        #expect(
            SpawnBrief.resultFields(for: .withhold(status: "blocked"))
                == ",\"briefSent\":false,\"briefNotSent\":\"agent is blocked; a brief submits Enter and was not sent\""
        )
        #expect(
            SpawnBrief.resultFields(for: .withhold(status: "unknown"))
                == ",\"briefSent\":false,\"briefNotSent\":\"agent status is unknown; a brief submits Enter and was not sent\""
        )
        #expect(
            SpawnBrief.resultFields(for: .withhold(status: ""))
                == ",\"briefSent\":false,\"briefNotSent\":\"agent was not in the herd list; a brief submits Enter and was not sent\""
        )
        let hostile = "blocked\";\"started\":false"
        #expect(
            SpawnBrief.resultFields(for: .withhold(status: hostile))
                == ",\"briefSent\":false,\"briefNotSent\":\"agent is not idle, working, or done; a brief submits Enter and was not sent\""
        )
        #expect(!SpawnBrief.resultFields(for: .withhold(status: hostile)).contains(hostile))
        #expect(SpawnBrief.journalPostState(for: .send) == "started, brief sent")
        #expect(SpawnBrief.journalPostState(for: .withhold(status: "blocked")) == "started, brief withheld (blocked)")
        #expect(SpawnBrief.journalPostState(for: .withhold(status: "")) == "started, brief withheld (unlisted)")
        #expect(SpawnBrief.journalPostState(for: .withhold(status: hostile)) == "started, brief withheld (other)")
        #expect(SpawnBrief.journalStatusToken("done") == "done")
    }

    @Test("A brief longer than agent.say's cap is refused")
    func lengthCap() {
        #expect(SpawnBrief.maxCharacters == 2000)
        #expect(!SpawnBrief.exceedsLimit(""))
        #expect(!SpawnBrief.exceedsLimit(String(repeating: "a", count: 2000)))
        #expect(SpawnBrief.exceedsLimit(String(repeating: "a", count: 2001)))
    }

    @Test("A throw after the agent has started does not claim the brief was sent")
    func failureAfterStartStaysJSON() {
        let unread = SpawnBrief.resultFields(for: .unread)
        #expect(
            unread
                == ",\"briefSent\":false,\"briefNotSent\":\"the agent's status could not be read; a brief submits Enter and was not sent\""
        )
        #expect(
            SpawnBrief.resultFields(for: .writesClosed)
                == ",\"briefSent\":false,\"briefNotSent\":\"writes are not enabled; a brief submits Enter and was not sent\""
        )
        #expect(
            SpawnBrief.resultFields(for: .notConnected)
                == ",\"briefSent\":false,\"briefNotSent\":\"the prompt could not connect; a brief submits Enter and was not sent\""
        )
        let unconfirmed = SpawnBrief.resultFields(for: .unconfirmed)
        #expect(
            unconfirmed
                == ",\"briefSent\":false,\"briefNotSent\":\"the brief was not confirmed; it is not reported as sent\""
        )
        #expect(!unconfirmed.contains("was not sent"))

        for fields in [unread, SpawnBrief.resultFields(for: .writesClosed), SpawnBrief.resultFields(for: .notConnected), unconfirmed] {
            #expect(fields.filter { $0 == "\"" }.count == 6)
            #expect(!fields.contains("\\"))
        }

        #expect(SpawnBrief.journalPostState(for: .unread) == "started, brief withheld (unread)")
        #expect(SpawnBrief.journalPostState(for: .writesClosed) == "started, brief withheld (writes)")
        #expect(SpawnBrief.journalPostState(for: .notConnected) == "started, brief withheld (connect)")
        #expect(SpawnBrief.journalPostState(for: .unconfirmed) == "started, brief unconfirmed")
        #expect(!SpawnBrief.journalPostState(for: .unconfirmed).contains("\""))
    }

    @Test("A prompt failure is unconfirmed unless nothing was written")
    func promptFailureClassification() {
        #expect(
            SpawnBrief.outcome(forPromptFailure: NDJSONClientError.writesDisabled("older than 17"))
                == .writesClosed
        )
        #expect(
            SpawnBrief.outcome(forPromptFailure: NDJSONClientError.connectFailed("/tmp/herdr.sock", 61))
                == .notConnected
        )
        #expect(SpawnBrief.outcome(forPromptFailure: NDJSONClientError.socketCreationFailed(1)) == .notConnected)

        let inserted = NDJSONClientError.invalidResponse(
            "text was inserted, but Enter failed: socket I/O timed out"
        )
        #expect(SpawnBrief.outcome(forPromptFailure: inserted) == .unconfirmed)
        #expect(SpawnBrief.outcome(forPromptFailure: NDJSONClientError.invalidResponse("nope")) == .unconfirmed)
        #expect(SpawnBrief.outcome(forPromptFailure: NDJSONClientError.timeout) == .unconfirmed)
        #expect(SpawnBrief.outcome(forPromptFailure: NDJSONClientError.sendFailed(32)) == .unconfirmed)
        #expect(SpawnBrief.outcome(forPromptFailure: NDJSONClientError.readFailed(1)) == .unconfirmed)
        #expect(SpawnBrief.outcome(forPromptFailure: NDJSONClientError.connectionClosed) == .unconfirmed)

        struct Other: Error {}
        #expect(SpawnBrief.outcome(forPromptFailure: Other()) == .unconfirmed)

        let reported = SpawnBrief.resultFields(for: SpawnBrief.outcome(forPromptFailure: inserted))
        #expect(!reported.contains("timed out"))
        #expect(!reported.contains("inserted"))
        #expect(!reported.contains("/tmp/herdr.sock"))
    }
}
