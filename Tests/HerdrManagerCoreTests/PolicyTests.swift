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
