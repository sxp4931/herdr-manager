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
        let rejected = SpawnBrief.resultFields(for: .rejected)
        #expect(
            rejected
                == ",\"briefSent\":false,\"briefNotSent\":\"herdr rejected the text write; the brief was not sent\""
        )
        #expect(rejected.contains("was not sent"))

        for fields in [
            unread,
            SpawnBrief.resultFields(for: .writesClosed),
            SpawnBrief.resultFields(for: .notConnected),
            unconfirmed,
            rejected
        ] {
            #expect(fields.filter { $0 == "\"" }.count == 6)
            #expect(!fields.contains("\\"))
        }

        #expect(SpawnBrief.journalPostState(for: .unread) == "started, brief withheld (unread)")
        #expect(SpawnBrief.journalPostState(for: .writesClosed) == "started, brief withheld (writes)")
        #expect(SpawnBrief.journalPostState(for: .notConnected) == "started, brief withheld (connect)")
        #expect(SpawnBrief.journalPostState(for: .unconfirmed) == "started, brief unconfirmed")
        #expect(!SpawnBrief.journalPostState(for: .unconfirmed).contains("\""))
        #expect(SpawnBrief.journalPostState(for: .rejected) == "started, brief withheld (rejected)")
        #expect(!SpawnBrief.journalPostState(for: .rejected).contains("\""))
    }

    @Test("A herdr rejection of the brief is not an oversized success line")
    func promptFailureClassification() throws {
        #expect(
            SpawnBrief.outcome(forPromptFailure: NDJSONClientError.writesDisabled("older than 17"))
                == .writesClosed
        )
        #expect(
            SpawnBrief.outcome(forPromptFailure: NDJSONClientError.connectFailed("/tmp/herdr.sock", 61))
                == .notConnected
        )
        #expect(SpawnBrief.outcome(forPromptFailure: NDJSONClientError.socketCreationFailed(1)) == .notConnected)

        let inserted = NDJSONClientError.promptEnterFailed
        #expect(SpawnBrief.outcome(forPromptFailure: inserted) == .unconfirmed)
        // The text write returned. Enter did not. That is not a rejection,
        // and the phrase still does not claim the text was inserted.
        #expect(SpawnBrief.outcome(forPromptFailure: NDJSONClientError.invalidResponse("nope")) == .rejected)
        #expect(SpawnBrief.outcome(forPromptFailure: NDJSONClientError.invalidResponse("pane not found")) == .rejected)
        #expect(SpawnBrief.outcome(forPromptFailure: NDJSONClientError.invalidResponse("herdr error -32601")) == .rejected)
        #expect(
            SpawnBrief.outcome(forPromptFailure: NDJSONClientError.invalidResponse("not NDJSON line exceeded 1 bytes"))
                == .rejected
        )
        let oversized = "\(NDJSONClientError.oversizedLineDetailPrefix)\(NDJSONFraming.maxLineBytes) bytes"
        #expect(SpawnBrief.outcome(forPromptFailure: NDJSONClientError.invalidResponse(oversized)) == .unconfirmed)
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
        #expect(!reported.contains("was not sent"))

        let rejection = SpawnBrief.resultFields(
            for: SpawnBrief.outcome(forPromptFailure: NDJSONClientError.invalidResponse("pane not found"))
        )
        #expect(rejection.contains("was not sent"))
        #expect(!rejection.contains("pane not found"))
        #expect(!rejection.contains("inserted"))

        let object = try JSONSerialization.jsonObject(with: Data(SpawnBrief.startedResult(
            agentId: "w\"1",
            space: "w1",
            placement: "new_tab",
            tab: "t2",
            actionId: "A1",
            brief: .rejected
        ).utf8)) as? [String: Any]
        #expect(object?["agentId"] as? String == "w\"1")
        #expect(object?["started"] as? Bool == true)
        #expect(object?["briefSent"] as? Bool == false)
        #expect(
            object?["briefNotSent"] as? String
                == "herdr rejected the text write; the brief was not sent"
        )
    }

    @Test("A quote in a herdr id stays inside the spawn result")
    func startedResultStaysJSON() throws {
        let plain = SpawnBrief.startedResult(
            agentId: "w1:p1",
            space: "w1",
            placement: "new_tab",
            tab: "t2",
            actionId: "A1",
            brief: .none
        )
        #expect(
            plain
                == "{\"agentId\":\"w1:p1\",\"space\":\"w1\",\"placement\":\"new_tab\",\"tab\":\"t2\",\"started\":true,\"actionId\":\"A1\"}"
        )
        #expect(!plain.contains("\\"))

        let split = SpawnBrief.startedResult(
            agentId: "w1:p1",
            space: "w1",
            placement: "split",
            tab: nil,
            actionId: "A1",
            brief: .send
        )
        #expect(
            split
                == "{\"agentId\":\"w1:p1\",\"space\":\"w1\",\"placement\":\"split\",\"started\":true,\"actionId\":\"A1\",\"briefSent\":true}"
        )
        #expect(!split.contains("\"tab\""))

        let emptyTab = SpawnBrief.startedResult(
            agentId: "w1:p1",
            space: "w1",
            placement: "new_workspace",
            tab: "",
            actionId: "A1",
            brief: .none
        )
        #expect(emptyTab.contains(",\"tab\":\"\""))

        let hostile = SpawnBrief.startedResult(
            agentId: "w\"1",
            space: "a\\b",
            placement: "new_tab\";\"started\":false",
            tab: "t\n2\t\u{0001}",
            actionId: "A\"1",
            brief: .withhold(status: "blocked\";\"started\":false")
        )
        let object = try JSONSerialization.jsonObject(with: Data(hostile.utf8)) as? [String: Any]
        #expect(object?["agentId"] as? String == "w\"1")
        #expect(object?["space"] as? String == "a\\b")
        #expect(object?["placement"] as? String == "new_tab\";\"started\":false")
        #expect(object?["tab"] as? String == "t\n2\t\u{0001}")
        #expect(object?["started"] as? Bool == true)
        #expect(object?["actionId"] as? String == "A\"1")
        #expect(object?["briefSent"] as? Bool == false)
        #expect(
            object?["briefNotSent"] as? String
                == "agent is blocked; a brief submits Enter and was not sent"
        )
    }
}

@Suite("SpawnLaunch")
struct SpawnLaunchTests {

    @Test("A start failure is not the same as a dropped response")
    func classifiesStart() {
        #expect(
            SpawnLaunch.miss(forStart: NDJSONClientError.writesDisabled("older than 17"))
                == .writesClosed
        )
        #expect(
            SpawnLaunch.miss(forStart: NDJSONClientError.connectFailed("/tmp/herdr.sock", 61))
                == .notConnected
        )
        #expect(SpawnLaunch.miss(forStart: NDJSONClientError.socketCreationFailed(1)) == .notConnected)

        #expect(SpawnLaunch.miss(forStart: NDJSONClientError.invalidResponse("pane not found")) == .rejected)
        #expect(SpawnLaunch.miss(forStart: NDJSONClientError.invalidResponse("herdr error -32601")) == .rejected)
        #expect(
            SpawnLaunch.miss(forStart: NDJSONClientError.invalidResponse("not NDJSON line exceeded 1 bytes"))
                == .rejected
        )

        let oversized = "\(NDJSONClientError.oversizedLineDetailPrefix)\(NDJSONFraming.maxLineBytes) bytes"
        #expect(NDJSONClientError.isOversizedLineDetail(oversized))
        #expect(!NDJSONClientError.isOversizedLineDetail("pane not found"))
        #expect(SpawnLaunch.miss(forStart: NDJSONClientError.invalidResponse(oversized)) == .unconfirmed)

        #expect(SpawnLaunch.miss(forStart: NDJSONClientError.timeout) == .unconfirmed)
        #expect(SpawnLaunch.miss(forStart: NDJSONClientError.sendFailed(32)) == .unconfirmed)
        #expect(SpawnLaunch.miss(forStart: NDJSONClientError.readFailed(1)) == .unconfirmed)
        #expect(SpawnLaunch.miss(forStart: NDJSONClientError.connectionClosed) == .unconfirmed)
        #expect(SpawnLaunch.miss(forStart: NDJSONClientError.promptEnterFailed) == .unconfirmed)

        struct Other: Error {}
        #expect(SpawnLaunch.miss(forStart: Other()) == .unconfirmed)

        let reported = SpawnLaunch.reason(SpawnLaunch.miss(forStart: NDJSONClientError.connectFailed("/tmp/herdr.sock", 61)))
        #expect(!reported.contains("/tmp/herdr.sock"))
        #expect(!reported.contains("61"))
        let rejected = SpawnLaunch.reason(.rejected)
        #expect(!rejected.contains("pane not found"))
        #expect(!SpawnLaunch.reason(.unconfirmed).contains("timed out"))
    }

    @Test("A pane created before a failed start stays one JSON object")
    func createdResultStaysJSON() throws {
        let misses: [SpawnLaunch.Miss] = [
            .shell, .writesClosed, .notConnected, .rejected, .unconfirmed
        ]
        for miss in misses {
            let reason = SpawnLaunch.reason(miss)
            let journal = SpawnLaunch.journalPostState(for: miss)
            #expect(!reason.contains("\""))
            #expect(!reason.contains("\\"))
            #expect(!journal.contains("\""))
            #expect(!journal.contains("\\"))
            if miss == .unconfirmed {
                #expect(!reason.contains("not started"))
                #expect(!journal.contains("not started"))
            } else {
                #expect(reason.contains("not started"))
                #expect(journal.contains("not started"))
            }
        }
        #expect(!SpawnLaunch.briefNotSentReason.contains("\""))
        #expect(!SpawnLaunch.briefNotSentReason.contains("\\"))

        let plain = SpawnLaunch.createdResult(
            agentId: "w1:p1",
            space: "w1",
            placement: "new_workspace",
            tab: "t2",
            actionId: "A1",
            miss: .shell,
            briefRequested: false
        )
        #expect(
            plain
                == "{\"agentId\":\"w1:p1\",\"space\":\"w1\",\"placement\":\"new_workspace\",\"tab\":\"t2\",\"started\":false,\"actionId\":\"A1\",\"startNotConfirmed\":\"the new pane did not become a shell; the agent was not started\"}"
        )
        #expect(!plain.contains("brief"))

        let split = SpawnLaunch.createdResult(
            agentId: "w1:p1",
            space: "w1",
            placement: "split",
            tab: nil,
            actionId: "A1",
            miss: .unconfirmed,
            briefRequested: true
        )
        #expect(!split.contains("\"tab\""))
        let splitObject = try #require(JSONSerialization.jsonObject(with: Data(split.utf8)) as? [String: Any])
        #expect(splitObject["started"] as? Bool == false)
        #expect(splitObject["briefSent"] as? Bool == false)
        #expect(splitObject["startNotConfirmed"] as? String == SpawnLaunch.reason(.unconfirmed))
        #expect(splitObject["briefNotSent"] as? String == SpawnLaunch.briefNotSentReason)
        #expect(splitObject["agentId"] as? String == "w1:p1")

        let emptyTab = SpawnLaunch.createdResult(
            agentId: "w1:p1",
            space: "w1",
            placement: "new_tab",
            tab: "",
            actionId: "A1",
            miss: .writesClosed,
            briefRequested: false
        )
        #expect(emptyTab.contains(",\"tab\":\"\""))
        #expect(!emptyTab.contains("briefSent"))

        let hostile = SpawnLaunch.createdResult(
            agentId: "w\"1",
            space: "a\\b",
            placement: "split\";\"started\":true",
            tab: "t\n2\t\u{0001}",
            actionId: "A\"1",
            miss: .rejected,
            briefRequested: true
        )
        let object = try #require(JSONSerialization.jsonObject(with: Data(hostile.utf8)) as? [String: Any])
        #expect(object["agentId"] as? String == "w\"1")
        #expect(object["space"] as? String == "a\\b")
        #expect(object["placement"] as? String == "split\";\"started\":true")
        #expect(object["tab"] as? String == "t\n2\t\u{0001}")
        #expect(object["started"] as? Bool == false)
        #expect(object["actionId"] as? String == "A\"1")
        #expect(object["startNotConfirmed"] as? String == SpawnLaunch.reason(.rejected))
        #expect(object["briefSent"] as? Bool == false)
        #expect(object["briefNotSent"] as? String == SpawnLaunch.briefNotSentReason)
        #expect(!hostile.contains("pane not found"))
        #expect(!hostile.contains("/tmp"))
    }
}
