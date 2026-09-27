import Foundation
import Testing
@testable import HerdrManagerCore

// MARK: - Mock HerdrAdapter for Diagnosis Tests

private final class ReadLinesLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int?] = []

    func append(_ value: Int?) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Detection screens in poll order. The heartbeat reads one pane at a time.
private final class ReadScript: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String]

    init(_ texts: [String]) {
        self.texts = texts
    }

    func next() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !texts.isEmpty else { return nil }
        return texts.removeFirst()
    }
}

private struct MockHerdrAdapter: HerdrAdapter {
    var snapshotResult: HerdrSnapshot?
    var readResult: PaneReadResult?
    var explainResult: AgentExplainResult?
    var processInfoResult: ProcessInfoResult?
    var focusError: Error?
    var sendKeysError: Error?
    var promptError: Error?
    var closePaneError: Error?
    var createWorkspaceResult: WorkspaceCreation?
    var startAgentError: Error?
    var waitStatusResult: Bool = true
    var reportMetadataError: Error?
    var connectionState: HerdrConnectionState = .connected
    var readLinesLog: ReadLinesLog?
    var readScript: ReadScript?
    /// Runs after the read is issued and before the text is returned, so a
    /// test can note a newer herd serial while the poll is in `pane.read`.
    var onRead: (@Sendable () async -> Void)?

    func snapshot() async throws -> HerdrSnapshot {
        guard let result = snapshotResult else { throw NSError(domain: "Mock", code: 1) }
        return result
    }

    func read(paneId: String, source: PaneReadSource, lines: Int?) async throws -> PaneReadResult {
        readLinesLog?.append(lines)
        if let onRead { await onRead() }
        if let text = readScript?.next() {
            return PaneReadResult(text: text, source: source.rawValue)
        }
        guard let result = readResult else { throw NSError(domain: "Mock", code: 1) }
        return result
    }
    
    func explain(paneId: String) async throws -> AgentExplainResult {
        guard let result = explainResult else { throw NSError(domain: "Mock", code: 1) }
        return result
    }
    
    func processInfo(paneId: String) async throws -> ProcessInfoResult {
        guard let result = processInfoResult else { throw NSError(domain: "Mock", code: 1) }
        return result
    }
    
    func focus(paneId: String) async throws {
        if let error = focusError { throw error }
    }
    
    func events() -> AsyncStream<HerdrEvent> {
        return AsyncStream { $0.finish() }
    }
    
    func sendKeys(paneId: String, keys: [String]) async throws {
        if let error = sendKeysError { throw error }
    }
    
    func prompt(paneId: String, text: String) async throws {
        if let error = promptError { throw error }
    }
    
    func closePane(paneId: String) async throws {
        if let error = closePaneError { throw error }
    }
    
    func createWorkspace(cwd: String, label: String?) async throws -> WorkspaceCreation {
        guard let result = createWorkspaceResult else { throw NSError(domain: "Mock", code: 1) }
        return result
    }
    
    func startAgent(paneId: String, kind: String, name: String) async throws {
        if let error = startAgentError { throw error }
    }
    
    func waitStatus(paneId: String, until: [String], timeoutMs: Int) async throws -> Bool {
        return waitStatusResult
    }
    
    func reportMetadata(paneId: String, source: String, tokens: [String: String], ttlMs: Int) async throws {
        if let error = reportMetadataError { throw error }
    }
}

// MARK: - BlockKind.from(ruleId:) Tests

@Suite("BlockKind.from(ruleId:)")
struct BlockKindFromRuleIdTests {
    @Test("bash_permission_prompt maps to .bashPermission")
    func bashPermission() {
        #expect(BlockKind.from(ruleId: "bash_permission_prompt") == .bashPermission)
    }

    @Test("generic_permission_prompt maps to .toolPermission")
    func toolPermission() {
        #expect(BlockKind.from(ruleId: "generic_permission_prompt") == .toolPermission)
    }

    @Test("live_blocked_form maps to .selectionForm")
    func selectionForm() {
        #expect(BlockKind.from(ruleId: "live_blocked_form") == .selectionForm)
    }

    @Test("dynamic_workflow_prompt maps to .workflowConfirm")
    func workflowConfirm() {
        #expect(BlockKind.from(ruleId: "dynamic_workflow_prompt") == .workflowConfirm)
    }

    @Test("model_picker_menu maps to .menu")
    func menu() {
        #expect(BlockKind.from(ruleId: "model_picker_menu") == .menu)
    }

    @Test("live_strong_blocker maps to .approval")
    func approvalStrong() {
        #expect(BlockKind.from(ruleId: "live_strong_blocker") == .approval)
    }

    @Test("osc_title_blocked maps to .approval")
    func approvalOsc() {
        #expect(BlockKind.from(ruleId: "osc_title_blocked") == .approval)
    }

    @Test("weak_blocker maps to .probableApproval")
    func probableApproval() {
        #expect(BlockKind.from(ruleId: "weak_blocker") == .probableApproval)
    }

    @Test("unknown rule ID maps to .unknownBlock")
    func unknown() {
        #expect(BlockKind.from(ruleId: "some_new_rule") == .unknownBlock)
        #expect(BlockKind.from(ruleId: "") == .unknownBlock)
        // A password prompt and a shell waiting for input stay unnamed.
        // Sending Enter there would submit whatever is in the field.
        #expect(BlockKind.from(ruleId: "credential_prompt") == .unknownBlock)
        #expect(BlockKind.from(ruleId: "confirmation_or_input_blocker") == .unknownBlock)
    }

    @Test("Enter-to-confirm rules are a confirmation, and accept_once is refused")
    func confirmationPrompts() {
        let rules = [
            "permission_required", "opencode_permission", "mcp_elicitation_prompt",
            "trust_directory", "startup_update", "apply_or_allow_change",
            "current_approval_panel", "legacy_approval_panel",
            "dangerous_command_approval", "clarification_prompt", "tool_confirmation",
            "permission_scope_selector", "workspace_trust_blocked", "blocked_approval",
            "plan_complete_form"
        ]
        for rule in rules {
            let kind = BlockKind.from(ruleId: rule)
            #expect(kind == .confirmation)
            #expect(kind.summary == "confirmation prompt")
            #expect(kind.answerKeys(forChoice: "approve", index: nil) == ["enter"])
            #expect(kind.answerKeys(forChoice: "deny", index: nil) == ["esc"])
            #expect(kind.answerKeys(forChoice: "cancel", index: nil) == ["esc"])
            #expect(kind.answerKeys(forChoice: "accept_once", index: nil) == nil)
            #expect(kind.answerKeys(forChoice: "select", index: 0) == ["enter"])
            #expect(kind.answerKeys(forChoice: "select", index: 2) == ["down", "down", "enter"])
        }
    }

    @Test("Enter-to-select rules stay a selection form")
    func selectionPrompts() {
        let rules = [
            "execute_selection_blocker", "selection_menu_blocker", "selection_blocker",
            "question_panel", "question_dialog", "command_approval"
        ]
        for rule in rules {
            let kind = BlockKind.from(ruleId: rule)
            #expect(kind == .selectionForm)
            #expect(kind.answerKeys(forChoice: "approve", index: nil) == ["enter"])
            #expect(kind.answerKeys(forChoice: "select", index: 1) == ["down", "enter"])
            #expect(kind.answerKeys(forChoice: "accept_once", index: nil) == nil)
        }
    }

    @Test("Prompts whose Enter key disagrees stay read-only")
    func readOnlyPrompts() {
        // permission_prompt is one id for three agents. On one of them Enter denies.
        // Cursor asks for y. Grok's cancel on these screens is not Esc.
        let rules = [
            "permission_prompt", "write_file_approval", "approval_prompt",
            "legacy_no_prompt_blocker", "permission_hints_blocked",
            "question_dialog_hints_blocked", "option_dialog_blocked",
            "folder_trust_dialog", "inline_tool_permission"
        ]
        for rule in rules {
            let kind = BlockKind.from(ruleId: rule)
            #expect(kind == .probableApproval)
            #expect(kind.answerKeys(forChoice: "approve", index: nil) == nil)
            #expect(kind.answerKeys(forChoice: "deny", index: nil) == nil)
            #expect(kind.answerKeys(forChoice: "select", index: 0) == nil)
        }
    }

    @Test("The yes / don't-ask-again / no stack still takes accept_once")
    func acceptOnceStaysOnThePermissionStack() {
        for kind in [BlockKind.bashPermission, .toolPermission, .approval, .workflowConfirm] {
            #expect(kind.answerKeys(forChoice: "approve", index: nil) == ["enter"])
            #expect(kind.answerKeys(forChoice: "accept_once", index: nil) == ["down", "enter"])
            #expect(kind.answerKeys(forChoice: "deny", index: nil) == ["esc"])
            #expect(kind.answerKeys(forChoice: "select", index: 1) == nil)
        }
        #expect(BlockKind.menu.answerKeys(forChoice: "select", index: nil) == ["enter"])
        #expect(BlockKind.menu.answerKeys(forChoice: "accept_once", index: nil) == nil)
        #expect(BlockKind.unknownBlock.answerKeys(forChoice: "approve", index: nil) == nil)
        #expect(BlockKind.selectionForm.answerKeys(forChoice: "select", index: -1) == nil)
    }
}

// MARK: - CPUState.from(cpuPercent:) Tests

@Suite("CPUState.from(cpuPercent:)")
struct CPUStateFromCpuPercentTests {
    @Test(">50% CPU → .thinking")
    func thinking() {
        #expect(CPUState.from(cpuPercent: 51.0) == .thinking)
        #expect(CPUState.from(cpuPercent: 99.9) == .thinking)
        #expect(CPUState.from(cpuPercent: 100.0) == .thinking)
    }

    @Test("<1% CPU → .deadlocked")
    func deadlocked() {
        #expect(CPUState.from(cpuPercent: 0.0) == .deadlocked)
        #expect(CPUState.from(cpuPercent: 0.5) == .deadlocked)
        #expect(CPUState.from(cpuPercent: 0.99) == .deadlocked)
    }

    @Test("1-50% CPU → .ioWait")
    func ioWait() {
        #expect(CPUState.from(cpuPercent: 1.0) == .ioWait)
        #expect(CPUState.from(cpuPercent: 25.0) == .ioWait)
        #expect(CPUState.from(cpuPercent: 50.0) == .ioWait)
    }
}

// MARK: - Verdict.summaryLine Tests

@Suite("Verdict.summaryLine")
struct VerdictSummaryLineTests {
    @Test("healthy returns nil")
    func healthy() {
        #expect(Verdict.healthy.summaryLine == nil)
    }

    @Test("awaitingInput returns non-empty string")
    func awaitingInput() {
        let classification = BlockClassification(
            kind: .bashPermission,
            since: Date(),
            summary: "bash permission prompt"
        )
        let verdict = Verdict.awaitingInput(classification)
        let summary = verdict.summaryLine
        #expect(summary != nil)
        #expect(!summary!.isEmpty)
        #expect(summary!.contains("Waiting"))
    }

    @Test("silent returns non-empty string")
    func silent() {
        let verdict = Verdict.silent(since: Date().addingTimeInterval(-300), cpu: .thinking)
        let summary = verdict.summaryLine
        #expect(summary != nil)
        #expect(!summary!.isEmpty)
        #expect(summary!.contains("Silent"))
    }

    @Test("silent with unknown CPU omits CPU hint")
    func silentUnknownCpu() {
        let verdict = Verdict.silent(since: Date().addingTimeInterval(-60), cpu: .unknown)
        let summary = verdict.summaryLine
        #expect(summary != nil)
        #expect(summary!.contains("Silent"))
        // Should not contain CPU hint in parens
        #expect(!summary!.contains("thinking"))
        #expect(!summary!.contains("deadlocked"))
    }

    @Test("silent with nil CPU omits CPU hint")
    func silentNilCpu() {
        let verdict = Verdict.silent(since: Date().addingTimeInterval(-60), cpu: nil)
        let summary = verdict.summaryLine
        #expect(summary != nil)
        #expect(summary!.contains("Silent"))
    }

    @Test("processGone returns non-empty string")
    func processGone() {
        let verdict = Verdict.processGone(lastLine: "bash (pid 1234)")
        let summary = verdict.summaryLine
        #expect(summary != nil)
        #expect(!summary!.isEmpty)
        #expect(summary!.contains("gone") || summary!.contains("💀"))
    }

    @Test("unclassifiable returns non-empty string")
    func unclassifiable() {
        let verdict = Verdict.unclassifiable(reason: "unknown status")
        let summary = verdict.summaryLine
        #expect(summary != nil)
        #expect(!summary!.isEmpty)
    }
}

// MARK: - Verdict convenience properties Tests

@Suite("Verdict convenience properties")
struct VerdictConvenienceTests {
    @Test("isHealthy returns true only for .healthy")
    func isHealthy() {
        #expect(Verdict.healthy.isHealthy == true)
        #expect(Verdict.processGone(lastLine: nil).isHealthy == false)
        #expect(Verdict.unclassifiable(reason: "x").isHealthy == false)
    }

    @Test("isSilent returns true only for .silent")
    func isSilent() {
        #expect(Verdict.silent(since: Date(), cpu: nil).isSilent == true)
        #expect(Verdict.healthy.isSilent == false)
        #expect(Verdict.processGone(lastLine: nil).isSilent == false)
    }

    @Test("isProcessGone returns true only for .processGone")
    func isProcessGone() {
        #expect(Verdict.processGone(lastLine: nil).isProcessGone == true)
        #expect(Verdict.processGone(lastLine: "bash").isProcessGone == true)
        #expect(Verdict.healthy.isProcessGone == false)
        #expect(Verdict.silent(since: Date(), cpu: nil).isProcessGone == false)
    }

    @Test("isAwaitingInput returns true only for .awaitingInput")
    func isAwaitingInput() {
        let classification = BlockClassification(kind: .bashPermission, since: Date(), summary: "test")
        #expect(Verdict.awaitingInput(classification).isAwaitingInput == true)
        #expect(Verdict.healthy.isAwaitingInput == false)
        #expect(Verdict.silent(since: Date(), cpu: nil).isAwaitingInput == false)
    }

    @Test("isUnclassifiable returns true only for .unclassifiable")
    func isUnclassifiable() {
        #expect(Verdict.unclassifiable(reason: "x").isUnclassifiable == true)
        #expect(Verdict.healthy.isUnclassifiable == false)
        #expect(Verdict.silent(since: Date(), cpu: nil).isUnclassifiable == false)
    }
}

// MARK: - HeartbeatPoller SHA256 Tests

@Suite("HeartbeatPoller SHA256")
struct HeartbeatPollerHashTests {
    @Test("Same input produces same hash")
    func deterministic() {
        let hash1 = HeartbeatPoller.sha256("hello world")
        let hash2 = HeartbeatPoller.sha256("hello world")
        #expect(hash1 == hash2)
    }

    @Test("Different inputs produce different hashes")
    func differentInputs() {
        let hash1 = HeartbeatPoller.sha256("hello")
        let hash2 = HeartbeatPoller.sha256("world")
        #expect(hash1 != hash2)
    }

    @Test("Empty string produces a hash")
    func emptyString() {
        let hash = HeartbeatPoller.sha256("")
        #expect(!hash.isEmpty)
    }

    @Test("Hash changes when content changes (simulating output change detection)")
    func hashChangeDetection() {
        let content1 = "$ echo hello\nhello\n$"
        let content2 = "$ echo hello\nhello\n$ echo world\nworld\n$"
        let hash1 = HeartbeatPoller.sha256(content1)
        let hash2 = HeartbeatPoller.sha256(content2)
        #expect(hash1 != hash2, "Hash should change when pane output changes")
    }

    @Test("Detection hash only considers a bounded suffix so a huge pane.read cannot pin RSS")
    func detectionHashUsesBoundedSuffix() {
        let cap = HeartbeatPoller.detectionHashMaxBytes
        #expect(cap == 64 * 1024)
        let window = String(repeating: "n", count: cap)
        let ignoredPrefix = String(repeating: "p", count: 8_192)
        #expect(HeartbeatPoller.sha256(ignoredPrefix + window) == HeartbeatPoller.sha256(window))
        #expect(HeartbeatPoller.sha256(window + "changed") != HeartbeatPoller.sha256(window))
    }

    @Test("Detection heartbeat asks herdr for at most 80 lines")
    func detectionReadIsBounded() async {
        var adapter = MockHerdrAdapter()
        let log = ReadLinesLog()
        adapter.readLinesLog = log
        adapter.readResult = PaneReadResult(text: "screen", source: "detection")
        let poller = HeartbeatPoller()
        _ = await poller.poll(
            agents: [Agent(id: AgentID("w1:p1"), status: .working)],
            adapter: adapter
        )
        #expect(log.snapshot == [HeartbeatPoller.detectionReadLines])
        #expect(HeartbeatPoller.detectionReadLines == 80)
    }

    @Test("A poll from an older herd serial does not replace the screen a newer read stored")
    func olderHerdSerialDoesNotReplaceTheDetectionHash() async {
        let poller = HeartbeatPoller()
        let agent = Agent(id: AgentID("w1:p1"), status: .working)
        var first = MockHerdrAdapter()
        first.readResult = PaneReadResult(text: "one", source: "detection")
        let baseline = await poller.poll(agents: [agent], adapter: first, herdSerial: 1)
        #expect(baseline.isEmpty)
        let started = await poller.lastOutputDate(for: agent.id)

        var during = MockHerdrAdapter()
        during.readScript = ReadScript(["two"])
        during.onRead = {
            await poller.noteHerdSerial(4)
        }
        let ignored = await poller.poll(agents: [agent], adapter: during, herdSerial: 1)
        #expect(ignored.isEmpty)
        #expect(await poller.lastOutputDate(for: agent.id) == started)

        var same = MockHerdrAdapter()
        same.readResult = PaneReadResult(text: "one", source: "detection")
        let still = await poller.poll(agents: [agent], adapter: same, herdSerial: 4)
        #expect(still.isEmpty)

        var changed = MockHerdrAdapter()
        changed.readResult = PaneReadResult(text: "two", source: "detection")
        let update = await poller.poll(agents: [agent], adapter: changed, herdSerial: 4)
        #expect(update[agent.id] != nil)

        // Already behind, before the read. The screen is not fetched.
        await poller.noteHerdSerial(6)
        let lateScript = ReadScript(["three"])
        var late = MockHerdrAdapter()
        late.readScript = lateScript
        let dropped = await poller.poll(agents: [agent], adapter: late, herdSerial: 4)
        #expect(dropped.isEmpty)
        #expect(lateScript.next() == "three")
        var stillTwo = MockHerdrAdapter()
        stillTwo.readResult = PaneReadResult(text: "two", source: "detection")
        let afterDrop = await poller.poll(agents: [agent], adapter: stillTwo, herdSerial: 6)
        #expect(afterDrop.isEmpty)

        // Untagged polls are Shepherd's heartbeat. They still record.
        var untagged = MockHerdrAdapter()
        untagged.readResult = PaneReadResult(text: "four", source: "detection")
        let recorded = await poller.poll(agents: [agent], adapter: untagged)
        #expect(recorded[agent.id] != nil)

        var zero = MockHerdrAdapter()
        zero.readResult = PaneReadResult(text: "five", source: "detection")
        let notASerial = await poller.poll(agents: [agent], adapter: zero, herdSerial: 0)
        #expect(notASerial.isEmpty)
        var stillFour = MockHerdrAdapter()
        stillFour.readResult = PaneReadResult(text: "four", source: "detection")
        let unchanged = await poller.poll(agents: [agent], adapter: stillFour)
        #expect(unchanged.isEmpty)
    }

    @Test("A move's herd serial retires a poll of the pane that was left")
    func retargetNotesTheHerdSerial() async {
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)
        var adapter = MockHerdrAdapter()
        adapter.readResult = PaneReadResult(text: "one", source: "detection")
        _ = await poller.poll(agents: [origin], adapter: adapter, herdSerial: 2)
        _ = await poller.retarget(replacing: [origin.id: moved.id], herdSerial: 5)

        var older = MockHerdrAdapter()
        older.readResult = PaneReadResult(text: "shell", source: "detection")
        let dropped = await poller.poll(agents: [origin], adapter: older, herdSerial: 2)
        #expect(dropped.isEmpty)
        // "shell" was not stored on the old id. The next screen there is a
        // first look, not a change from the shell.
        var probe = MockHerdrAdapter()
        probe.readResult = PaneReadResult(text: "other", source: "detection")
        let firstLook = await poller.poll(agents: [origin], adapter: probe)
        #expect(firstLook.isEmpty)

        var same = MockHerdrAdapter()
        same.readResult = PaneReadResult(text: "one", source: "detection")
        let kept = await poller.poll(agents: [moved], adapter: same, herdSerial: 5)
        #expect(kept.isEmpty)
    }

    @Test("Prune drops last-output dates for agents that left the herd")
    func pruneDropsClosedAgents() async throws {
        var adapter = MockHerdrAdapter()
        adapter.readResult = PaneReadResult(text: "screen", source: "detection")
        let keep = Agent(id: AgentID("w1:p1"), status: .working)
        let drop = Agent(id: AgentID("w1:p2"), status: .working)
        let poller = HeartbeatPoller()
        _ = await poller.poll(agents: [keep, drop], adapter: adapter)
        #expect(await poller.lastOutputDate(for: keep.id) != nil)
        #expect(await poller.lastOutputDate(for: drop.id) != nil)
        await poller.prune(keeping: [keep.id])
        #expect(await poller.lastOutputDate(for: keep.id) != nil)
        #expect(await poller.lastOutputDate(for: drop.id) == nil)
    }

    @Test("A moved pane keeps its detection hash, so the same screen is not a new change")
    func retargetKeepsTheDetectionHash() async {
        let script = ReadScript(["one", "two", "two", "three"])
        var adapter = MockHerdrAdapter()
        adapter.readScript = script
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)

        let baseline = await poller.poll(agents: [origin], adapter: adapter)
        #expect(baseline.isEmpty)

        let changed = await poller.poll(agents: [origin], adapter: adapter)
        #expect(changed[origin.id] != nil)

        await poller.retarget(from: origin.id, to: moved.id)

        let sameScreen = await poller.poll(agents: [moved], adapter: adapter)
        #expect(sameScreen.isEmpty)
        #expect(await poller.lastOutputDate(for: origin.id) == nil)

        let afterMove = await poller.poll(agents: [moved], adapter: adapter)
        #expect(afterMove[moved.id] != nil)
        #expect(afterMove[origin.id] == nil)
        #expect(await poller.lastOutputDate(for: moved.id) != nil)
    }

    @Test("Output that arrives before the first poll of the new id is not swallowed")
    func retargetReportsTheScreenTheMoveLandedOn() async {
        let script = ReadScript(["one", "two"])
        var adapter = MockHerdrAdapter()
        adapter.readScript = script
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)

        let baseline = await poller.poll(agents: [origin], adapter: adapter)
        #expect(baseline.isEmpty)
        await poller.retarget(from: origin.id, to: moved.id)

        let landed = await poller.poll(agents: [moved], adapter: adapter)
        #expect(landed[moved.id] != nil)
        #expect(landed[origin.id] == nil)
    }

    @Test("Retargeting replaces a hash the destination id already had")
    func retargetReplacesTheDestinationHash() async {
        let script = ReadScript(["alpha", "other", "alpha", "beta"])
        var adapter = MockHerdrAdapter()
        adapter.readScript = script
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let destination = Agent(id: AgentID("wB:p9"), status: .working)

        let baseline = await poller.poll(agents: [origin, destination], adapter: adapter)
        #expect(baseline.isEmpty)
        await poller.retarget(from: origin.id, to: destination.id)

        // "alpha" is the mover's screen. The destination's old "other" hash
        // would have called this a change.
        let moverScreen = await poller.poll(agents: [destination], adapter: adapter)
        #expect(moverScreen.isEmpty)

        let changed = await poller.poll(agents: [destination], adapter: adapter)
        #expect(changed[destination.id] != nil)
        #expect(await poller.lastOutputDate(for: origin.id) == nil)
    }

    @Test("A mover that has never been polled does not inherit the destination hash")
    func retargetWithoutAHashDoesNotCompareAgainstTheOldOccupant() async {
        let script = ReadScript(["other", "different"])
        var adapter = MockHerdrAdapter()
        adapter.readScript = script
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let destination = Agent(id: AgentID("wB:p9"), status: .working)

        let baseline = await poller.poll(agents: [destination], adapter: adapter)
        #expect(baseline.isEmpty)
        await poller.retarget(from: origin.id, to: destination.id)

        let firstLook = await poller.poll(agents: [destination], adapter: adapter)
        #expect(firstLook.isEmpty)
        #expect(await poller.lastOutputDate(for: destination.id) != nil)
    }

    @Test("Retargeting an id onto itself keeps the hash")
    func retargetOntoItselfKeepsTheHash() async {
        let script = ReadScript(["one", "one", "two"])
        var adapter = MockHerdrAdapter()
        adapter.readScript = script
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)

        let baseline = await poller.poll(agents: [origin], adapter: adapter)
        #expect(baseline.isEmpty)
        await poller.retarget(from: origin.id, to: origin.id)

        let same = await poller.poll(agents: [origin], adapter: adapter)
        #expect(same.isEmpty)
        let changed = await poller.poll(agents: [origin], adapter: adapter)
        #expect(changed[origin.id] != nil)
    }

    @Test("Prune after a retarget drops the old id and keeps the new one")
    func pruneAfterRetargetKeepsTheNewId() async {
        var adapter = MockHerdrAdapter()
        adapter.readResult = PaneReadResult(text: "screen", source: "detection")
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)

        _ = await poller.poll(agents: [origin], adapter: adapter)
        await poller.retarget(from: origin.id, to: moved.id)
        await poller.prune(keeping: [moved.id])

        #expect(await poller.lastOutputDate(for: origin.id) == nil)
        #expect(await poller.lastOutputDate(for: moved.id) != nil)
    }

    @Test("A vacant retarget fills an id that has not been polled")
    func retargetVacantFillsAnUnpolledId() async {
        let script = ReadScript(["one", "one", "two"])
        var adapter = MockHerdrAdapter()
        adapter.readScript = script
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)

        let baseline = await poller.poll(agents: [origin], adapter: adapter)
        #expect(baseline.isEmpty)
        await poller.retargetVacant(from: origin.id, to: moved.id)

        let sameScreen = await poller.poll(agents: [moved], adapter: adapter)
        #expect(sameScreen.isEmpty)
        #expect(await poller.lastOutputDate(for: origin.id) == nil)

        let changed = await poller.poll(agents: [moved], adapter: adapter)
        #expect(changed[moved.id] != nil)
    }

    @Test("A vacant retarget keeps a hash the new id already stored")
    func retargetVacantKeepsTheDestinationHash() async {
        let script = ReadScript(["alpha", "alpha", "alpha", "beta"])
        var adapter = MockHerdrAdapter()
        adapter.readScript = script
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)

        let originBaseline = await poller.poll(agents: [origin], adapter: adapter)
        #expect(originBaseline.isEmpty)
        // The poll of the new id landed first and stored the mover's screen.
        let destinationBaseline = await poller.poll(agents: [moved], adapter: adapter)
        #expect(destinationBaseline.isEmpty)
        await poller.retargetVacant(from: origin.id, to: moved.id)

        let sameScreen = await poller.poll(agents: [moved], adapter: adapter)
        #expect(sameScreen.isEmpty)
        #expect(await poller.lastOutputDate(for: origin.id) == nil)

        let changed = await poller.poll(agents: [moved], adapter: adapter)
        #expect(changed[moved.id] != nil)
    }

    @Test("A vacant retarget does not clear a destination the origin never hashed")
    func retargetVacantWithoutAHashLeavesTheDestination() async {
        let script = ReadScript(["other", "other"])
        var adapter = MockHerdrAdapter()
        adapter.readScript = script
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let destination = Agent(id: AgentID("wB:p9"), status: .working)

        let baseline = await poller.poll(agents: [destination], adapter: adapter)
        #expect(baseline.isEmpty)
        await poller.retargetVacant(from: origin.id, to: destination.id)

        let sameScreen = await poller.poll(agents: [destination], adapter: adapter)
        #expect(sameScreen.isEmpty)
        #expect(await poller.lastOutputDate(for: destination.id) != nil)
    }

    @Test("A first look is not a change a move can carry")
    func retargetOfABaselineCarriesNoChange() async {
        var adapter = MockHerdrAdapter()
        adapter.readScript = ReadScript(["one"])
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)

        let baseline = await poller.poll(agents: [origin], adapter: adapter)
        #expect(baseline.isEmpty)
        let carried = await poller.retarget(from: origin.id, to: moved.id)
        #expect(carried == nil)
        let vacant = await poller.retargetVacant(from: moved.id, to: AgentID("wC:p8"))
        #expect(vacant == nil)
    }

    @Test("A change compared on the old id follows the row, and a second hop keeps it")
    func retargetCarriesTheComparedChange() async {
        var adapter = MockHerdrAdapter()
        adapter.readScript = ReadScript(["one", "two"])
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)
        let again = AgentID("wC:p8")

        let baseline = await poller.poll(agents: [origin], adapter: adapter)
        #expect(baseline.isEmpty)
        let changed = await poller.poll(agents: [origin], adapter: adapter)
        let when = changed[origin.id]
        #expect(when != nil)

        let carried = await poller.retarget(from: origin.id, to: moved.id)
        #expect(carried == when)
        #expect(await poller.lastOutputDate(for: origin.id) == nil)

        let hopped = await poller.retarget(from: moved.id, to: again)
        #expect(hopped == when)
        #expect(await poller.lastOutputDate(for: moved.id) == nil)
        #expect(await poller.lastOutputDate(for: again) != nil)
    }

    @Test("The carried change clears a silence the poll's old id can no longer see")
    @MainActor
    func carriedChangeClearsSilenceOnTheNewId() async {
        var adapter = MockHerdrAdapter()
        adapter.readScript = ReadScript(["one", "two"])
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)

        _ = await poller.poll(agents: [origin], adapter: adapter)
        let changed = await poller.poll(agents: [origin], adapter: adapter)
        let carried = await poller.retarget(from: origin.id, to: moved.id)
        #expect(carried == changed[origin.id])

        let store = AgentStore()
        let stale = Date().addingTimeInterval(-20 * 60)
        store.agents = [
            moved.id: Agent(
                id: moved.id,
                kind: .claude,
                status: .working,
                enteredAt: stale,
                lastOutputAt: stale,
                verdict: .silent(since: stale, cpu: nil)
            )
        ]
        // The dictionary poll returned names the pane that left.
        if let when = changed[origin.id] {
            store.applyObservedOutput([origin.id: when])
        }
        #expect(store.agents[moved.id]?.verdict.isSilent == true)

        if let carried {
            store.applyObservedOutput([moved.id: carried])
        }
        let agent = store.agents[moved.id]
        #expect(agent?.lastOutputAt == carried)
        #expect(agent?.verdict.isHealthy == true)
        #expect(agent?.verdict.isSilent == false)
    }

    @Test("A vacant retarget carries a change the new id will not report again")
    func vacantRetargetCarriesTheComparedChange() async {
        var adapter = MockHerdrAdapter()
        adapter.readScript = ReadScript(["one", "two", "two", "two", "three"])
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)

        _ = await poller.poll(agents: [origin], adapter: adapter)
        let changed = await poller.poll(agents: [origin], adapter: adapter)
        // The new id's first look stored this same screen.
        let landed = await poller.poll(agents: [moved], adapter: adapter)
        #expect(landed.isEmpty)

        let carried = await poller.retargetVacant(from: origin.id, to: moved.id)
        #expect(carried == changed[origin.id])
        #expect(await poller.lastOutputDate(for: origin.id) == nil)

        let sameScreen = await poller.poll(agents: [moved], adapter: adapter)
        #expect(sameScreen.isEmpty)
        let next = await poller.poll(agents: [moved], adapter: adapter)
        #expect(next[moved.id] != nil)
    }

    @Test("Prune drops a change that never followed the row")
    func pruneDropsAnUncarriedChange() async {
        var adapter = MockHerdrAdapter()
        adapter.readScript = ReadScript(["one", "two"])
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)

        _ = await poller.poll(agents: [origin], adapter: adapter)
        let changed = await poller.poll(agents: [origin], adapter: adapter)
        #expect(changed[origin.id] != nil)
        await poller.prune(keeping: [])
        let carried = await poller.retarget(from: origin.id, to: AgentID("wB:p4"))
        #expect(carried == nil)
    }

    @Test("A replace after the hop already moved does not swallow the landed screen")
    func replaceAfterVacantKeepsTheLandedScreen() async {
        let script = ReadScript(["one", "two"])
        var adapter = MockHerdrAdapter()
        adapter.readScript = script
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)

        let baseline = await poller.poll(agents: [origin], adapter: adapter)
        #expect(baseline.isEmpty)
        let vacant = await poller.retargetVacant(from: origin.id, to: moved.id)
        #expect(vacant == nil)
        let replace = await poller.retarget(from: origin.id, to: moved.id)
        #expect(replace == nil)

        // "one" is the screen the hop stored. A replace that cleared it
        // would treat "two" as the first look and report nothing.
        let landed = await poller.poll(agents: [moved], adapter: adapter)
        #expect(landed[moved.id] != nil)
        #expect(landed[origin.id] == nil)
    }

    @Test("A replace after a vacant retarget keeps a hash the new id already stored")
    func replaceAfterVacantKeepsTheDestinationHash() async {
        let script = ReadScript(["alpha", "alpha", "beta"])
        var adapter = MockHerdrAdapter()
        adapter.readScript = script
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)

        let originBaseline = await poller.poll(agents: [origin], adapter: adapter)
        #expect(originBaseline.isEmpty)
        let destinationBaseline = await poller.poll(agents: [moved], adapter: adapter)
        #expect(destinationBaseline.isEmpty)
        let vacant = await poller.retargetVacant(from: origin.id, to: moved.id)
        #expect(vacant == nil)
        let replace = await poller.retarget(from: origin.id, to: moved.id)
        #expect(replace == nil)

        let changed = await poller.poll(agents: [moved], adapter: adapter)
        #expect(changed[moved.id] != nil)
        #expect(await poller.lastOutputDate(for: origin.id) == nil)
    }

    @Test("A vacant retarget then a replace still carries the compared change")
    func replaceAfterVacantKeepsTheCarriedChange() async {
        var adapter = MockHerdrAdapter()
        adapter.readScript = ReadScript(["one", "two"])
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)
        let again = AgentID("wC:p8")

        _ = await poller.poll(agents: [origin], adapter: adapter)
        let changed = await poller.poll(agents: [origin], adapter: adapter)
        let when = changed[origin.id]
        #expect(when != nil)

        let vacant = await poller.retargetVacant(from: origin.id, to: moved.id)
        #expect(vacant == when)
        let replace = await poller.retarget(from: origin.id, to: moved.id)
        #expect(replace == nil)
        let hopped = await poller.retarget(from: moved.id, to: again)
        #expect(hopped == when)
        #expect(await poller.lastOutputDate(for: moved.id) == nil)
        #expect(await poller.lastOutputDate(for: again) != nil)
    }

    @Test("A second replace does not install a screen recorded on the old id afterwards")
    func secondReplaceLeavesALaterHashOnTheOldId() async {
        let script = ReadScript(["one", "shell", "shell"])
        var adapter = MockHerdrAdapter()
        adapter.readScript = script
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)

        let baseline = await poller.poll(agents: [origin], adapter: adapter)
        #expect(baseline.isEmpty)
        let carried = await poller.retarget(from: origin.id, to: moved.id)
        #expect(carried == nil)
        // The read was in flight against the old id. It finishes after the
        // hash has moved, so it stores a first look there.
        let stale = await poller.poll(agents: [origin], adapter: adapter)
        #expect(stale.isEmpty)
        let again = await poller.retarget(from: origin.id, to: moved.id)
        #expect(again == nil)

        // The destination still holds "one". "shell" is a change. Installing
        // the stale first look, or clearing the hash, would report nothing.
        let landed = await poller.poll(agents: [moved], adapter: adapter)
        #expect(landed[moved.id] != nil)
        #expect(await poller.lastOutputDate(for: origin.id) != nil)
    }

    @Test("A second replace of the same hop leaves the change a later hop carries")
    func secondReplaceKeepsTheCarriedChange() async {
        var adapter = MockHerdrAdapter()
        adapter.readScript = ReadScript(["one", "two"])
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)
        let again = AgentID("wC:p8")

        _ = await poller.poll(agents: [origin], adapter: adapter)
        let changed = await poller.poll(agents: [origin], adapter: adapter)
        let when = changed[origin.id]
        #expect(when != nil)

        let first = await poller.retarget(from: origin.id, to: moved.id)
        #expect(first == when)
        let second = await poller.retarget(from: origin.id, to: moved.id)
        #expect(second == nil)
        let hopped = await poller.retarget(from: moved.id, to: again)
        #expect(hopped == when)
    }

    @Test("Prune of the old id does not let a later replace drop the moved screen")
    func pruneAfterVacantKeepsTheMovedScreen() async {
        let script = ReadScript(["one", "two"])
        var adapter = MockHerdrAdapter()
        adapter.readScript = script
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let moved = Agent(id: AgentID("wB:p4"), status: .working)

        _ = await poller.poll(agents: [origin], adapter: adapter)
        _ = await poller.retargetVacant(from: origin.id, to: moved.id)
        await poller.prune(keeping: [moved.id])
        let replace = await poller.retarget(from: origin.id, to: moved.id)
        #expect(replace == nil)

        let landed = await poller.poll(agents: [moved], adapter: adapter)
        #expect(landed[moved.id] != nil)
        #expect(await poller.lastOutputDate(for: origin.id) == nil)
    }

    @Test("One replace of a whole poll moves every pane, and a never-polled origin still clears")
    func retargetReplacingMovesEveryPane() async {
        let script = ReadScript(["one", "three", "other", "two", "four", "different"])
        var adapter = MockHerdrAdapter()
        adapter.readScript = script
        let poller = HeartbeatPoller()
        let originA = Agent(id: AgentID("wA:p1"), status: .working)
        let originB = Agent(id: AgentID("wB:p2"), status: .working)
        let staleDest = Agent(id: AgentID("wE:p5"), status: .working)
        let movedA = Agent(id: AgentID("wC:p3"), status: .working)
        let movedB = Agent(id: AgentID("wD:p4"), status: .working)
        let neverPolled = AgentID("wF:p6")

        let baseline = await poller.poll(agents: [originA, originB, staleDest], adapter: adapter)
        #expect(baseline.isEmpty)
        let carried = await poller.retarget(replacing: [
            originA.id: movedA.id,
            originB.id: movedB.id,
            neverPolled: staleDest.id,
        ])
        #expect(carried.isEmpty)

        let landedA = await poller.poll(agents: [movedA], adapter: adapter)
        #expect(landedA[movedA.id] != nil)
        let landedB = await poller.poll(agents: [movedB], adapter: adapter)
        #expect(landedB[movedB.id] != nil)
        // The origin was never polled, so "different" is a first look
        // against the hash this call cleared, not a change from "other".
        let cleared = await poller.poll(agents: [staleDest], adapter: adapter)
        #expect(cleared.isEmpty)
    }

    @Test("A vacant retarget of a never-polled origin still lets the replace clear")
    func replaceAfterVacantWithoutAHashClearsTheDestination() async {
        let script = ReadScript(["other", "different"])
        var adapter = MockHerdrAdapter()
        adapter.readScript = script
        let poller = HeartbeatPoller()
        let origin = Agent(id: AgentID("wA:p1"), status: .working)
        let destination = Agent(id: AgentID("wB:p9"), status: .working)

        let baseline = await poller.poll(agents: [destination], adapter: adapter)
        #expect(baseline.isEmpty)
        let vacant = await poller.retargetVacant(from: origin.id, to: destination.id)
        #expect(vacant == nil)
        let replace = await poller.retarget(from: origin.id, to: destination.id)
        #expect(replace == nil)

        let firstLook = await poller.poll(agents: [destination], adapter: adapter)
        #expect(firstLook.isEmpty)
        #expect(await poller.lastOutputDate(for: destination.id) != nil)
    }
}

// MARK: - Diagnoser silentThreshold Tests

@Suite("Diagnoser.silentThreshold")
struct DiagnoserSilentThresholdTests {
    @Test("Known coding agents use 5-minute threshold")
    func knownAgents() {
        #expect(Diagnoser.silentThreshold(for: .claude) == 300)
        #expect(Diagnoser.silentThreshold(for: .codex) == 300)
        #expect(Diagnoser.silentThreshold(for: .opencode) == 300)
        #expect(Diagnoser.silentThreshold(for: .aider) == 300)
        #expect(Diagnoser.silentThreshold(for: .gemini) == 300)
    }

    @Test("Custom agents use 5-minute default threshold")
    func customAgents() {
        #expect(Diagnoser.silentThreshold(for: .custom("myagent")) == 300)
    }
}

// MARK: - Diagnoser.diagnose with explicit silentThreshold

@Suite("Diagnoser.diagnose with silentThreshold")
struct DiagnoserDiagnoseThresholdTests {

    @Test("Small threshold classifies working agent as silent")
    func smallThresholdClassifiesSilent() async {
        let diagnoser = Diagnoser()
        let agentId = AgentID("w1:p1")
        let agent = Agent(
            id: agentId,
            kind: .claude,
            status: .working,
            enteredAt: Date().addingTimeInterval(-60),
            lastOutputAt: Date().addingTimeInterval(-10) // 10 seconds ago
        )
        
        let adapter = MockHerdrAdapter(
            processInfoResult: ProcessInfoResult(
                shellPid: 123,
                foregroundProcesses: [ForegroundProcess(pid: 456, name: "node", argv0: nil, cmdline: nil, cwd: nil)]
            )
        )
        
        // With a 5-second threshold, 10 seconds of silence should trigger .silent
        let verdict = await diagnoser.diagnose(agent: agent, adapter: adapter, silentThreshold: 5)
        #expect(verdict.isSilent)
    }

    @Test("Nil lastOutputAt uses enteredAt as the silent clock")
    func silentClockFallsBackToEnteredAt() async {
        let diagnoser = Diagnoser()
        let agent = Agent(
            id: AgentID("w1:p1"),
            kind: .claude,
            status: .working,
            enteredAt: Date().addingTimeInterval(-10),
            lastOutputAt: nil
        )
        let adapter = MockHerdrAdapter(
            processInfoResult: ProcessInfoResult(
                shellPid: 123,
                foregroundProcesses: [ForegroundProcess(pid: 456, name: "node", argv0: nil, cmdline: nil, cwd: nil)]
            )
        )
        let verdict = await diagnoser.diagnose(agent: agent, adapter: adapter, silentThreshold: 5)
        #expect(verdict.isSilent)
    }

    @Test("Output from before the current working episode does not start the silent clock")
    func priorEpisodeOutputIsNotSilence() async {
        // Blocked on a prompt for 20 minutes, then approved: the pane has
        // been working again for 30s, but lastOutputAt still holds the last
        // heartbeat change from before the prompt. That is not 20m of silence.
        let agent = Agent(
            id: AgentID("w1:p1"),
            kind: .claude,
            status: .working,
            enteredAt: Date().addingTimeInterval(-30),
            lastOutputAt: Date().addingTimeInterval(-20 * 60)
        )
        let adapter = MockHerdrAdapter(
            processInfoResult: ProcessInfoResult(
                shellPid: 123,
                foregroundProcesses: [ForegroundProcess(pid: 456, name: "node", argv0: nil, cmdline: nil, cwd: nil)]
            )
        )
        let verdict = await Diagnoser().diagnose(agent: agent, adapter: adapter)
        #expect(!verdict.isSilent)
    }

    @Test("Silence in a new working episode is measured from the episode start")
    func silentSinceIsEpisodeStart() async {
        let entered = Date().addingTimeInterval(-600)
        let agent = Agent(
            id: AgentID("w1:p1"),
            kind: .claude,
            status: .working,
            enteredAt: entered,
            lastOutputAt: entered.addingTimeInterval(-3600)
        )
        let adapter = MockHerdrAdapter(
            processInfoResult: ProcessInfoResult(
                shellPid: 123,
                foregroundProcesses: [ForegroundProcess(pid: 456, name: "node", argv0: nil, cmdline: nil, cwd: nil)]
            )
        )
        let verdict = await Diagnoser().diagnose(agent: agent, adapter: adapter)
        guard case .silent(let since, _) = verdict else {
            Issue.record("Expected silent, got \(verdict)")
            return
        }
        #expect(since == entered)
    }

    @Test("Output inside the current episode still drives the silent clock")
    func inEpisodeOutputDrivesSilentClock() async {
        let lastOutput = Date().addingTimeInterval(-400)
        let agent = Agent(
            id: AgentID("w1:p1"),
            kind: .claude,
            status: .working,
            enteredAt: Date().addingTimeInterval(-3600),
            lastOutputAt: lastOutput
        )
        let adapter = MockHerdrAdapter(
            processInfoResult: ProcessInfoResult(
                shellPid: 123,
                foregroundProcesses: [ForegroundProcess(pid: 456, name: "node", argv0: nil, cmdline: nil, cwd: nil)]
            )
        )
        let verdict = await Diagnoser().diagnose(agent: agent, adapter: adapter)
        guard case .silent(let since, _) = verdict else {
            Issue.record("Expected silent, got \(verdict)")
            return
        }
        #expect(since == lastOutput)
    }

    @Test("Blocked is awaiting input, not silent, even with a stale lastOutputAt")
    func blockedIsNotSilent() async {
        let diagnoser = Diagnoser()
        let agent = Agent(
            id: AgentID("w1:p1"),
            kind: .claude,
            status: .blocked,
            lastOutputAt: Date().addingTimeInterval(-400)
        )
        let adapter = MockHerdrAdapter(
            explainResult: AgentExplainResult(
                agent: "claude",
                state: "permission",
                matchedRuleId: "bash_permission_prompt",
                matchedRulePriority: 1,
                screenDetectionSkipped: false
            ),
            processInfoResult: ProcessInfoResult(
                shellPid: 123,
                foregroundProcesses: [ForegroundProcess(pid: 456, name: "node", argv0: nil, cmdline: nil, cwd: nil)]
            )
        )
        let verdict = await diagnoser.diagnose(agent: agent, adapter: adapter, silentThreshold: 5)
        #expect(verdict.isAwaitingInput)
        #expect(!verdict.isSilent)
    }

    @Test("Large threshold does not classify working agent as silent")
    func largeThresholdDoesNotClassifySilent() async {
        let diagnoser = Diagnoser()
        let agentId = AgentID("w1:p1")
        let agent = Agent(
            id: agentId,
            kind: .claude,
            status: .working,
            lastOutputAt: Date().addingTimeInterval(-10) // 10 seconds ago
        )
        
        let adapter = MockHerdrAdapter(
            processInfoResult: ProcessInfoResult(
                shellPid: 123,
                foregroundProcesses: [ForegroundProcess(pid: 456, name: "node", argv0: nil, cmdline: nil, cwd: nil)]
            )
        )
        
        // With a 60-second threshold, 10 seconds of silence should NOT trigger .silent
        let verdict = await diagnoser.diagnose(agent: agent, adapter: adapter, silentThreshold: 60)
        #expect(!verdict.isSilent)
    }
}

// MARK: - Diagnoser cpuState with foreground processes

@Suite("Diagnoser cpuState with foreground processes")
struct DiagnoserCpuStateTests {

    @Test("Busy foreground process is measured")
    func busyForegroundProcess() async {
        let diagnoser = Diagnoser()
        let agentId = AgentID("w1:p1")
        let agent = Agent(
            id: agentId,
            kind: .claude,
            status: .working,
            enteredAt: Date().addingTimeInterval(-3600),
            lastOutputAt: Date().addingTimeInterval(-400) // 400 seconds ago to trigger silent
        )
        
        // Mock adapter returns a foreground process (node)
        let adapter = MockHerdrAdapter(
            processInfoResult: ProcessInfoResult(
                shellPid: 123,
                foregroundProcesses: [
                    ForegroundProcess(pid: 456, name: "node", argv0: nil, cmdline: nil, cwd: nil)
                ]
            )
        )
        
        // The diagnoser will call ps on pid 456. Since we can't control ps output in a unit test,
        // we just verify that the diagnosis completes without error and returns a verdict.
        let verdict = await diagnoser.diagnose(agent: agent, adapter: adapter)
        // Should be silent (400s > 300s default threshold)
        #expect(verdict.isSilent)
    }

    @Test("Empty foreground processes returns unknown CPU state")
    func emptyForegroundProcessesReturnsUnknown() async {
        let diagnoser = Diagnoser()
        let agentId = AgentID("w1:p1")
        let agent = Agent(
            id: agentId,
            kind: .claude,
            status: .working,
            enteredAt: Date().addingTimeInterval(-3600),
            lastOutputAt: Date().addingTimeInterval(-400) // 400 seconds ago to trigger silent
        )
        
        // Mock adapter returns empty foreground processes
        let adapter = MockHerdrAdapter(
            processInfoResult: ProcessInfoResult(
                shellPid: 123,
                foregroundProcesses: []
            )
        )
        
        let verdict = await diagnoser.diagnose(agent: agent, adapter: adapter)
        // Should be silent with unknown CPU state
        #expect(verdict.isSilent)
        if case .silent(_, let cpu) = verdict {
            #expect(cpu == .unknown)
        }
    }
}

@Suite("Diagnoser finished vs process-gone")
struct DiagnoserFinishedClassificationTests {
    private let bareShell = ProcessInfoResult(
        shellPid: 10,
        foregroundProcesses: [ForegroundProcess(pid: 10, name: "zsh", argv0: "-zsh", cmdline: nil, cwd: nil)]
    )

    @Test("Done with a bare shell stays healthy, not process-gone or unclassifiable")
    func doneIsHealthy() async {
        let agent = Agent(id: AgentID("w1:p1"), kind: .claude, status: .done)
        let verdict = await Diagnoser().diagnose(
            agent: agent,
            adapter: MockHerdrAdapter(processInfoResult: bareShell)
        )
        #expect(verdict.isHealthy)
        #expect(!verdict.isProcessGone)
        #expect(!verdict.isUnclassifiable)
        #expect(!verdict.isSilent)
    }

    @Test("Idle with a bare shell stays healthy")
    func idleIsHealthy() async {
        let agent = Agent(id: AgentID("w1:p1"), kind: .claude, status: .idle)
        let verdict = await Diagnoser().diagnose(
            agent: agent,
            adapter: MockHerdrAdapter(processInfoResult: bareShell)
        )
        #expect(verdict.isHealthy)
        #expect(!verdict.isProcessGone)
    }

    @Test("Working with a bare shell is process-gone")
    func workingBareShellIsGone() async {
        let agent = Agent(id: AgentID("w1:p1"), kind: .claude, status: .working)
        let verdict = await Diagnoser().diagnose(
            agent: agent,
            adapter: MockHerdrAdapter(processInfoResult: bareShell)
        )
        #expect(verdict.isProcessGone)
    }

    @Test("A process read distinguishes a crash, a live runtime, and an unreadable list")
    func observeProcessGoneDoesNotTreatUnknownAsAlive() async {
        let working = Agent(id: AgentID("w1:p1"), kind: .claude, status: .working)
        let diagnoser = Diagnoser()
        let crashed = await diagnoser.observeProcessGone(agent: working, adapter: MockHerdrAdapter(
            processInfoResult: bareShell
        ))
        #expect(crashed == .gone(lastLine: "zsh (pid 10)"))

        let runtime = ProcessInfoResult(
            shellPid: 10,
            foregroundProcesses: [ForegroundProcess(pid: 456, name: "node", argv0: nil, cmdline: nil, cwd: nil)]
        )
        let alive = await diagnoser.observeProcessGone(agent: working, adapter: MockHerdrAdapter(
            processInfoResult: runtime
        ))
        #expect(alive == .running)

        let unreadable = await diagnoser.observeProcessGone(agent: working, adapter: MockHerdrAdapter(
            processInfoResult: ProcessInfoResult(shellPid: 10, foregroundProcesses: [])
        ))
        #expect(unreadable == .unknown)

        // A thrown read is the same as an empty one: not evidence of life.
        let failed = await diagnoser.observeProcessGone(
            agent: working, adapter: MockHerdrAdapter(processInfoResult: nil)
        )
        #expect(failed == .unknown)

        // Done has legitimately returned to the shell, and the read is not asked.
        let done = Agent(id: AgentID("w1:p1"), kind: .claude, status: .done)
        let finished = await diagnoser.observeProcessGone(
            agent: done, adapter: MockHerdrAdapter(processInfoResult: nil)
        )
        #expect(finished == .running)
    }

    @Test("Nushell, PowerShell, and csh are the shell a crashed agent leaves")
    func configuredShellsAreProcessGone() async {
        let working = Agent(id: AgentID("w1:p1"), kind: .claude, status: .working)
        let diagnoser = Diagnoser()

        func observe(_ processes: [ForegroundProcess]) async -> ProcessGoneObservation {
            await diagnoser.observeProcessGone(
                agent: working,
                adapter: MockHerdrAdapter(processInfoResult: ProcessInfoResult(
                    shellPid: 10,
                    foregroundProcesses: processes
                ))
            )
        }

        // herdr's documented default_shell example. The comm is `nu`.
        let nu = await observe([
            ForegroundProcess(pid: 11, name: "nu", argv0: nil, cmdline: nil, cwd: nil)
        ])
        #expect(nu == .gone(lastLine: "nu (pid 11)"))

        // Login argv0 when the comm is not itself a shell name, including case.
        let login = await observe([
            ForegroundProcess(pid: 12, name: "MainThread", argv0: "-Nu", cmdline: nil, cwd: nil)
        ])
        #expect(login == .gone(lastLine: "MainThread (pid 12)"))
        let homebrew = await observe([
            ForegroundProcess(
                pid: 13, name: "MainThread", argv0: "/opt/homebrew/bin/nu", cmdline: nil, cwd: nil
            )
        ])
        #expect(homebrew == .gone(lastLine: "MainThread (pid 13)"))

        let powershell = await observe([
            ForegroundProcess(
                pid: 14,
                name: "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
                argv0: nil,
                cmdline: nil,
                cwd: nil
            )
        ])
        #expect(powershell == .gone(lastLine: "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe (pid 14)"))
        let pwsh = await observe([
            ForegroundProcess(pid: 15, name: "Pwsh.EXE", argv0: nil, cmdline: nil, cwd: nil)
        ])
        #expect(pwsh == .gone(lastLine: "Pwsh.EXE (pid 15)"))
        let csh = await observe([
            ForegroundProcess(pid: 16, name: "csh", argv0: "-csh", cmdline: nil, cwd: nil)
        ])
        #expect(csh == .gone(lastLine: "csh (pid 16)"))

        // A runtime beside the shell is the agent, not a crash. A name that
        // only starts with `nu`, and tmux, are not this shell.
        let mixed = await observe([
            ForegroundProcess(pid: 11, name: "nu", argv0: nil, cmdline: nil, cwd: nil),
            ForegroundProcess(pid: 17, name: "node", argv0: "/usr/local/bin/node", cmdline: nil, cwd: nil),
        ])
        #expect(mixed == .running)
        let nush = await observe([
            ForegroundProcess(pid: 18, name: "nush", argv0: nil, cmdline: nil, cwd: nil)
        ])
        #expect(nush == .running)
        let tmux = await observe([
            ForegroundProcess(pid: 19, name: "tmux", argv0: "tmux", cmdline: nil, cwd: nil)
        ])
        #expect(tmux == .running)

        // Finished has returned to the shell on purpose. The name is not asked.
        let done = Agent(id: AgentID("w1:p1"), kind: .claude, status: .done)
        let finished = await diagnoser.observeProcessGone(
            agent: done,
            adapter: MockHerdrAdapter(processInfoResult: ProcessInfoResult(
                shellPid: 10,
                foregroundProcesses: [
                    ForegroundProcess(pid: 11, name: "nu", argv0: nil, cmdline: nil, cwd: nil)
                ]
            ))
        )
        #expect(finished == .running)
    }

    @Test("Elvish and xonsh are the shell a crashed agent leaves")
    func elvishAndXonshAreProcessGone() async {
        let working = Agent(id: AgentID("w1:p1"), kind: .claude, status: .working)
        let diagnoser = Diagnoser()

        func observe(_ processes: [ForegroundProcess]) async -> ProcessGoneObservation {
            await diagnoser.observeProcessGone(
                agent: working,
                adapter: MockHerdrAdapter(processInfoResult: ProcessInfoResult(
                    shellPid: 10,
                    foregroundProcesses: processes
                ))
            )
        }

        // herdr's pane-shell check names both. A dead agent leaves that
        // process, including a login argv0, a path, and `.exe`.
        let elvish = await observe([
            ForegroundProcess(pid: 91, name: "elvish", argv0: nil, cmdline: nil, cwd: nil)
        ])
        #expect(elvish == .gone(lastLine: "elvish (pid 91)"))
        let loginElvish = await observe([
            ForegroundProcess(pid: 92, name: "MainThread", argv0: "-elvish", cmdline: nil, cwd: nil)
        ])
        #expect(loginElvish == .gone(lastLine: "MainThread (pid 92)"))
        let elvishPath = await observe([
            ForegroundProcess(
                pid: 93, name: "MainThread", argv0: "/usr/bin/elvish", cmdline: nil, cwd: nil
            )
        ])
        #expect(elvishPath == .gone(lastLine: "MainThread (pid 93)"))
        let xonsh = await observe([
            ForegroundProcess(pid: 94, name: "Xonsh.EXE", argv0: nil, cmdline: nil, cwd: nil)
        ])
        #expect(xonsh == .gone(lastLine: "Xonsh.EXE (pid 94)"))

        // herdr does not unwrap a script on these shells. The path is not
        // the agent, the same as `nu /tmp/claude`.
        let elvishScript = await observe([
            ForegroundProcess(
                pid: 95, name: "elvish", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["elvish", "/usr/bin/claude"]
            )
        ])
        #expect(elvishScript == .gone(lastLine: "elvish (pid 95)"))
        let xonshScript = await observe([
            ForegroundProcess(
                pid: 96, name: "xonsh", argv0: "-xonsh", cmdline: nil, cwd: nil,
                argv: ["-xonsh", "/usr/local/bin/codex"]
            )
        ])
        #expect(xonshScript == .gone(lastLine: "xonsh (pid 96)"))

        // A name that only begins with the shell, and a runtime beside it, stay.
        let elvishrc = await observe([
            ForegroundProcess(pid: 97, name: "elvishrc", argv0: nil, cmdline: nil, cwd: nil)
        ])
        #expect(elvishrc == .running)
        let xonshy = await observe([
            ForegroundProcess(pid: 98, name: "xonshy", argv0: nil, cmdline: nil, cwd: nil)
        ])
        #expect(xonshy == .running)
        let mixed = await observe([
            ForegroundProcess(pid: 91, name: "elvish", argv0: nil, cmdline: nil, cwd: nil),
            ForegroundProcess(pid: 99, name: "node", argv0: "/usr/local/bin/node", cmdline: nil, cwd: nil),
        ])
        #expect(mixed == .running)
    }

    @Test("A shell whose argv launches an agent is still that agent")
    func shellWrapperIsNotProcessGone() async {
        let working = Agent(id: AgentID("w1:p1"), kind: .claude, status: .working)
        let diagnoser = Diagnoser()

        func observe(_ processes: [ForegroundProcess]) async -> ProcessGoneObservation {
            await diagnoser.observeProcessGone(
                agent: working,
                adapter: MockHerdrAdapter(processInfoResult: ProcessInfoResult(
                    shellPid: 10,
                    foregroundProcesses: processes
                ))
            )
        }

        // herdr identifies `sh /path/to/pi` as Pi. The comm is the shell.
        let pi = await observe([
            ForegroundProcess(
                pid: 20, name: "sh", argv0: "/bin/sh", cmdline: nil, cwd: nil,
                argv: ["/bin/sh", "/tmp/test-bin/pi"]
            )
        ])
        #expect(pi == .running)

        // The same fact from cmdline when the payload has no argv.
        let cmdline = await observe([
            ForegroundProcess(
                pid: 21, name: "bash", argv0: nil,
                cmdline: "/bin/bash /usr/local/bin/codex", cwd: nil
            )
        ])
        #expect(cmdline == .running)

        // PowerShell's -File script, including the .ps1 herdr strips, and
        // a -Command whose first program is the agent. A value-taking
        // flag is not that program.
        let file = await observe([
            ForegroundProcess(
                pid: 22, name: "powershell.exe", argv0: nil, cmdline: nil, cwd: nil,
                argv: [
                    "powershell.exe", "-NoProfile", "-File",
                    "C:\\Users\\herdr\\Documents\\PowerShell\\Scripts\\claude.ps1",
                ]
            )
        ])
        #expect(file == .running)
        let command = await observe([
            ForegroundProcess(
                pid: 23, name: "pwsh", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["pwsh", "-WorkingDirectory", "C:\\repo", "-Command", "& claude"]
            )
        ])
        #expect(command == .running)

        // `-c` is an eval. A later path that names an agent is not the program.
        // An encoded blob is not decoded. `nu` is not unwrapped.
        let eval = await observe([
            ForegroundProcess(
                pid: 24, name: "bash", argv0: nil,
                cmdline: "bash -c claude /tmp/codex", cwd: nil,
                argv: ["bash", "-c", "claude", "/tmp/codex"]
            )
        ])
        #expect(eval == .gone(lastLine: "bash (pid 24)"))
        let encoded = await observe([
            ForegroundProcess(
                pid: 25, name: "powershell.exe", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["powershell.exe", "-EncodedCommand", "Y2xhdWRl"]
            )
        ])
        #expect(encoded == .gone(lastLine: "powershell.exe (pid 25)"))
        let nuScript = await observe([
            ForegroundProcess(
                pid: 26, name: "nu", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["nu", "/tmp/claude"]
            )
        ])
        #expect(nuScript == .gone(lastLine: "nu (pid 26)"))

        // `cmd /C` is the Windows wrapper. A bare `cmd.exe` with an argument
        // vector is the prompt. A payload that names cmd and omits the
        // vector stays running: that used to be indistinguishable.
        let cmdWrapped = await observe([
            ForegroundProcess(
                pid: 27, name: "cmd.exe", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["cmd.exe", "/D", "/C", "C:\\npm\\codex.cmd --model gpt-5"]
            )
        ])
        #expect(cmdWrapped == .running)
        let cmdPrompt = await observe([
            ForegroundProcess(
                pid: 28, name: "C:\\Windows\\System32\\cmd.exe", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["C:\\Windows\\System32\\cmd.exe"]
            )
        ])
        #expect(cmdPrompt == .gone(lastLine: "C:\\Windows\\System32\\cmd.exe (pid 28)"))
        let cmdUnspecified = await observe([
            ForegroundProcess(pid: 29, name: "cmd.exe", argv0: nil, cmdline: nil, cwd: nil)
        ])
        #expect(cmdUnspecified == .running)

        // argv wins over a cmdline that names an agent. The eval is the vector.
        let argvWins = await observe([
            ForegroundProcess(
                pid: 30, name: "sh", argv0: "/bin/sh",
                cmdline: "/bin/sh /usr/bin/claude", cwd: nil,
                argv: ["sh", "-c", "sleep 60"]
            )
        ])
        #expect(argvWins == .gone(lastLine: "sh (pid 30)"))
    }

    @Test("A package entrypoint herdr names is not a crashed agent")
    func packageEntrypointIsNotProcessGone() async {
        let working = Agent(id: AgentID("w1:p1"), kind: .claude, status: .working)
        let diagnoser = Diagnoser()

        func observe(
            _ argv: [String],
            pid: Int32 = 40,
            name: String = "sh"
        ) async -> ProcessGoneObservation {
            await diagnoser.observeProcessGone(
                agent: working,
                adapter: MockHerdrAdapter(processInfoResult: ProcessInfoResult(
                    shellPid: 10,
                    foregroundProcesses: [
                        ForegroundProcess(
                            pid: pid, name: name, argv0: nil, cmdline: nil, cwd: nil,
                            argv: argv
                        )
                    ]
                ))
            )
        }

        let pi = "/usr/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
        let piBundle = "C:\\Users\\herdr\\AppData\\Local\\pi-node\\current/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
        let omp = "C:\\Users\\herdr\\AppData\\Roaming\\npm\\node_modules\\@oh-my-pi\\pi-coding-agent\\dist\\cli.js"
        let kimi = "C:\\repro\\node_modules\\@moonshot-ai\\kimi-code\\dist\\main.mjs"
        let qwen = "/home/user/.npm/lib/node_modules/@qwen-code/qwen-code/dist/index.js"
        let mastracode = "C:\\npm\\node_modules\\mastracode\\dist\\cli.js"
        let letta = "/usr/lib/node_modules/@letta-ai/letta-code/letta.js"

        let piLaunch = await observe(["/bin/sh", pi])
        #expect(piLaunch == .running)
        let bundled = await observe(["bash", "-euo", "pipefail", piBundle], name: "bash")
        #expect(bundled == .running)
        let ompLaunch = await observe(["dash", omp], name: "dash")
        #expect(ompLaunch == .running)
        let kimiLaunch = await observe(["pwsh", "-File", kimi], name: "pwsh")
        #expect(kimiLaunch == .running)
        let kimiColon = await observe(
            ["powershell.exe", "-File:C:\\repro\\node_modules\\@moonshot-ai\\kimi-code\\dist\\Main.MJS"],
            name: "powershell.exe"
        )
        #expect(kimiColon == .running)
        let qwenLaunch = await observe(["/bin/bash", qwen], name: "bash")
        #expect(qwenLaunch == .running)
        let mastraLaunch = await observe(["cmd.exe", "/C", mastracode], name: "cmd.exe")
        #expect(mastraLaunch == .running)
        let lettaLaunch = await observe(["zsh", letta], name: "zsh")
        #expect(lettaLaunch == .running)

        // The basename alone is not the agent. A sibling script in the
        // same package is not either, and neither is `cli.exe` or a path
        // that only continues past `cli.js`. `-c` is still an eval.
        let bareCli = await observe(["sh", "/tmp/cli.js"], pid: 41)
        #expect(bareCli == .gone(lastLine: "sh (pid 41)"))
        let setup = await observe(
            ["sh", "C:\\workspace\\node_modules\\@oh-my-pi\\pi-coding-agent\\dist\\setup.js"],
            pid: 42
        )
        #expect(setup == .gone(lastLine: "sh (pid 42)"))
        let cliExe = await observe(
            ["sh", "C:\\workspace\\node_modules\\@earendil-works\\pi-coding-agent\\dist\\cli.exe"],
            pid: 43
        )
        #expect(cliExe == .gone(lastLine: "sh (pid 43)"))
        let continued = await observe(
            ["sh", "C:\\workspace\\node_modules\\@earendil-works\\pi-coding-agent\\dist\\cli.js\\other.js"],
            pid: 44
        )
        #expect(continued == .gone(lastLine: "sh (pid 44)"))
        let shortBundle = await observe(["sh", "C:\\workspace\\dist\\bundle\\cli.js"], pid: 45)
        #expect(shortBundle == .gone(lastLine: "sh (pid 45)"))
        let evalScript = await observe(["sh", "-c", pi], pid: 46)
        #expect(evalScript == .gone(lastLine: "sh (pid 46)"))
        let nuScript = await observe(["nu", pi], pid: 47, name: "nu")
        #expect(nuScript == .gone(lastLine: "nu (pid 47)"))
        let bareMjs = await observe(["sh", "/tmp/main.mjs"], pid: 48)
        #expect(bareMjs == .gone(lastLine: "sh (pid 48)"))
        let bareIndex = await observe(["sh", "/tmp/index.js"], pid: 49)
        #expect(bareIndex == .gone(lastLine: "sh (pid 49)"))
    }

    @Test("A shell option is not the program, and dash, ksh, and csh still launch one")
    func shellOptionAndSiblingShellsLaunchAgents() async {
        let working = Agent(id: AgentID("w1:p1"), kind: .claude, status: .working)
        let diagnoser = Diagnoser()

        func observe(_ processes: [ForegroundProcess]) async -> ProcessGoneObservation {
            await diagnoser.observeProcessGone(
                agent: working,
                adapter: MockHerdrAdapter(processInfoResult: ProcessInfoResult(
                    shellPid: 10,
                    foregroundProcesses: processes
                ))
            )
        }

        // `-o` names an option. The program is the word after that.
        let bashOption = await observe([
            ForegroundProcess(
                pid: 40, name: "bash", argv0: "/bin/bash", cmdline: nil, cwd: nil,
                argv: ["/bin/bash", "-o", "errexit", "/usr/local/bin/claude"]
            )
        ])
        #expect(bashOption == .running)
        let zshShopt = await observe([
            ForegroundProcess(
                pid: 41, name: "zsh", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["zsh", "-O", "shwordsplit", "/usr/bin/codex"]
            )
        ])
        #expect(zshShopt == .running)
        // The option can sit in front of an eval. The eval is still not a program.
        let optionThenEval = await observe([
            ForegroundProcess(
                pid: 42, name: "bash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["bash", "-o", "errexit", "-c", "claude"]
            )
        ])
        #expect(optionThenEval == .gone(lastLine: "bash (pid 42)"))
        // The word after `-o` is the option name, even when that name is an agent.
        let optionNamedClaude = await observe([
            ForegroundProcess(
                pid: 43, name: "bash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["bash", "-o", "claude"]
            )
        ])
        #expect(optionNamedClaude == .gone(lastLine: "bash (pid 43)"))
        // `--rcfile` is a file. The program is the next word, and a missing
        // program is the shell even when the file's basename is an agent.
        let rcfile = await observe([
            ForegroundProcess(
                pid: 44, name: "bash", argv0: nil,
                cmdline: "bash --rcfile /tmp/init /usr/bin/claude", cwd: nil
            )
        ])
        #expect(rcfile == .running)
        let rcfileOnly = await observe([
            ForegroundProcess(
                pid: 45, name: "bash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["bash", "--init-file", "/tmp/claude"]
            )
        ])
        #expect(rcfileOnly == .gone(lastLine: "bash (pid 45)"))

        // These are already crash shells. A script path is the agent.
        let dashScript = await observe([
            ForegroundProcess(
                pid: 46, name: "dash", argv0: "/bin/dash", cmdline: nil, cwd: nil,
                argv: ["/bin/dash", "/tmp/test-bin/pi"]
            )
        ])
        #expect(dashScript == .running)
        let kshScript = await observe([
            ForegroundProcess(
                pid: 47, name: "ksh", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["ksh", "/usr/local/bin/codex"]
            )
        ])
        #expect(kshScript == .running)
        let kshEval = await observe([
            ForegroundProcess(
                pid: 48, name: "ksh", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["ksh", "-c", "/tmp/codex"]
            )
        ])
        #expect(kshEval == .gone(lastLine: "ksh (pid 48)"))
        let cshScript = await observe([
            ForegroundProcess(
                pid: 49, name: "csh", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["csh", "/usr/bin/claude"]
            )
        ])
        #expect(cshScript == .running)
        let tcshFast = await observe([
            ForegroundProcess(
                pid: 50, name: "tcsh", argv0: "-tcsh", cmdline: nil, cwd: nil,
                argv: ["-tcsh", "-f", "/usr/bin/gemini"]
            )
        ])
        #expect(tcshFast == .running)
        // csh has no `-o` option value, so the next word is still the program.
        let cshFlag = await observe([
            ForegroundProcess(
                pid: 51, name: "csh", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["csh", "-o", "/usr/bin/claude"]
            )
        ])
        #expect(cshFlag == .running)
        // dash takes `-o` and does not take `-O`.
        let dashOption = await observe([
            ForegroundProcess(
                pid: 52, name: "dash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["dash", "-o", "errexit", "/tmp/pi"]
            )
        ])
        #expect(dashOption == .running)
        let dashCapital = await observe([
            ForegroundProcess(
                pid: 53, name: "dash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["dash", "-O", "extglob", "/tmp/claude"]
            )
        ])
        #expect(dashCapital == .gone(lastLine: "dash (pid 53)"))
        // ksh and fish take `-o`. fish does not take `-O`.
        let kshOption = await observe([
            ForegroundProcess(
                pid: 54, name: "ksh", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["ksh", "-o", "errexit", "/usr/local/bin/codex"]
            )
        ])
        #expect(kshOption == .running)
        let fishOption = await observe([
            ForegroundProcess(
                pid: 55, name: "fish", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["fish", "-o", "errexit", "/usr/bin/claude"]
            )
        ])
        #expect(fishOption == .running)
        let fishCapital = await observe([
            ForegroundProcess(
                pid: 56, name: "fish", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["fish", "-O", "extglob", "/usr/bin/claude"]
            )
        ])
        #expect(fishCapital == .gone(lastLine: "fish (pid 56)"))
    }

    @Test("A clustered shell option is not the program, and ash and mksh still launch one")
    func clusteredShellOptionIsNotTheProgram() async {
        let working = Agent(id: AgentID("w1:p1"), kind: .claude, status: .working)
        let diagnoser = Diagnoser()

        func observe(_ processes: [ForegroundProcess]) async -> ProcessGoneObservation {
            await diagnoser.observeProcessGone(
                agent: working,
                adapter: MockHerdrAdapter(processInfoResult: ProcessInfoResult(
                    shellPid: 10,
                    foregroundProcesses: processes
                ))
            )
        }

        // `-euo pipefail` is one cluster. The option name is not the program.
        let bashCluster = await observe([
            ForegroundProcess(
                pid: 60, name: "bash", argv0: "/bin/bash", cmdline: nil, cwd: nil,
                argv: ["/bin/bash", "-euo", "pipefail", "/usr/local/bin/claude"]
            )
        ])
        #expect(bashCluster == .running)
        let cmdlineCluster = await observe([
            ForegroundProcess(
                pid: 61, name: "sh", argv0: nil,
                cmdline: "sh -euo pipefail /usr/bin/claude", cwd: nil
            )
        ])
        #expect(cmdlineCluster == .running)
        // No program after the option name. The shell is bare.
        let clusterOnly = await observe([
            ForegroundProcess(
                pid: 62, name: "bash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["bash", "-euo", "pipefail"]
            )
        ])
        #expect(clusterOnly == .gone(lastLine: "bash (pid 62)"))
        // The option can sit in front of an eval. The eval is still not a program.
        let clusterThenEval = await observe([
            ForegroundProcess(
                pid: 63, name: "bash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["bash", "-euo", "pipefail", "-c", "claude"]
            )
        ])
        #expect(clusterThenEval == .gone(lastLine: "bash (pid 63)"))
        // Flag letters may follow `-o`. The next word is still the name.
        let optionBeforeFlags = await observe([
            ForegroundProcess(
                pid: 64, name: "bash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["bash", "-oeu", "pipefail", "/usr/bin/claude"]
            )
        ])
        #expect(optionBeforeFlags == .running)
        // `-oerrexit` is not a glued option name. The next word is that name.
        let gluedName = await observe([
            ForegroundProcess(
                pid: 164, name: "bash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["bash", "-oerrexit", "/usr/bin/claude"]
            )
        ])
        #expect(gluedName == .gone(lastLine: "bash (pid 164)"))
        // fish keeps an attached value in the cluster, so the next word is the program.
        let fishAttached = await observe([
            ForegroundProcess(
                pid: 165, name: "fish", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["fish", "-d3", "/usr/bin/claude"]
            )
        ])
        #expect(fishAttached == .running)
        // `+o` turns the option off. The next word is still the name, not the program.
        let plus = await observe([
            ForegroundProcess(
                pid: 65, name: "zsh", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["zsh", "+o", "nomatch", "/usr/bin/codex"]
            )
        ])
        #expect(plus == .running)
        let plusCluster = await observe([
            ForegroundProcess(
                pid: 66, name: "zsh", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["zsh", "+euo", "pipefail", "/usr/bin/codex"]
            )
        ])
        #expect(plusCluster == .running)
        let plusShopt = await observe([
            ForegroundProcess(
                pid: 67, name: "bash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["bash", "+O", "extglob", "/usr/bin/claude"]
            )
        ])
        #expect(plusShopt == .running)
        // A trailing `c` leaves the next word as the program. A `c` before
        // a final `-o` does not: `pipefail` is the option name, and claude
        // is still the program. With no name in between, `-o` takes the path.
        let trailingEval = await observe([
            ForegroundProcess(
                pid: 68, name: "bash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["bash", "-lc", "/usr/bin/claude"]
            )
        ])
        #expect(trailingEval == .running)
        let optionAfterEvalFlag = await observe([
            ForegroundProcess(
                pid: 69, name: "bash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["bash", "-xco", "pipefail", "/usr/bin/claude"]
            )
        ])
        #expect(optionAfterEvalFlag == .running)
        let optionTakesPath = await observe([
            ForegroundProcess(
                pid: 69, name: "bash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["bash", "-xco", "/usr/bin/claude"]
            )
        ])
        #expect(optionTakesPath == .gone(lastLine: "bash (pid 69)"))

        // dash takes `-o` inside a cluster and does not take `-O`.
        let dashCluster = await observe([
            ForegroundProcess(
                pid: 70, name: "dash", argv0: "/bin/dash", cmdline: nil, cwd: nil,
                argv: ["/bin/dash", "-euo", "pipefail", "/tmp/pi"]
            )
        ])
        #expect(dashCluster == .running)
        let dashCapitalCluster = await observe([
            ForegroundProcess(
                pid: 71, name: "dash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["dash", "-eO", "extglob", "/tmp/claude"]
            )
        ])
        #expect(dashCapitalCluster == .gone(lastLine: "dash (pid 71)"))
        // ksh takes `-O` at the end of a cluster.
        let kshCapitalCluster = await observe([
            ForegroundProcess(
                pid: 72, name: "ksh", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["ksh", "-eO", "shwordsplit", "/usr/bin/codex"]
            )
        ])
        #expect(kshCapitalCluster == .running)
        // csh has no option value, so the word after the cluster is the program.
        let cshCluster = await observe([
            ForegroundProcess(
                pid: 73, name: "csh", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["csh", "-euo", "pipefail", "/usr/bin/claude"]
            )
        ])
        #expect(cshCluster == .gone(lastLine: "csh (pid 73)"))

        // fish's debug and profile flags take a value. `=` keeps it in the word.
        let fishDebug = await observe([
            ForegroundProcess(
                pid: 74, name: "fish", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["fish", "-d", "3", "/usr/bin/claude"]
            )
        ])
        #expect(fishDebug == .running)
        let fishProfile = await observe([
            ForegroundProcess(
                pid: 75, name: "fish", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["fish", "--profile", "/tmp/start.prof", "/usr/bin/claude"]
            )
        ])
        #expect(fishProfile == .running)
        let fishInit = await observe([
            ForegroundProcess(
                pid: 76, name: "fish", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["fish", "--init-command", "set -x FOO 1", "/usr/bin/claude"]
            )
        ])
        #expect(fishInit == .running)
        let fishDebugEquals = await observe([
            ForegroundProcess(
                pid: 77, name: "fish", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["fish", "--debug=3", "/usr/bin/claude"]
            )
        ])
        #expect(fishDebugEquals == .running)
        // fish's `-o` is not `+o`. The word is not a program, and it is not an option value.
        let fishPlus = await observe([
            ForegroundProcess(
                pid: 78, name: "fish", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["fish", "+o", "/usr/bin/claude"]
            )
        ])
        #expect(fishPlus == .gone(lastLine: "fish (pid 78)"))

        // herdr launches ash and mksh as login shells. A bare one is the crash.
        // A script path is the agent. mksh does not take bash's `-O`.
        let ash = await observe([
            ForegroundProcess(pid: 80, name: "ash", argv0: nil, cmdline: nil, cwd: nil)
        ])
        #expect(ash == .gone(lastLine: "ash (pid 80)"))
        let ashPath = await observe([
            ForegroundProcess(
                pid: 81, name: "MainThread", argv0: "/bin/ash", cmdline: nil, cwd: nil
            )
        ])
        #expect(ashPath == .gone(lastLine: "MainThread (pid 81)"))
        let mkshLogin = await observe([
            ForegroundProcess(pid: 82, name: "MainThread", argv0: "-mksh", cmdline: nil, cwd: nil)
        ])
        #expect(mkshLogin == .gone(lastLine: "MainThread (pid 82)"))
        let mkshExe = await observe([
            ForegroundProcess(pid: 83, name: "Mksh.EXE", argv0: nil, cmdline: nil, cwd: nil)
        ])
        #expect(mkshExe == .gone(lastLine: "Mksh.EXE (pid 83)"))
        let ashScript = await observe([
            ForegroundProcess(
                pid: 84, name: "ash", argv0: "/bin/ash", cmdline: nil, cwd: nil,
                argv: ["/bin/ash", "/tmp/test-bin/pi"]
            )
        ])
        #expect(ashScript == .running)
        let mkshOption = await observe([
            ForegroundProcess(
                pid: 85, name: "mksh", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["mksh", "-o", "errexit", "/usr/local/bin/codex"]
            )
        ])
        #expect(mkshOption == .running)
        let ashCluster = await observe([
            ForegroundProcess(
                pid: 86, name: "ash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["ash", "-euo", "pipefail", "/tmp/pi"]
            )
        ])
        #expect(ashCluster == .running)
        let mkshCapital = await observe([
            ForegroundProcess(
                pid: 87, name: "mksh", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["mksh", "-O", "extglob", "/usr/bin/claude"]
            )
        ])
        #expect(mkshCapital == .gone(lastLine: "mksh (pid 87)"))
        let ashEval = await observe([
            ForegroundProcess(
                pid: 88, name: "ash", argv0: nil, cmdline: nil, cwd: nil,
                argv: ["ash", "-c", "/tmp/codex"]
            )
        ])
        #expect(ashEval == .gone(lastLine: "ash (pid 88)"))
        // A name that only begins with the shell, and a runtime beside it, stay.
        let ashley = await observe([
            ForegroundProcess(pid: 89, name: "ashley", argv0: nil, cmdline: nil, cwd: nil)
        ])
        #expect(ashley == .running)
        let mixed = await observe([
            ForegroundProcess(pid: 80, name: "ash", argv0: nil, cmdline: nil, cwd: nil),
            ForegroundProcess(pid: 90, name: "node", argv0: "/usr/local/bin/node", cmdline: nil, cwd: nil),
        ])
        #expect(mixed == .running)
    }

    @Test("A spaced agent basename herdr looks up is not a crashed agent")
    func spacedAgentBasenameIsNotProcessGone() async {
        let working = Agent(id: AgentID("w1:p1"), kind: .custom("kimi"), status: .working)
        let diagnoser = Diagnoser()

        func observe(
            _ argv: [String],
            pid: Int32 = 70,
            name: String = "pwsh"
        ) async -> ProcessGoneObservation {
            await diagnoser.observeProcessGone(
                agent: working,
                adapter: MockHerdrAdapter(processInfoResult: ProcessInfoResult(
                    shellPid: 10,
                    foregroundProcesses: [
                        ForegroundProcess(
                            pid: pid, name: name, argv0: nil, cmdline: nil, cwd: nil,
                            argv: argv
                        )
                    ]
                ))
            )
        }

        // herdr's lookup names these with a space. The hyphenated form was
        // already an agent; `Kimi Code.exe` was the shell the agent left.
        let kimi = await observe([
            "powershell.exe", "-File",
            "C:\\Program Files\\Kimi Code\\Kimi Code.exe",
        ], name: "powershell.exe")
        #expect(kimi == .running)
        let qwen = await observe([
            "pwsh", "-File", "D:\\Apps\\Qwen Code.cmd",
        ])
        #expect(qwen == .running)
        let letta = await observe([
            "/bin/zsh", "/opt/letta/Letta Code.js",
        ], name: "zsh")
        #expect(letta == .running)
        let kilo = await observe([
            "bash", "/usr/local/bin/Kilo Code",
        ], name: "bash")
        #expect(kilo == .running)
        let mastra = await observe([
            "cmd.exe", "/C", "\"C:\\Tools\\Mastra Code.bat\"",
        ], name: "cmd.exe")
        #expect(mastra == .running)
        let devin = await observe([
            "cmd.exe", "/K", "\"Devin CLI.exe\" --resume",
        ], pid: 71, name: "cmd.exe")
        #expect(devin == .running)

        // A longer basename is not that lookup, and neither is a note
        // after the name. The shell is still the crash.
        let longer = await observe([
            "sh", "/tmp/kimi code extra",
        ], pid: 72, name: "sh")
        #expect(longer == .gone(lastLine: "sh (pid 72)"))
        let coder = await observe([
            "pwsh", "-File", "C:\\Program Files\\Kimi Coder.exe",
        ], pid: 73)
        #expect(coder == .gone(lastLine: "pwsh (pid 73)"))
        let helper = await observe([
            "bash", "/usr/local/bin/devin-cli-helper",
        ], pid: 74, name: "bash")
        #expect(helper == .gone(lastLine: "bash (pid 74)"))
    }

    @Test("A symlink to an agent basename is not a crashed agent")
    func symlinkToAgentBasenameIsNotProcessGone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr-agent-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func place(_ name: String, body: String = "#!/bin/sh\n") throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(body.utf8).write(to: url)
            return url
        }
        func link(named name: String, to target: URL) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            return url
        }

        let cursor = try place("cursor-agent")
        let cursorLink = try link(named: "agent", to: cursor)
        let muse = try place("muse-bin-1.2.3")
        let museLink = try link(named: "launcher", to: muse)
        let spaced = try place("Kimi Code")
        let spacedLink = try link(named: "tool", to: spaced)
        let script = try place("claude.js", body: "")
        let scriptLink = try link(named: "wrapper", to: script)
        let notes = try place("notes.txt", body: "hello")
        let notesLink = try link(named: "helper", to: notes)
        // The target is an entrypoint herdr names. The link's own path is
        // not, and canonicalizing only checks the target's basename.
        let cli = root
            .appendingPathComponent("node_modules")
            .appendingPathComponent("@earendil-works")
            .appendingPathComponent("pi-coding-agent")
            .appendingPathComponent("dist")
            .appendingPathComponent("cli.js")
        try FileManager.default.createDirectory(
            at: cli.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: cli)
        let cliLink = try link(named: "pi-shim", to: cli)

        let working = Agent(id: AgentID("w1:p1"), kind: .custom("cursor"), status: .working)
        let diagnoser = Diagnoser()
        func observe(
            _ argv: [String],
            pid: Int32,
            name: String
        ) async -> ProcessGoneObservation {
            await diagnoser.observeProcessGone(
                agent: working,
                adapter: MockHerdrAdapter(processInfoResult: ProcessInfoResult(
                    shellPid: 10,
                    foregroundProcesses: [
                        ForegroundProcess(
                            pid: pid, name: name, argv0: nil, cmdline: nil, cwd: nil,
                            argv: argv
                        )
                    ]
                ))
            )
        }

        // herdr canonicalizes the script a `#!/bin/sh` wrapper is still
        // running. The link name is not the agent; the target's is.
        let shCursor = await observe(
            ["/bin/sh", cursorLink.path], pid: 91, name: "sh"
        )
        #expect(shCursor == .running)
        let museLaunch = await observe(
            ["/bin/bash", museLink.path], pid: 92, name: "bash"
        )
        #expect(museLaunch == .running)
        let spacedLaunch = await observe(
            ["zsh", spacedLink.path], pid: 93, name: "zsh"
        )
        #expect(spacedLaunch == .running)
        // One suffix herdr strips, after the link is resolved.
        let suffix = await observe(
            ["pwsh", "-File", scriptLink.path], pid: 94, name: "pwsh"
        )
        #expect(suffix == .running)

        // The target's basename is not an agent. A package path that
        // exists only after the link is followed is not re-checked:
        // herdr canonicalizes the basename and leaves the package
        // match on the path it was given.
        let notesLaunch = await observe(
            ["sh", notesLink.path], pid: 95, name: "sh"
        )
        #expect(notesLaunch == .gone(lastLine: "sh (pid 95)"))
        let packageAfterLink = await observe(
            ["sh", cliLink.path], pid: 96, name: "sh"
        )
        #expect(packageAfterLink == .gone(lastLine: "sh (pid 96)"))
        // A relative path is not resolved against this process's directory.
        let relative = await observe(
            ["sh", "agent"], pid: 97, name: "sh"
        )
        #expect(relative == .gone(lastLine: "sh (pid 97)"))
        let missing = await observe(
            ["sh", root.appendingPathComponent("missing-helper").path],
            pid: 98,
            name: "sh"
        )
        #expect(missing == .gone(lastLine: "sh (pid 98)"))
    }

    @Test("Blocked with a bare shell is process-gone, not awaiting input")
    func blockedBareShellIsGone() async {
        let agent = Agent(id: AgentID("w1:p1"), kind: .claude, status: .blocked)
        let adapter = MockHerdrAdapter(
            explainResult: AgentExplainResult(
                agent: "claude",
                state: "permission",
                matchedRuleId: "bash_permission_prompt",
                matchedRulePriority: 1,
                screenDetectionSkipped: false
            ),
            processInfoResult: bareShell
        )
        let verdict = await Diagnoser().diagnose(agent: agent, adapter: adapter)
        #expect(verdict.isProcessGone)
        #expect(!verdict.isAwaitingInput)
    }
}

@Suite("Process-gone stamp")
struct ProcessGoneStampTests {
    private let now = Date(timeIntervalSince1970: 8_000)

    @Test("A PowerShell parameter value is not the program")
    func powershellParameterValueIsNotTheProgram() async {
        let working = Agent(id: AgentID("w1:p1"), kind: .claude, status: .working)
        let diagnoser = Diagnoser()

        func observe(_ argv: [String], pid: Int32 = 90, name: String = "pwsh") async -> ProcessGoneObservation {
            await diagnoser.observeProcessGone(
                agent: working,
                adapter: MockHerdrAdapter(processInfoResult: ProcessInfoResult(
                    shellPid: 10,
                    foregroundProcesses: [
                        ForegroundProcess(
                            pid: pid, name: name, argv0: nil, cmdline: nil, cwd: nil,
                            argv: argv
                        )
                    ]
                ))
            )
        }

        // `-InputFormat Text` used to be the program, so the `-File` script
        // never got looked at and a live agent was gone.
        let inputFormat = await observe([
            "pwsh", "-NoProfile", "-InputFormat", "Text", "-File", "claude.ps1",
        ])
        #expect(inputFormat == .running)
        let shortInput = await observe([
            "pwsh", "-if", "XML", "-File", "/usr/local/bin/claude",
        ])
        #expect(shortInput == .running)
        let outputFormat = await observe([
            "pwsh", "-o", "XML", "-c", "& claude",
        ])
        #expect(outputFormat == .running)
        let policy = await observe([
            "pwsh", "-ep", "Bypass", "-File", "C:\\Scripts\\claude.ps1",
        ])
        #expect(policy == .running)
        let directory = await observe([
            "pwsh", "-wd", "C:\\repo", "-w", "Hidden", "-File", "codex.ps1",
        ])
        #expect(directory == .running)
        let settings = await observe([
            "pwsh", "-SettingsFile", "C:\\cfg\\powershell.config.json",
            "-CustomPipeName", "MyDebugPipe", "-config", "AdminRoles",
            "-File", "claude.ps1",
        ])
        #expect(settings == .running)

        // Windows PowerShell 5.1 uses the long names. cmd.exe uses `/`.
        let windows = await observe(
            [
                "powershell.exe", "-Version", "5.1", "-InputFormat", "Text",
                "-OutputFormat", "XML", "-File", "claude.ps1",
            ],
            pid: 91,
            name: "powershell.exe"
        )
        #expect(windows == .running)
        let slash = await observe(
            [
                "powershell.exe", "/InputFormat", "Text", "/File",
                "C:\\Scripts\\claude.ps1",
            ],
            pid: 92,
            name: "powershell.exe"
        )
        #expect(slash == .running)

        // The value may be glued on with a colon. The format is still not
        // the program, and `-File:claude.ps1` is still the script.
        let colonFormat = await observe([
            "pwsh", "-InputFormat:Text", "-File", "claude.ps1",
        ])
        #expect(colonFormat == .running)
        let colonFile = await observe([
            "pwsh", "-NoProfile", "-File:C:\\Scripts\\claude.ps1",
        ])
        #expect(colonFile == .running)
        let colonCommand = await observe([
            "pwsh", "-c:& claude",
        ])
        #expect(colonCommand == .running)

        // `-CommandWithArgs` is a command. The words after that string are
        // arguments, so a later `claude` does not make an echo the agent.
        let commandWithArgs = await observe([
            "pwsh", "-cwa", "claude --resume", "extra",
        ])
        #expect(commandWithArgs == .running)
        let commandIsEcho = await observe([
            "pwsh", "-CommandWithArgs", "echo hi", "claude",
        ], pid: 93)
        #expect(commandIsEcho == .gone(lastLine: "pwsh (pid 93)"))

        // `-e` / `-ec` are encoded commands. The next word is the blob,
        // even when that word is an agent name.
        let encodedShort = await observe(["pwsh", "-e", "claude"], pid: 94)
        #expect(encodedShort == .gone(lastLine: "pwsh (pid 94)"))
        let encodedEC = await observe(["pwsh", "-ec", "claude"], pid: 95)
        #expect(encodedEC == .gone(lastLine: "pwsh (pid 95)"))

        // A format with no script is still a shell. A script that is not
        // an agent is still a shell. `/usr/bin/claude` is a path, not a
        // switch, including when another slash-flag sits beside it.
        let formatOnly = await observe(["pwsh", "-InputFormat", "Text"], pid: 96)
        #expect(formatOnly == .gone(lastLine: "pwsh (pid 96)"))
        let notAgent = await observe([
            "pwsh", "-ep", "Bypass", "-File", "C:\\Scripts\\readme.txt",
        ], pid: 97)
        #expect(notAgent == .gone(lastLine: "pwsh (pid 97)"))
        let pathProgram = await observe([
            "pwsh", "-NoProfile", "/usr/local/bin/claude",
        ])
        #expect(pathProgram == .running)
    }

    @Test("A crash replaces the status verdict and a running read clears only that crash")
    func stampSetsAndClears() {
        let working = Agent(id: AgentID("w1:p1"), status: .working, verdict: .healthy)
        let blocked = Agent(
            id: AgentID("w1:p2"),
            status: .blocked,
            verdict: .awaitingInput(BlockClassification(
                kind: .unknownBlock, since: now, summary: "blocked"
            ))
        )
        let crashed = ProcessGoneObservation.apply(
            [working.id: .gone(lastLine: "zsh (pid 1)")],
            to: [working, blocked],
            now: now
        )
        #expect(crashed[0].verdict == .processGone(lastLine: "zsh (pid 1)"))
        #expect(crashed[1].verdict.isAwaitingInput)
        #expect(AttentionTriage.kind(for: crashed[0]) == .gone)
        #expect(AttentionTriage.statusMark(for: crashed[0]) == "GONE")
        #expect(AttentionTriage.statusMark(for: crashed[1]) == "🔴")
        #expect(AttentionTriage.statusFooter(agentCount: 2, counts: AttentionTriage.counts(crashed))
            == "2 agents | 1 blocked | 1 gone | 0 silent | 0 done")

        // Running clears the crash back to the status verdict. The permission
        // prompt beside it is not a crash and stays.
        let cleared = ProcessGoneObservation.apply(
            [working.id: .running],
            to: crashed,
            now: now
        )
        #expect(cleared[0].verdict.isHealthy)
        #expect(cleared[1].verdict.isAwaitingInput)

        let blockedCrash = ProcessGoneObservation.apply(
            [blocked.id: .gone(lastLine: nil)],
            to: [blocked],
            now: now
        )
        let blockedAgain = ProcessGoneObservation.apply(
            [blocked.id: .running],
            to: blockedCrash,
            now: now
        )
        #expect(blockedAgain[0].verdict == HerdSnapshot.displayVerdict(for: .blocked, now: now))
    }

    @Test("An unreadable process list does not clear a crash or invent one")
    func unknownLeavesTheRow() {
        let crashed = Agent(
            id: AgentID("w1:p1"),
            status: .working,
            verdict: .processGone(lastLine: "zsh (pid 1)")
        )
        let healthy = Agent(id: AgentID("w1:p2"), status: .working, verdict: .healthy)
        let after = ProcessGoneObservation.apply(
            [crashed.id: .unknown, healthy.id: .unknown],
            to: [crashed, healthy],
            now: now
        )
        #expect(after[0].verdict == crashed.verdict)
        #expect(after[1].verdict.isHealthy)

        let untouched = ProcessGoneObservation.apply([:], to: [crashed], now: now)
        #expect(untouched[0].verdict == crashed.verdict)
    }
}

@Suite("Diagnoser does not stamp known states unclassifiable")
struct DiagnoserUnclassifiableScopeTests {
    private let nodeForeground = ProcessInfoResult(
        shellPid: 123,
        foregroundProcesses: [ForegroundProcess(pid: 456, name: "node", argv0: nil, cmdline: nil, cwd: nil)]
    )

    @Test("A working agent with recent output is healthy, not unclassifiable")
    func workingWithinThresholdIsHealthy() async {
        let agent = Agent(
            id: AgentID("w1:p1"),
            kind: .claude,
            status: .working,
            enteredAt: Date().addingTimeInterval(-60),
            lastOutputAt: Date().addingTimeInterval(-5)
        )
        let adapter = MockHerdrAdapter(
            explainResult: AgentExplainResult(
                agent: "claude",
                state: "working",
                matchedRuleId: nil,
                matchedRulePriority: nil,
                screenDetectionSkipped: false
            ),
            processInfoResult: nodeForeground
        )
        let verdict = await Diagnoser().diagnose(agent: agent, adapter: adapter)
        #expect(verdict.isHealthy)
        #expect(!verdict.isUnclassifiable)
        #expect(verdict.reasonText == nil)
    }

    @Test("A working hook-reported agent is healthy even with screen detection skipped")
    func workingHookReportedIsHealthy() async {
        let agent = Agent(
            id: AgentID("w1:p1"),
            kind: .opencode,
            status: .working,
            enteredAt: Date().addingTimeInterval(-30)
        )
        let adapter = MockHerdrAdapter(
            explainResult: AgentExplainResult(
                agent: "opencode",
                state: nil,
                matchedRuleId: nil,
                matchedRulePriority: nil,
                screenDetectionSkipped: true
            ),
            processInfoResult: nodeForeground
        )
        let verdict = await Diagnoser().diagnose(agent: agent, adapter: adapter)
        #expect(verdict.isHealthy)
    }

    @Test("A working agent whose explain and process info both fail is healthy")
    func workingWithFailedLookupsIsHealthy() async {
        let agent = Agent(
            id: AgentID("w1:p1"),
            kind: .claude,
            status: .working,
            enteredAt: Date().addingTimeInterval(-30)
        )
        let verdict = await Diagnoser().diagnose(agent: agent, adapter: MockHerdrAdapter())
        #expect(verdict.isHealthy)
    }

    @Test("Unknown status is still unclassifiable")
    func unknownStaysUnclassifiable() async {
        let agent = Agent(id: AgentID("w1:p1"), kind: .claude, status: .unknown)
        let verdict = await Diagnoser().diagnose(
            agent: agent,
            adapter: MockHerdrAdapter(processInfoResult: nodeForeground)
        )
        #expect(verdict.isUnclassifiable)
    }

    @Test("Blocked with screen detection skipped still degrades to unclassifiable")
    func blockedHookReportedIsUnclassifiable() async {
        let agent = Agent(id: AgentID("w1:p1"), kind: .opencode, status: .blocked)
        let adapter = MockHerdrAdapter(
            explainResult: AgentExplainResult(
                agent: "opencode",
                state: nil,
                matchedRuleId: nil,
                matchedRulePriority: nil,
                screenDetectionSkipped: true
            ),
            processInfoResult: nodeForeground
        )
        let verdict = await Diagnoser().diagnose(agent: agent, adapter: adapter)
        #expect(verdict.isUnclassifiable)
    }
}
