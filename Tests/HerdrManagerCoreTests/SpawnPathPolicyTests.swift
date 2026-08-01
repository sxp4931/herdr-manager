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
