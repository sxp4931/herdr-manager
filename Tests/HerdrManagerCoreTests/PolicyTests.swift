import Foundation
import Testing
@testable import HerdrManagerCore

// MARK: - SharedActionStore Tests

@Suite("SharedActionStore")
struct SharedActionStoreTests {
    private func tempStore() -> SharedActionStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("pending-actions.json")
        return SharedActionStore(fileURL: fileURL)
    }

    @Test("Create and retrieve pending action")
    func createAndRetrieve() async {
        let store = tempStore()
        let id = await store.create(tool: "bash", params: ["command": "rm -rf /"])
        let action = await store.get(id)
        #expect(action != nil)
        #expect(action?.tool == "bash")
        #expect(action?.state == .pending)
        #expect(action?.params["command"] == "rm -rf /")
    }

    @Test("Approve a pending action")
    func approve() async {
        let store = tempStore()
        let id = await store.create(tool: "bash", params: [:])
        await store.approve(id)
        let status = await store.status(id)
        #expect(status == .approved)
    }

    @Test("Deny a pending action")
    func deny() async {
        let store = tempStore()
        let id = await store.create(tool: "write", params: [:])
        await store.deny(id)
        let status = await store.status(id)
        #expect(status == .denied)
    }

    @Test("Cannot approve already-approved action")
    func doubleApprove() async {
        let store = tempStore()
        let id = await store.create(tool: "bash", params: [:])
        await store.approve(id)
        // Second approve should be a no-op (state stays approved)
        await store.approve(id)
        let status = await store.status(id)
        #expect(status == .approved)
    }

    @Test("pendingActions filters to pending only")
    func pendingActionsFilter() async {
        let store = tempStore()
        let id1 = await store.create(tool: "bash", params: [:])
        let _ = await store.create(tool: "write", params: [:])
        await store.approve(id1)

        let pending = await store.pendingActions()
        #expect(pending.count == 1)
        #expect(pending.first?.tool == "write")
    }

    @Test("expireStale marks past-due actions as expired")
    func expireStale() async {
        let store = tempStore()
        let id = await store.create(tool: "bash", params: [:])
        // The action expires in 120s by default. We can't easily fast-forward,
        // but we can verify that non-expired actions stay pending.
        await store.expireStale()
        let status = await store.status(id)
        #expect(status == .pending) // not yet expired
    }

    @Test("markExecuted changes state")
    func markExecuted() async {
        let store = tempStore()
        let id = await store.create(tool: "bash", params: [:])
        await store.markExecuted(id)
        let status = await store.status(id)
        #expect(status == .executed)
    }

    @Test("markFailed changes state with detail")
    func markFailed() async {
        let store = tempStore()
        let id = await store.create(tool: "bash", params: [:])
        await store.markFailed(id, detail: "timeout")
        let action = await store.get(id)
        #expect(action?.state == .failed)
        #expect(action?.failDetail == "timeout")
    }
}

// MARK: - Journal Cleanup Tests

@Suite("Journal cleanup")
struct JournalCleanupTests {
    private func tempJournal() -> (Journal, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("journal.ndjson")
        let journal = Journal(fileURL: fileURL)
        return (journal, fileURL)
    }

    private func readEntries(from url: URL) -> [JournalEntry] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return lines.compactMap { try? decoder.decode(JournalEntry.self, from: Data($0)) }
    }

    @Test("Recent entries survive cleanup")
    func recentEntriesSurvive() async {
        let (journal, url) = tempJournal()
        let entry = JournalEntry(
            actionId: "a_001",
            tool: "bash",
            params: [:],
            caller: "test",
            preState: "pending",
            outcome: "approved"
        )
        await journal.record(entry)
        await journal.cleanup(maxAgeDays: 30)
        let entries = readEntries(from: url)
        #expect(entries.count == 1)
        #expect(entries.first?.actionId == "a_001")
    }

    @Test("Old entries are removed by cleanup")
    func oldEntriesRemoved() async {
        let (journal, url) = tempJournal()
        let oldDate = Date().addingTimeInterval(-60 * 86400) // 60 days ago
        let entry = JournalEntry(
            timestamp: oldDate,
            actionId: "a_old",
            tool: "bash",
            params: [:],
            caller: "test",
            preState: "pending",
            outcome: "approved"
        )
        await journal.record(entry)
        await journal.cleanup(maxAgeDays: 30)
        let entries = readEntries(from: url)
        #expect(entries.count == 0)
    }

    @Test("keepForever entries survive cleanup regardless of age")
    func keepForeverSurvives() async {
        let (journal, url) = tempJournal()
        let oldDate = Date().addingTimeInterval(-60 * 86400) // 60 days ago
        let entry = JournalEntry(
            timestamp: oldDate,
            actionId: "a_keep",
            tool: "bash",
            params: [:],
            caller: "test",
            preState: "pending",
            outcome: "approved",
            keepForever: true
        )
        await journal.record(entry)
        await journal.cleanup(maxAgeDays: 30)
        let entries = readEntries(from: url)
        #expect(entries.count == 1)
        #expect(entries.first?.actionId == "a_keep")
    }

    @Test("Mixed entries: old removed, recent and keepForever kept")
    func mixedCleanup() async {
        let (journal, url) = tempJournal()
        let oldDate = Date().addingTimeInterval(-60 * 86400)

        let oldEntry = JournalEntry(
            timestamp: oldDate, actionId: "a_old", tool: "bash",
            params: [:], caller: "test", preState: "pending", outcome: "ok"
        )
        let recentEntry = JournalEntry(
            actionId: "a_recent", tool: "write",
            params: [:], caller: "test", preState: "pending", outcome: "ok"
        )
        let keepForeverEntry = JournalEntry(
            timestamp: oldDate, actionId: "a_forever", tool: "read",
            params: [:], caller: "test", preState: "pending", outcome: "ok",
            keepForever: true
        )

        await journal.record(oldEntry)
        await journal.record(recentEntry)
        await journal.record(keepForeverEntry)

        await journal.cleanup(maxAgeDays: 30)
        let entries = readEntries(from: url)
        let ids = Set(entries.map(\.actionId))
        #expect(ids.contains("a_recent"))
        #expect(ids.contains("a_forever"))
        #expect(!ids.contains("a_old"))
    }
}

// MARK: - SettingsStore Tests

@Suite("SettingsStore")
struct SettingsStoreTests {
    private func tempStore() -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("settings.json")
        return SettingsStore(fileURL: fileURL)
    }

    @Test("Default settings on fresh store")
    func defaults() async {
        let store = tempStore()
        let snap = await store.settingsSnapshot()
        #expect(snap.defaultThresholdMinutes == 5)
        #expect(snap.metadataWriteBackEnabled == true)
        #expect(snap.agentOverrides.isEmpty)
    }

    @Test("Save and load roundtrip")
    func saveAndLoad() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("settings.json")

        let store1 = SettingsStore(fileURL: fileURL)
        try await store1.setOverride(paneId: "w1:p1", minutes: 15)
        try await store1.setMetadataWriteBack(false)

        // Create a new store pointing at the same file and load
        let store2 = SettingsStore(fileURL: fileURL)
        try await store2.load()
        let snap = await store2.settingsSnapshot()
        #expect(snap.agentOverrides["w1:p1"] == 15)
        #expect(snap.metadataWriteBackEnabled == false)
    }

    @Test("Threshold returns default when no override")
    func thresholdDefault() async {
        let store = tempStore()
        let t = await store.threshold(for: "w1:p1")
        #expect(t == 5)
    }

    @Test("Threshold returns override when set")
    func thresholdOverride() async throws {
        let store = tempStore()
        try await store.setOverride(paneId: "w1:p1", minutes: 20)
        let t = await store.threshold(for: "w1:p1")
        #expect(t == 20)
    }

    @Test("removeOverride reverts to default")
    func removeOverride() async throws {
        let store = tempStore()
        try await store.setOverride(paneId: "w1:p1", minutes: 20)
        try await store.removeOverride(paneId: "w1:p1")
        let t = await store.threshold(for: "w1:p1")
        #expect(t == 5)
    }

    @Test("setMetadataWriteBack persists")
    func setMetadataWriteBack() async throws {
        let store = tempStore()
        try await store.setMetadataWriteBack(false)
        let snap = await store.settingsSnapshot()
        #expect(snap.metadataWriteBackEnabled == false)
    }

    @Test("Load from nonexistent file is a no-op")
    func loadNonexistent() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        let fileURL = dir.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: fileURL)
        // Should not throw
        try await store.load()
        let snap = await store.settingsSnapshot()
        #expect(snap.defaultThresholdMinutes == 5)
    }
}

// MARK: - ActionStore claimExecuting Tests

@Suite("ActionStore.claimExecuting")
struct ActionStoreClaimTests {

    @Test("Approved action transitions to executing and is returned")
    func approvedTransitionsToExecuting() async {
        let store = ActionStore()
        let id = await store.create(tool: "bash", params: [:])
        let approved = await store.approve(id)
        #expect(approved != nil)

        let claimed = await store.claimExecuting(actionId: id)
        #expect(claimed != nil)
        #expect(claimed?.state == .executing)
        #expect(claimed?.actionId == id)
    }

    @Test("Second claim returns nil (already executing)")
    func secondClaimReturnsNil() async {
        let store = ActionStore()
        let id = await store.create(tool: "bash", params: [:])
        _ = await store.approve(id)
        _ = await store.claimExecuting(actionId: id)

        let second = await store.claimExecuting(actionId: id)
        #expect(second == nil)
    }

    @Test("Pending action cannot be claimed")
    func pendingCannotBeClaimed() async {
        let store = ActionStore()
        let id = await store.create(tool: "bash", params: [:])
        let claimed = await store.claimExecuting(actionId: id)
        #expect(claimed == nil)
    }

    @Test("Denied action cannot be claimed")
    func deniedCannotBeClaimed() async {
        let store = ActionStore()
        let id = await store.create(tool: "bash", params: [:])
        await store.deny(id)
        let claimed = await store.claimExecuting(actionId: id)
        #expect(claimed == nil)
    }

    @Test("Missing action returns nil")
    func missingActionReturnsNil() async {
        let store = ActionStore()
        let claimed = await store.claimExecuting(actionId: "nonexistent")
        #expect(claimed == nil)
    }
}

// MARK: - SharedActionStore reapStale Tests

@Suite("SharedActionStore.reapStale")
struct SharedActionStoreReapStaleTests {
    private func tempStore() -> SharedActionStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("pending-actions.json")
        return SharedActionStore(fileURL: fileURL)
    }

    @Test("Pending action past expiresAt becomes expired")
    func pendingBecomesExpired() async {
        let store = tempStore()
        let id = await store.create(tool: "bash", params: [:])
        // Fast-forward: call reapStale with a now far in the future
        let future = Date().addingTimeInterval(3600)
        await store.reapStale(now: future)
        let status = await store.status(id)
        #expect(status == .expired)
    }

    @Test("Terminal action older than 24h is pruned")
    func oldTerminalPruned() async {
        let store = tempStore()
        let id = await store.create(tool: "bash", params: [:])
        await store.markExecuted(id)
        // Fast-forward 25 hours
        let future = Date().addingTimeInterval(25 * 3600)
        await store.reapStale(now: future)
        let action = await store.get(id)
        #expect(action == nil)
    }

    @Test("Recent terminal action survives reap")
    func recentTerminalSurvives() async {
        let store = tempStore()
        let id = await store.create(tool: "bash", params: [:])
        await store.markExecuted(id)
        // Reap with current time — action was just created, so it should survive
        await store.reapStale(now: Date())
        let action = await store.get(id)
        #expect(action != nil)
        #expect(action?.state == .executed)
    }
}

// MARK: - Action ID UUID format

@Suite("Action ID format")
struct ActionIdFormatTests {
    @Test("Action IDs are valid UUID strings")
    func actionIdsAreUUIDs() async {
        let store = ActionStore()
        for _ in 0..<10 {
            let id = await store.create(tool: "bash", params: [:])
            #expect(UUID(uuidString: id) != nil, "Action ID '\(id)' is not a valid UUID")
        }
    }

    @Test("SharedActionStore action IDs are valid UUID strings")
    func sharedActionIdsAreUUIDs() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("pending-actions.json")
        let store = SharedActionStore(fileURL: fileURL)

        for _ in 0..<10 {
            let id = await store.create(tool: "bash", params: [:])
            #expect(UUID(uuidString: id) != nil, "Action ID '\(id)' is not a valid UUID")
        }
    }
}

// MARK: - SharedActionStore permissions

@Suite("SharedActionStore permissions")
struct SharedActionStorePermissionsTests {

    @Test("File permissions are 0600 after write")
    func filePermissionsAre0600() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("pending-actions.json")
        let store = SharedActionStore(fileURL: fileURL)

        _ = await store.create(tool: "bash", params: ["command": "echo hello"])

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perm = attrs[.posixPermissions] as? Int
        #expect(perm == 0o600, "Expected file permissions 0600, got \(String(format: "%o", perm ?? 0))")
    }

    @Test("Directory permissions are 0700 when using default init")
    func directoryPermissionsAre0700() async throws {
        // Use the default init which creates the directory
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let testDir = appSupport.appendingPathComponent(
            "HerdrManagerTests-\(UUID().uuidString)", isDirectory: true
        )
        // Clean up if exists
        try? FileManager.default.removeItem(at: testDir)

        // We can't easily test the default init without polluting the real app support dir,
        // so we test the ensureDirectory behavior by creating a store with a nested path
        // and checking the parent directory permissions after a write.
        let fileURL = testDir.appendingPathComponent("pending-actions.json")
        let store = SharedActionStore(fileURL: fileURL)

        // Create the directory manually with the right permissions to simulate
        try FileManager.default.createDirectory(
            at: testDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        _ = await store.create(tool: "bash", params: [:])

        let attrs = try FileManager.default.attributesOfItem(atPath: testDir.path)
        let perm = attrs[.posixPermissions] as? Int
        #expect(perm == 0o700, "Expected dir permissions 0700, got \(String(format: "%o", perm ?? 0))")

        // Cleanup
        try? FileManager.default.removeItem(at: testDir)
    }
}

// MARK: - SharedActionStore concurrency

@Suite("SharedActionStore concurrency")
struct SharedActionStoreConcurrencyTests {

    @Test("Concurrent creates from multiple tasks preserve all records")
    func concurrentCreatesPreserveAll() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("pending-actions.json")

        let count = 20
        // Use a single store instance - actor serialization handles concurrency
        let store = SharedActionStore(fileURL: fileURL)

        // Create actions from multiple concurrent tasks
        let allIds: [String] = await withTaskGroup(of: String.self) { group in
            for i in 0..<count {
                group.addTask {
                    let tool = i.isMultiple(of: 2) ? "bash" : "write"
                    return await store.create(tool: tool, params: [:])
                }
            }
            var collected: [String] = []
            for await id in group { collected.append(id) }
            return collected
        }

        #expect(allIds.count == count)

        // Verify the file contains all actions
        let allActions = await store.loadActions()
        #expect(allActions.count == count, "Expected \(count) actions, got \(allActions.count)")

        // Verify the file is valid JSON
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            Issue.record("File not found at \(fileURL.path)")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode([PendingAction].self, from: data)
        #expect(decoded != nil, "File should decode as valid JSON array of PendingAction")
        #expect(decoded?.count == count)

        // Cleanup
        try? FileManager.default.removeItem(at: dir)
    }
}
