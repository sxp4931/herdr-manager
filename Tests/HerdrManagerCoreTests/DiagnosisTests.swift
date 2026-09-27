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

@Suite("Diagnoser.cpuSamplePid")
struct DiagnoserCpuSamplePidTests {
    private func process(
        _ pid: Int32,
        _ name: String,
        argv: [String]? = nil,
        argv0: String? = nil,
        cmdline: String? = nil
    ) -> ForegroundProcess {
        ForegroundProcess(
            pid: pid, name: name, argv0: argv0, cmdline: cmdline, cwd: nil, argv: argv
        )
    }

    @Test("A shell listed last is not the process whose CPU is read")
    func shellLastIsNotTheSample() {
        let node = process(20, "node", argv: ["node", "codex"])
        let shell = process(10, "zsh", argv: ["-zsh"])
        #expect(Diagnoser.cpuSamplePid([node, shell]) == 20)
        #expect(Diagnoser.cpuSamplePid([shell, node]) == 20)
    }

    @Test("A known agent outranks a node process that is not that agent")
    func agentOutranksHelperRuntime() {
        let helper = process(30, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        #expect(Diagnoser.cpuSamplePid([helper, claude]) == 12)
        let eval = process(30, "node", argv: ["node", "-e", "codex"])
        #expect(Diagnoser.cpuSamplePid([eval, claude]) == 12)
    }

    @Test("Node running the agent outranks the shell that launched it and a later git")
    func runtimeScriptOutranksShellAndHelper() {
        let shell = process(2, "sh", argv: ["sh", "codex"])
        let git = process(9, "git", argv: ["git", "status"])
        let node = process(4, "node", argv: ["node", "-r", "preload.js", "codex"])
        #expect(Diagnoser.cpuSamplePid([shell, git, node]) == 4)
        let attached = process(4, "node.exe", argv: ["node.exe", "--require=preload.js", "codex"])
        #expect(Diagnoser.cpuSamplePid([shell, git, attached]) == 4)
    }

    @Test("bun run, bun x, and deno run name the agent, and a program named run does not")
    func runtimeSubcommandIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let bunRun = process(20, "bun", argv: ["bun", "run", "codex"])
        #expect(Diagnoser.cpuSamplePid([helper, bunRun]) == 20)
        #expect(Diagnoser.cpuSamplePid([bunRun, helper]) == 20)

        let bunX = process(21, "bun", argv: ["bun", "x", "codex", "--model", "gpt-5"])
        #expect(Diagnoser.cpuSamplePid([helper, bunX]) == 21)
        let bunExe = process(
            22,
            "bun.exe",
            argv: ["bun.exe", "--bun", "run", "--watch", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, bunExe]) == 22)
        let attachedCwd = process(
            23,
            "bun",
            argv: ["bun", "run", "--cwd=/home/user/src/codex", "codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, attachedCwd]) == 23)

        let deno = process(24, "deno", argv: ["deno", "run", "--allow-all", "/tmp/codex"])
        #expect(Diagnoser.cpuSamplePid([helper, deno]) == 24)
        let denoExe = process(25, "deno.exe", argv: ["deno.exe", "run", "-A", "claude.js"])
        #expect(Diagnoser.cpuSamplePid([helper, denoExe]) == 25)

        let omp = process(
            26,
            "bun",
            argv: [
                "bun", "run",
                "/home/user/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([helper, omp]) == 26)

        // The directory, the env file, and the filter are not the program.
        let withCwd = process(
            4,
            "bun",
            argv: ["bun", "run", "--cwd", "/home/user/codex", "dev"]
        )
        let withEnv = process(
            4,
            "bun",
            argv: ["bun", "run", "--env-file", "/home/user/codex", "dev"]
        )
        let withFilter = process(
            4,
            "bun",
            argv: ["bun", "run", "--filter", "codex", "dev"]
        )
        let withFilterShort = process(4, "bun", argv: ["bun", "run", "-F", "codex", "dev"])
        let withPreload = process(
            4,
            "bun",
            argv: ["bun", "run", "--preload", "/home/user/codex", "dev"]
        )
        #expect(Diagnoser.cpuSamplePid([withCwd, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([withEnv, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([withFilter, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([withFilterShort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([withPreload, claude]) == 12)

        // A program named run stays the script. The later agent path is its argument.
        let namedRun = process(4, "bun", argv: ["bun", "./run", "/tmp/codex"])
        let nodeRun = process(4, "node", argv: ["node", "run", "/tmp/codex"])
        let pythonRun = process(4, "python3.12", argv: ["python3.12", "run", "/tmp/codex"])
        let afterDash = process(4, "bun", argv: ["bun", "--", "run", "/tmp/codex"])
        let scriptNamedX = process(4, "bun", argv: ["bun", "run", "x", "/tmp/codex"])
        #expect(Diagnoser.cpuSamplePid([namedRun, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([nodeRun, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([pythonRun, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([afterDash, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([scriptNamedX, claude]) == 12)

        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let leader = process(20, "bun", argv: ["bun", "run", "/usr/local/bin/codex"])
        #expect(Diagnoser.cpuSamplePid([mcp, leader]) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, leader], foregroundProcessGroupId: 20) == 20)

        let letta = process(
            30,
            "bun",
            argv: ["bun", "run", "/home/user/node_modules/.bin/letta", "--conversation", "id"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, letta]) == 30)
        let viaX = process(31, "bun", argv: ["bun", "x", "letta", "--backend", "local"])
        #expect(Diagnoser.cpuSamplePid([helper, viaX]) == 31)
        let lettaPrompt = process(8, "bun", argv: ["bun", "run", "letta", "--prompt", "hello"])
        let interactive = process(30, "letta", argv: ["letta"])
        #expect(Diagnoser.cpuSamplePid([lettaPrompt, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([lettaPrompt]) == 8)
        #expect(Diagnoser.cpuSamplePid([lettaPrompt, interactive], foregroundProcessGroupId: 8) == 30)

        let denoLetta = process(4, "deno", argv: ["deno", "run", "--allow-all", "/tmp/letta"])
        #expect(Diagnoser.cpuSamplePid([denoLetta, interactive]) == 30)

        let eval = process(9, "bun", argv: ["bun", "run", "-e", "code", "/tmp/codex"])
        #expect(Diagnoser.cpuSamplePid([eval, claude]) == 12)
    }

    @Test("a bun flag value is not the agent script")
    func bunFlagValueIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])

        let defined = process(
            20,
            "bun",
            argv: ["bun", "--define", "process.env.NODE_ENV:\"development\"", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, defined]) == 20)
        let shortDefine = process(
            20,
            "bun",
            argv: ["bun", "-d", "process.env.NODE_ENV:\"development\"", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, shortDefine]) == 20)
        let attachedDefine = process(20, "bun", argv: ["bun", "--define=KEY:1", "/tmp/codex"])
        let gluedDefine = process(20, "bun", argv: ["bun", "-dKEY:1", "/tmp/codex"])
        #expect(Diagnoser.cpuSamplePid([helper, attachedDefine]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, gluedDefine]) == 20)

        // The value's basename is an agent. The script after it is not.
        let title = process(4, "bun", argv: ["bun", "--title", "codex", "server.js"])
        let userAgent = process(4, "bun", argv: ["bun", "--user-agent", "codex", "server.js"])
        let dropped = process(4, "bun", argv: ["bun", "--drop", "codex", "server.js"])
        let shellFlag = process(4, "bun", argv: ["bun", "--shell", "codex", "server.js"])
        let conditions = process(4, "bun", argv: ["bun", "--conditions", "codex", "server.js"])
        let jsx = process(4, "bun", argv: ["bun", "--jsx-import-source", "codex", "server.js"])
        let port = process(4, "bun", argv: ["bun", "--port", "codex", "server.js"])
        let install = process(4, "bun", argv: ["bun", "--install", "codex", "server.js"])
        #expect(Diagnoser.cpuSamplePid([title, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([userAgent, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([dropped, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([shellFlag, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([conditions, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([jsx, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([port, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([install, claude]) == 12)

        // `KEY` has no `:` or `=`. Bun 1.4.2 exits, so `--watch` and the
        // path do not run. `KEY:1` is a define, and the path is the script.
        let bareDefine = process(
            20,
            "bun",
            argv: ["bun", "run", "--define", "KEY", "--watch", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, bareDefine]) == 10)
        #expect(Diagnoser.cpuSamplePid([bareDefine]) == 20)
        let afterRun = process(
            20,
            "bun",
            argv: ["bun", "run", "--define", "KEY:1", "--watch", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, afterRun]) == 20)

        // The path is the script. A separate port is the missing script,
        // so the agent path after it is not this process.
        let inspectPath = process(20, "bun", argv: ["bun", "--inspect", "./codex"])
        let inspectWaitPath = process(20, "bun", argv: ["bun", "--inspect-wait", "./codex"])
        let inspectBrkPath = process(4, "bun", argv: ["bun", "--inspect-brk", "/tmp/server.js"])
        #expect(Diagnoser.cpuSamplePid([helper, inspectPath]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, inspectWaitPath]) == 20)
        #expect(Diagnoser.cpuSamplePid([inspectBrkPath, claude]) == 12)
        let address = process(
            20,
            "bun",
            argv: ["bun", "--inspect-wait", "127.0.0.1:9229", "/tmp/codex"]
        )
        let portOnly = process(20, "bun", argv: ["bun", "--inspect-brk", "9229", "/tmp/codex"])
        let prefix = process(
            20,
            "bun",
            argv: ["bun", "--inspect", "localhost:6499/prefix", "/tmp/codex"]
        )
        let v6 = process(20, "bun", argv: ["bun", "--inspect-wait", "[::1]:9229", "/tmp/codex"])
        let attachedInspect = process(
            20,
            "bun",
            argv: ["bun", "--inspect=0.0.0.0:9229", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, address]) == 10)
        #expect(Diagnoser.cpuSamplePid([helper, portOnly]) == 10)
        #expect(Diagnoser.cpuSamplePid([helper, prefix]) == 10)
        #expect(Diagnoser.cpuSamplePid([helper, v6]) == 10)
        #expect(Diagnoser.cpuSamplePid([helper, attachedInspect]) == 20)

        let windows = process(20, "bun.exe", argv: ["bun.exe", "--inspect", "C:\\Users\\codex.js"])
        #expect(Diagnoser.cpuSamplePid([windows, claude]) == 20)

        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let leader = process(
            20,
            "bun",
            argv: ["bun", "--inspect-wait", "localhost:9229", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([mcp, leader]) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, leader], foregroundProcessGroupId: 20) == 10)

        // `KEY` is not a define, so the path is not the TUI. `KEY:1` is.
        let bareLetta = process(
            30,
            "bun",
            argv: [
                "bun", "--define", "KEY",
                "/home/user/node_modules/.bin/letta", "--conversation", "id",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([helper, bareLetta]) == 10)
        #expect(Diagnoser.cpuSamplePid([bareLetta]) == 30)
        let letta = process(
            30,
            "bun",
            argv: [
                "bun", "--define", "KEY:1",
                "/home/user/node_modules/.bin/letta", "--conversation", "id",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([helper, letta]) == 30)
        let oneShot = process(
            8,
            "bun",
            argv: ["bun", "--inspect-wait", "127.0.0.1:9229", "letta", "--prompt", "hello"]
        )
        let interactive = process(30, "letta", argv: ["letta"])
        #expect(Diagnoser.cpuSamplePid([oneShot, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([oneShot]) == 8)
        #expect(
            Diagnoser.cpuSamplePid([oneShot, interactive], foregroundProcessGroupId: 8) == 30
        )

        // `-p` and `-e` are eval. Bun 1.4.2's `-c` does not take a separate
        // word: `/tmp/codex` is the script, and `server.js` is its argument.
        let printFlag = process(4, "bun", argv: ["bun", "-p", "3000", "/tmp/codex"])
        let configShort = process(4, "bun", argv: ["bun", "-c", "/tmp/codex", "server.js"])
        let configGlued = process(20, "bun", argv: ["bun", "-c=/tmp/bunfig.toml", "/tmp/codex"])
        let externalShort = process(4, "bun", argv: ["bun", "-e", "codex", "/tmp/codex"])
        #expect(Diagnoser.cpuSamplePid([printFlag, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([configShort, claude]) == 4)
        #expect(Diagnoser.cpuSamplePid([helper, configGlued]) == 20)
        #expect(Diagnoser.cpuSamplePid([externalShort, claude]) == 12)

        // Node 22.23 rejects bun's `--define` and does not run the file.
        // Python's `-d` is still the script.
        let nodeDefine = process(4, "node", argv: ["node", "--define", "codex", "server.js"])
        let pythonDebug = process(4, "python3", argv: ["python3", "-d", "/tmp/codex"])
        #expect(Diagnoser.cpuSamplePid([nodeDefine, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([pythonDebug, claude]) == 4)

        // Bun 1.4.2 still consumes these. The value named codex is not the script.
        let feature = process(4, "bun", argv: ["bun", "--feature", "codex", "server.js"])
        let origin = process(4, "bun", argv: ["bun", "--origin", "https://example.com/codex", "server.js"])
        let warnings = process(4, "bun", argv: ["bun", "--redirect-warnings", "codex", "server.js"])
        let cron = process(
            4,
            "bun",
            argv: ["bun", "--cron-title", "codex", "--cron-period", "* * * * *", "server.js"]
        )
        let profDir = process(
            4,
            "bun",
            argv: ["bun", "--cpu-prof", "--cpu-prof-dir", "/tmp/codex", "server.js"]
        )
        #expect(Diagnoser.cpuSamplePid([feature, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([origin, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([warnings, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([cron, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([profDir, claude]) == 12)

        let featureScript = process(20, "bun", argv: ["bun", "--feature", "FLAG", "/tmp/codex"])
        let originScript = process(
            20,
            "bun",
            argv: ["bun", "--origin", "https://example.com", "/tmp/codex"]
        )
        let attachedFeature = process(20, "bun", argv: ["bun", "--feature=FLAG", "/tmp/codex"])
        let targetAttached = process(20, "bun", argv: ["bun", "--target=browser", "/tmp/codex"])
        #expect(Diagnoser.cpuSamplePid([helper, featureScript]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, originScript]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, attachedFeature]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, targetAttached]) == 20)

        // A separate word after these is the script on Bun 1.4.2.
        let external = process(4, "bun", argv: ["bun", "--external", "react", "/tmp/codex"])
        let packages = process(4, "bun", argv: ["bun", "--packages", "external", "/tmp/codex"])
        let target = process(4, "bun", argv: ["bun", "--target", "browser", "/tmp/codex"])
        #expect(Diagnoser.cpuSamplePid([external, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([packages, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([target, claude]) == 12)

        let featureLetta = process(
            30,
            "bun",
            argv: [
                "bun", "--feature", "KEY",
                "/home/user/node_modules/.bin/letta", "--conversation", "id",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([helper, featureLetta]) == 30)
    }

    @Test("a dash word bun rejects is not the agent script")
    func bunDashValueIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Bun 1.4.2 exits. The path after the dash word does not run, so
        // this bun is not the group leader.
        let port = process(
            4, "bun", argv: ["bun", "--port", "--watch", "/usr/local/bin/codex"]
        )
        let define = process(
            4, "bun", argv: ["bun", "--define", "--watch", "/tmp/codex"]
        )
        let shortDefine = process(
            4, "bun.exe", argv: ["bun.exe", "-d", "--watch", "/tmp/codex"]
        )
        let shell = process(
            4, "bun", argv: ["bun", "run", "--shell", "--watch", "/usr/local/bin/codex"]
        )
        let install = process(
            4, "bun", argv: ["bun", "--install", "--watch", "/tmp/codex"]
        )
        let depth = process(
            4, "bun", argv: ["bun", "--console-depth", "-1", "/tmp/codex"]
        )
        let elide = process(
            4, "bun", argv: ["bun", "--elide-lines", "--watch", "/tmp/codex"]
        )
        let jsx = process(
            4, "bun", argv: ["bun", "--jsx-runtime", "--watch", "/usr/local/bin/codex"]
        )
        let preconnect = process(
            4, "bun", argv: ["bun", "--fetch-preconnect", "--watch", "/tmp/codex"]
        )
        let header = process(
            4, "bun", argv: ["bun", "--max-http-header-size", "--watch", "/tmp/codex"]
        )
        let dns = process(
            4, "bun", argv: ["bun", "--dns-result-order", "--watch", "/tmp/codex"]
        )
        let rejections = process(
            4, "bun", argv: ["bun", "--unhandled-rejections", "--watch", "/tmp/codex"]
        )
        let bareKey = process(
            4, "bun", argv: ["bun", "--define", "KEY", "/usr/local/bin/codex"]
        )
        let gluedDebug = process(4, "bun", argv: ["bun", "-debug", "/tmp/codex"])
        let attachedPort = process(
            4, "bun", argv: ["bun", "--port=--watch", "/usr/local/bin/codex"]
        )
        let emptyPort = process(4, "bun", argv: ["bun", "--port=", "/tmp/codex"])
        let attachedDefine = process(
            4, "bun", argv: ["bun", "--define=--watch", "/tmp/codex"]
        )
        let shortAttached = process(4, "bun", argv: ["bun", "-d=A", "/tmp/codex"])
        let gluedDash = process(4, "bun.exe", argv: ["bun.exe", "-d--watch", "/tmp/codex"])
        #expect(Diagnoser.cpuSamplePid([port, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([define, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([shortDefine, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([shell, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([install, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([depth, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([elide, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([jsx, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([preconnect, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([header, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([dns, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([rejections, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([bareKey, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([gluedDebug, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([attachedPort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([emptyPort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([attachedDefine, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([shortAttached, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([gluedDash, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([mcp, port], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([port]) == 4)

        // A real value, including one glued with `=`, still names the script.
        // A dash word on `--title` and `--user-agent` is that value.
        let portScript = process(
            20, "bun", argv: ["bun", "--port", "3000", "/usr/local/bin/codex"]
        )
        let portEquals = process(20, "bun", argv: ["bun", "--port=3000", "/tmp/codex"])
        let defined = process(
            20, "bun", argv: ["bun", "--define", "KEY:1", "/usr/local/bin/codex"]
        )
        let definedEquals = process(
            20, "bun", argv: ["bun", "--define=KEY:1", "/tmp/codex"]
        )
        let definedDash = process(
            20, "bun", argv: ["bun", "--define", "--watch=1", "/tmp/codex"]
        )
        let shortEquals = process(20, "bun", argv: ["bun", "-d=KEY:1", "/tmp/codex"])
        let gluedWatch = process(20, "bun.exe", argv: ["bun.exe", "-d--watch=1", "/tmp/codex"])
        let emptyEquals = process(20, "bun", argv: ["bun", "--define==", "/tmp/codex"])
        let shellSystem = process(
            20, "bun", argv: ["bun", "--shell", "system", "/usr/local/bin/codex"]
        )
        let shellEquals = process(
            20, "bun", argv: ["bun", "--shell=system", "/tmp/codex"]
        )
        let emptyInstall = process(20, "bun", argv: ["bun", "--install=", "/tmp/codex"])
        let emptyElide = process(20, "bun", argv: ["bun", "--elide-lines=", "/tmp/codex"])
        let title = process(
            20, "bun", argv: ["bun", "--title", "--watch", "/usr/local/bin/codex"]
        )
        let userAgent = process(
            20, "bun", argv: ["bun", "--user-agent", "--watch", "/tmp/codex"]
        )
        let scriptFirst = process(
            20, "bun", argv: ["bun", "/usr/local/bin/codex", "--port", "--watch"]
        )
        let profName = process(
            20,
            "bun",
            argv: ["bun", "--cpu-prof", "--cpu-prof-name", "--watch", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, portScript]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, portEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, defined]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, definedEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, definedDash]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, shortEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, gluedWatch]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, emptyEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, shellSystem]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, shellEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, emptyInstall]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, emptyElide]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, title]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, userAgent]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, scriptFirst]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, profName]) == 20)
        #expect(
            Diagnoser.cpuSamplePid([mcp, title], foregroundProcessGroupId: 20) == 20
        )

        // Node 22.23 rejects `--port`. The path after it does not run.
        let nodePort = process(
            20, "node", argv: ["node", "--port", "--watch", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, nodePort]) == 10)

        // A rejected value in front of Letta is not the TUI. `--title
        // --watch` still is, and so is a define that has a separator.
        let falseLetta = process(
            8,
            "bun",
            argv: ["bun", "--port", "--watch", "/home/user/node_modules/.bin/letta"]
        )
        let defineLetta = process(
            8,
            "bun",
            argv: [
                "bun", "--define", "KEY",
                "/home/user/node_modules/.bin/letta", "--prompt", "hi",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([falseLetta, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([falseLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([falseLetta]) == 8)
        #expect(Diagnoser.cpuSamplePid([mcp, falseLetta], foregroundProcessGroupId: 8) == 10)
        #expect(Diagnoser.cpuSamplePid([defineLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([defineLetta]) == 8)
        let titleLetta = process(
            30,
            "bun",
            argv: [
                "bun", "--title", "--watch",
                "/home/user/node_modules/.bin/letta", "--conversation", "id",
            ]
        )
        let definedLetta = process(
            30,
            "bun",
            argv: [
                "bun", "--define", "KEY:1",
                "/home/user/node_modules/.bin/letta", "--conversation", "id",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([helper, titleLetta]) == 30)
        #expect(Diagnoser.cpuSamplePid([helper, definedLetta]) == 30)
    }

    @Test("a bun value the runtime rejects is not the agent script")
    func bunRejectedValueIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Bun 1.4.2 exits. The path after the rejected value does not run,
        // so this bun is not the group leader.
        let portWord = process(
            4, "bun", argv: ["bun", "--port", "codex", "/usr/local/bin/codex"]
        )
        let portRange = process(
            4, "bun", argv: ["bun", "--port", "65536", "/usr/local/bin/codex"]
        )
        let portEquals = process(
            4, "bun", argv: ["bun", "--port=bun", "/tmp/codex"]
        )
        let install = process(
            4, "bun", argv: ["bun", "run", "--install", "nope", "/tmp/codex"]
        )
        let shell = process(
            4, "bun", argv: ["bun", "--shell", "bash", "/usr/local/bin/codex"]
        )
        let shellBun = process(
            4, "bun.exe", argv: ["bun.exe", "--shell", "bun", "/tmp/codex"]
        )
        let depth = process(
            4, "bun", argv: ["bun", "--console-depth", "65536", "/tmp/codex"]
        )
        let elide = process(
            4, "bun", argv: ["bun", "--elide-lines", "abc", "/usr/local/bin/codex"]
        )
        let jsx = process(
            4, "bun", argv: ["bun", "--jsx-runtime", "nope", "/tmp/codex"]
        )
        let dns = process(
            4, "bun", argv: ["bun", "--dns-result-order", "nope", "/tmp/codex"]
        )
        let rejections = process(
            4, "bun", argv: ["bun", "--unhandled-rejections", "nope", "/tmp/codex"]
        )
        let preconnect = process(
            4, "bun", argv: ["bun", "--fetch-preconnect", "https://example.com", "/tmp/codex"]
        )
        let header = process(
            4, "bun", argv: ["bun", "--max-http-header-size", "abc", "/tmp/codex"]
        )
        let titleBun = process(
            4, "bun", argv: ["bun", "--title", "bun", "/usr/local/bin/codex"]
        )
        let profName = process(
            4, "bun", argv: ["bun", "--cpu-prof-name", "out.cpuprofile", "/tmp/codex"]
        )
        let heapInterval = process(
            4, "bun", argv: ["bun", "--heap-prof-interval", "1000", "/tmp/codex"]
        )
        let interval = process(
            4, "bun", argv: ["bun", "--cpu-prof-interval", "1", "/usr/local/bin/codex"]
        )
        let cron = process(
            4, "bun", argv: ["bun", "--cron-title", "hello", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([portWord, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([portRange, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([portEquals, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([install, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([shell, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([shellBun, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([depth, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([elide, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([jsx, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([dns, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([rejections, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([preconnect, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([header, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([titleBun, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([profName, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([heapInterval, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([interval, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([cron, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([mcp, portWord], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([portWord]) == 4)

        // A value bun accepts still names the script, including `=`,
        // `bun run`, and a script written before the flag.
        let portScript = process(
            20, "bun", argv: ["bun", "--port", "0", "/usr/local/bin/codex"]
        )
        let portPlus = process(20, "bun", argv: ["bun", "--port", "+80", "/tmp/codex"])
        let portPadded = process(20, "bun.exe", argv: ["bun.exe", "--port=03000", "/tmp/codex"])
        let installed = process(
            20, "bun", argv: ["bun", "--install", "disable", "/usr/local/bin/codex"]
        )
        let shellEquals = process(20, "bun", argv: ["bun", "--shell=bun", "/tmp/codex"])
        let depthZero = process(20, "bun", argv: ["bun", "--console-depth", "0", "/tmp/codex"])
        let depthTop = process(
            20, "bun", argv: ["bun", "--console-depth", "+65535", "/usr/local/bin/codex"]
        )
        let elideNumber = process(20, "bun", argv: ["bun", "--elide-lines", "+2", "/tmp/codex"])
        let jsxClassic = process(
            20, "bun", argv: ["bun", "--jsx-runtime=classic", "/tmp/codex"]
        )
        let dnsOrder = process(
            20, "bun", argv: ["bun", "--dns-result-order", "ipv6first", "/tmp/codex"]
        )
        let rejectionMode = process(
            20,
            "bun",
            argv: ["bun", "--unhandled-rejections", "warn-with-error-code", "/tmp/codex"]
        )
        let preconnected = process(
            20,
            "bun",
            argv: ["bun", "--fetch-preconnect", "https://example.com:443/path", "/tmp/codex"]
        )
        let preconnectV6 = process(
            20, "bun", argv: ["bun", "--fetch-preconnect", "https://[::1]:443", "/tmp/codex"]
        )
        let headerZero = process(
            20, "bun", argv: ["bun", "--max-http-header-size", "0", "/tmp/codex"]
        )
        let titleEquals = process(20, "bun", argv: ["bun", "--title=bun", "/usr/local/bin/codex"])
        let defaultInterval = process(
            20, "bun", argv: ["bun", "--cpu-prof-interval", "01000", "/tmp/codex"]
        )
        let namedProfile = process(
            20,
            "bun",
            argv: ["bun", "--cpu-prof-name", "out.cpuprofile", "--cpu-prof", "/tmp/codex"]
        )
        let markdownProfile = process(
            20,
            "bun",
            argv: ["bun", "--cpu-prof-md", "--cpu-prof-interval", "abc", "/tmp/codex"]
        )
        let heapMarkdown = process(
            20,
            "bun",
            argv: ["bun", "--heap-prof-md", "--heap-prof-name", "out", "/usr/local/bin/codex"]
        )
        let heapAny = process(
            20,
            "bun",
            argv: ["bun", "--heap-prof", "--heap-prof-interval", "abc", "/tmp/codex"]
        )
        let cronBoth = process(
            20,
            "bun",
            argv: [
                "bun", "run", "--cron-title=hello", "--cron-period", "1s",
                "/usr/local/bin/codex",
            ]
        )
        let scriptFirst = process(
            20, "bun", argv: ["bun", "/usr/local/bin/codex", "--port", "codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, portScript]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, portPlus]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, portPadded]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, installed]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, shellEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, depthZero]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, depthTop]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, elideNumber]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, jsxClassic]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, dnsOrder]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, rejectionMode]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, preconnected]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, preconnectV6]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, headerZero]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, titleEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, defaultInterval]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, namedProfile]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, markdownProfile]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, heapMarkdown]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, heapAny]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, cronBoth]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, scriptFirst]) == 20)
        #expect(
            Diagnoser.cpuSamplePid([mcp, shellEquals], foregroundProcessGroupId: 20) == 20
        )

        // Node 22.23 rejects `--port`, so `codex` in that slot is not
        // the script. `--title bun` is a title, and the path after it
        // is the script.
        let nodePort = process(
            20, "node", argv: ["node", "--port", "codex", "server.js"]
        )
        let nodeTitle = process(
            20, "node", argv: ["node", "--title", "bun", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, nodePort]) == 10)
        #expect(Diagnoser.cpuSamplePid([helper, nodeTitle]) == 20)

        // A rejected value in front of Letta is not the TUI. An attached
        // `--shell=bun` still is.
        let falseLetta = process(
            8,
            "bun",
            argv: ["bun", "--port", "65536", "/home/user/node_modules/.bin/letta"]
        )
        let titleLetta = process(
            8,
            "bun",
            argv: [
                "bun", "--title", "bun",
                "/home/user/node_modules/.bin/letta", "--prompt", "hi",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([falseLetta, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([falseLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([falseLetta]) == 8)
        #expect(Diagnoser.cpuSamplePid([mcp, falseLetta], foregroundProcessGroupId: 8) == 10)
        #expect(Diagnoser.cpuSamplePid([titleLetta, interactive]) == 30)
        let shellLetta = process(
            30,
            "bun",
            argv: [
                "bun", "--shell=bun",
                "/home/user/node_modules/.bin/letta", "--conversation", "id",
            ]
        )
        let portLetta = process(
            30,
            "bun",
            argv: [
                "bun", "--port", "3000",
                "/home/user/node_modules/.bin/letta", "--conversation", "id",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([helper, shellLetta]) == 30)
        #expect(Diagnoser.cpuSamplePid([helper, portLetta]) == 30)
    }

    @Test("bun's --config word is the script, and the other runtimes keep theirs")
    func bunConfigWordIsTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])

        // Bun 1.4.2 does not take a separate word. The path is the script.
        let runsCodex = process(
            4, "bun", argv: ["bun", "run", "--config", "/home/user/codex", "dev"]
        )
        let bare = process(20, "bun", argv: ["bun", "--config", "/usr/local/bin/codex"])
        let equals = process(
            20, "bun", argv: ["bun", "--config=/tmp/bunfig.toml", "/tmp/codex"]
        )
        let bunExe = process(
            20, "bun.exe", argv: ["bun.exe", "run", "--config", "/tmp/codex"]
        )
        let watched = process(
            20, "bun", argv: ["bun", "--config", "--watch", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([runsCodex, claude]) == 4)
        #expect(Diagnoser.cpuSamplePid([helper, bare]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, equals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bunExe]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, watched]) == 20)

        // The first word is the program. The agent path is its argument.
        let toml = process(
            4,
            "bun",
            argv: ["bun", "run", "--config", "bunfig.toml", "/usr/local/bin/codex"]
        )
        let server = process(
            4,
            "bun",
            argv: ["bun", "run", "--config", "server.js", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([toml, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([server, claude]) == 12)

        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let leader = process(
            20, "bun", argv: ["bun", "run", "--config", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([mcp, leader]) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, leader], foregroundProcessGroupId: 20) == 20)
        let falseLeader = process(
            20,
            "bun",
            argv: ["bun", "run", "--config", "server.js", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([mcp, falseLeader]) == 10)
        #expect(
            Diagnoser.cpuSamplePid([mcp, falseLeader], foregroundProcessGroupId: 20) == 10
        )

        let letta = process(
            30,
            "bun",
            argv: ["bun", "--config", "/home/user/node_modules/.bin/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, letta]) == 30)
        let oneShot = process(
            8,
            "bun",
            argv: [
                "bun", "--config",
                "/home/user/node_modules/.bin/letta", "--prompt", "hello",
            ]
        )
        let interactive = process(30, "letta", argv: ["letta"])
        #expect(Diagnoser.cpuSamplePid([oneShot, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([oneShot]) == 8)
        #expect(
            Diagnoser.cpuSamplePid([oneShot, interactive], foregroundProcessGroupId: 8) == 30
        )

        // Deno still consumes the next word. The = form keeps the file in the flag.
        let denoValue = process(
            4, "deno", argv: ["deno", "run", "--config", "codex", "server.js"]
        )
        let denoScript = process(
            20, "deno", argv: ["deno", "run", "--config", "deno.json", "/tmp/codex"]
        )
        let denoEquals = process(
            20, "deno", argv: ["deno", "--config=/tmp/deno.json", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([denoValue, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, denoScript]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, denoEquals]) == 20)

        // Node and Python reject the flag and exit. A path after it is not
        // the script. A script before the flag still is.
        let nodeBare = process(
            4, "node", argv: ["node", "--config", "/usr/local/bin/codex"]
        )
        let nodeAfter = process(
            4, "node", argv: ["node", "--config", "file.js", "/usr/local/bin/codex"]
        )
        let nodeEquals = process(
            4, "nodejs", argv: ["nodejs", "--config=/tmp/file", "/usr/local/bin/codex"]
        )
        let nodeScriptFirst = process(
            20, "node", argv: ["node", "/usr/local/bin/codex", "--config"]
        )
        let pythonBare = process(
            4, "python3", argv: ["python3", "--config", "/tmp/codex"]
        )
        let pythonEquals = process(
            4, "python3.11", argv: ["python3.11", "--config=/tmp/file", "/tmp/codex"]
        )
        let pythonScriptFirst = process(
            20, "python3", argv: ["python3", "/tmp/codex", "--config"]
        )
        #expect(Diagnoser.cpuSamplePid([nodeBare, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([nodeAfter, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([nodeEquals, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, nodeScriptFirst]) == 20)
        #expect(Diagnoser.cpuSamplePid([pythonBare, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([pythonEquals, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, pythonScriptFirst]) == 20)
    }

    @Test("python -S is the script, and hash-based pycs takes a mode")
    func pythonSiteFlagIsNotAValue() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])

        // Python 3.13 runs the next word. `-S` is not a value.
        let site = process(20, "python3", argv: ["python3", "-S", "/usr/local/bin/codex"])
        let versioned = process(
            20, "python3.11", argv: ["python3.11", "-S", "/tmp/codex"]
        )
        let exe = process(20, "Python.exe", argv: ["Python.exe", "-S", "/tmp/codex"])
        let twice = process(20, "python3", argv: ["python3", "-SS", "/tmp/codex"])
        let verbose = process(
            20, "python3", argv: ["python3", "-v", "-S", "/tmp/codex"]
        )
        let warning = process(
            20, "python3", argv: ["python3", "-S", "-W", "ignore", "/tmp/codex"]
        )
        let option = process(
            20, "python3", argv: ["python3", "-X", "dev", "/tmp/codex"]
        )
        let gluedOption = process(
            20, "python3", argv: ["python3", "-Xdev", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, site]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, versioned]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, exe]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, twice]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, verbose]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, warning]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, option]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, gluedOption]) == 20)
        #expect(Diagnoser.cpuSamplePid([mcp, site]) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, site], foregroundProcessGroupId: 20) == 20)

        // The flag word is not an agent, and neither is a script that is not one.
        let notAgent = process(4, "python3", argv: ["python3", "-S", "server.js"])
        let namedOption = process(
            4, "python3", argv: ["python3", "-X", "codex", "server.js"]
        )
        #expect(Diagnoser.cpuSamplePid([notAgent, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([namedOption, claude]) == 12)

        // The mode is not the script. The file after a real mode is.
        let mode = process(
            4,
            "python3",
            argv: ["python3", "--check-hash-based-pycs", "always", "server.js"]
        )
        let never = process(
            20,
            "python3",
            argv: ["python3", "--check-hash-based-pycs", "never", "/tmp/codex"]
        )
        let thenSite = process(
            20,
            "python3",
            argv: [
                "python3", "--check-hash-based-pycs", "default", "-S",
                "/usr/local/bin/codex",
            ]
        )
        let scriptFirst = process(
            20,
            "python3",
            argv: ["python3", "/tmp/codex", "--check-hash-based-pycs", "always"]
        )
        #expect(Diagnoser.cpuSamplePid([mode, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, never]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, thenSite]) == 20)
        #expect(Diagnoser.cpuSamplePid([mcp, never]) == 10)
        #expect(
            Diagnoser.cpuSamplePid([mcp, never], foregroundProcessGroupId: 20) == 20
        )
        #expect(Diagnoser.cpuSamplePid([helper, scriptFirst]) == 20)

        // A mode Python does not accept, or the `=` form, exits. The path
        // is not the script. Node and bun reject `-S` and exit the same way.
        let badMode = process(
            4,
            "python3",
            argv: ["python3", "--check-hash-based-pycs", "codex", "/tmp/codex"]
        )
        let upperMode = process(
            4,
            "python3",
            argv: ["python3", "--check-hash-based-pycs", "ALWAYS", "/tmp/codex"]
        )
        let equalsMode = process(
            4,
            "python3.11",
            argv: ["python3.11", "--check-hash-based-pycs=always", "/tmp/codex"]
        )
        let missingMode = process(
            4, "python3", argv: ["python3", "--check-hash-based-pycs"]
        )
        let nodeSite = process(4, "node", argv: ["node", "-S", "/usr/local/bin/codex"])
        let nodejsSite = process(4, "nodejs", argv: ["nodejs", "-S", "/tmp/codex"])
        let bunSite = process(4, "bun", argv: ["bun", "-S", "/usr/local/bin/codex"])
        #expect(Diagnoser.cpuSamplePid([badMode, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([upperMode, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([equalsMode, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([missingMode, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([nodeSite, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([nodejsSite, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([bunSite, claude]) == 12)

        // Deno's `-S` is still the permission flag. The path is the script.
        let denoSite = process(
            20, "deno", argv: ["deno", "run", "-S", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, denoSite]) == 20)

        // A file named letta under python stays a plain runtime.
        let pythonLetta = process(
            40, "python3", argv: ["python3", "-S", "/tmp/letta"]
        )
        let interactive = process(30, "letta", argv: ["letta"])
        #expect(Diagnoser.cpuSamplePid([helper, pythonLetta]) == 10)
        #expect(Diagnoser.cpuSamplePid([pythonLetta, interactive]) == 30)
    }

    @Test("bun's --experimental-loader and --inspect-port words are the script")
    func bunLoaderAndInspectPortNameTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])

        // Bun 1.4.2 runs the next word. The shared set used to swallow it.
        let loader = process(
            20,
            "bun",
            argv: ["bun", "--experimental-loader", "/tmp/codex.js", "/tmp/other.js"]
        )
        let loaderRun = process(
            20,
            "bun",
            argv: ["bun", "run", "--experimental-loader", "/usr/local/bin/codex", "dev"]
        )
        let loaderEquals = process(
            20,
            "bun",
            argv: ["bun", "--experimental-loader=/tmp/loader.js", "/tmp/codex"]
        )
        let loaderWatch = process(
            20,
            "bun",
            argv: ["bun", "--experimental-loader", "--watch", "/tmp/codex"]
        )
        let bunExe = process(
            20,
            "bun.exe",
            argv: ["bun.exe", "--experimental-loader", "/tmp/codex"]
        )
        let portPath = process(
            20, "bun", argv: ["bun", "--inspect-port", "/usr/local/bin/codex"]
        )
        let portEquals = process(
            20, "bun", argv: ["bun", "--inspect-port=9229", "/tmp/codex"]
        )
        let portWatch = process(
            20, "bun", argv: ["bun", "--inspect-port", "--watch", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, loader]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, loaderRun]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, loaderEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, loaderWatch]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bunExe]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, portPath]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, portEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, portWatch]) == 20)
        #expect(Diagnoser.cpuSamplePid([mcp, loader]) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, loader], foregroundProcessGroupId: 20) == 20)
        #expect(Diagnoser.cpuSamplePid([mcp, portPath]) == 10)
        #expect(
            Diagnoser.cpuSamplePid([mcp, portPath], foregroundProcessGroupId: 20) == 20
        )

        // The first word is the program. A port is not an address here.
        let loaderFirst = process(
            4,
            "bun",
            argv: [
                "bun", "--experimental-loader", "server.js", "/usr/local/bin/codex",
            ]
        )
        let portNumber = process(
            4,
            "bun",
            argv: ["bun", "--inspect-port", "9229", "/usr/local/bin/codex"]
        )
        let portHost = process(
            4,
            "bun",
            argv: ["bun", "--inspect-port", "127.0.0.1:9229", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([loaderFirst, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([portNumber, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([portHost, claude]) == 12)
        let falseLeader = process(
            20,
            "bun",
            argv: ["bun", "--inspect-port", "9229", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([mcp, falseLeader]) == 10)
        #expect(
            Diagnoser.cpuSamplePid(
                [mcp, falseLeader], foregroundProcessGroupId: 20
            ) == 10
        )

        // A `--loader` value with no colon makes bun exit. Neither word
        // is the script. `--require` still takes the next word.
        let loaderFlag = process(
            4,
            "bun",
            argv: ["bun", "--loader", "/usr/local/bin/codex", "server.js"]
        )
        let requireFlag = process(
            4, "bun", argv: ["bun", "--require", "codex", "server.js"]
        )
        let requireScript = process(
            20, "bun", argv: ["bun", "--require", "preload.js", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([loaderFlag, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([requireFlag, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, requireScript]) == 20)

        let letta = process(
            30,
            "bun",
            argv: ["bun", "--experimental-loader", "/home/user/node_modules/.bin/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, letta]) == 30)
        let oneShot = process(
            8,
            "bun",
            argv: [
                "bun", "--inspect-port",
                "/home/user/node_modules/.bin/letta", "--prompt", "hello",
            ]
        )
        let interactive = process(30, "letta", argv: ["letta"])
        #expect(Diagnoser.cpuSamplePid([oneShot, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([oneShot]) == 8)
        #expect(
            Diagnoser.cpuSamplePid([oneShot, interactive], foregroundProcessGroupId: 8) == 30
        )
        let portLetta = process(
            8,
            "bun",
            argv: [
                "bun", "--inspect-port", "9229",
                "/home/user/node_modules/.bin/letta",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([portLetta, interactive]) == 30)

        // Node still consumes the next word. The script is the one after it.
        let nodeLoaderValue = process(
            4,
            "node",
            argv: ["node", "--experimental-loader", "codex", "server.js"]
        )
        let nodeLoaderScript = process(
            20,
            "node",
            argv: ["node", "--experimental-loader", "/tmp/loader.js", "/usr/local/bin/codex"]
        )
        let nodeLoaderEquals = process(
            20,
            "nodejs",
            argv: ["nodejs", "--experimental-loader=/tmp/loader.js", "/tmp/codex"]
        )
        let nodePortValue = process(
            4, "node", argv: ["node", "--inspect-port", "codex", "server.js"]
        )
        let nodePortScript = process(
            20, "node", argv: ["node", "--inspect-port", "9229", "/usr/local/bin/codex"]
        )
        let nodePortEquals = process(
            20, "node.exe", argv: ["node.exe", "--inspect-port=9229", "/tmp/codex"]
        )
        let nodePortPath = process(
            4,
            "node",
            argv: ["node", "--inspect-port", "/usr/local/bin/codex", "server.js"]
        )
        #expect(Diagnoser.cpuSamplePid([nodeLoaderValue, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, nodeLoaderScript]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, nodeLoaderEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([nodePortValue, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, nodePortScript]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, nodePortEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([nodePortPath, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([mcp, nodePortScript]) == 10)
        #expect(
            Diagnoser.cpuSamplePid(
                [mcp, nodePortScript], foregroundProcessGroupId: 20
            ) == 20
        )

        // Deno still consumes both. The value named codex is not the script.
        let denoLoader = process(
            4, "deno", argv: ["deno", "run", "--experimental-loader", "codex", "server.js"]
        )
        let denoLoaderScript = process(
            20,
            "deno",
            argv: ["deno", "run", "--experimental-loader", "loader.js", "/tmp/codex"]
        )
        let denoPort = process(
            4, "deno", argv: ["deno", "--inspect-port", "9229", "server.js"]
        )
        let denoPortScript = process(
            20, "deno", argv: ["deno", "--inspect-port", "codex", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([denoLoader, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, denoLoaderScript]) == 20)
        #expect(Diagnoser.cpuSamplePid([denoPort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, denoPortScript]) == 20)

        // Python 3.13 rejects both and exits. A path after either is not
        // the script. A script written before the flag still is.
        let pythonLoader = process(
            4, "python3", argv: ["python3", "--experimental-loader", "/usr/local/bin/codex"]
        )
        let pythonLoaderNext = process(
            4,
            "python3",
            argv: ["python3", "--experimental-loader", "loader.js", "/tmp/codex"]
        )
        let pythonLoaderEquals = process(
            4,
            "python3.11",
            argv: ["python3.11", "--experimental-loader=/tmp/loader.js", "/tmp/codex"]
        )
        let pythonPort = process(
            4, "python3", argv: ["python3", "--inspect-port", "9229", "/tmp/codex"]
        )
        let pythonPortEquals = process(
            4, "Python.exe", argv: ["Python.exe", "--inspect-port=9229", "/tmp/codex"]
        )
        let pythonScriptFirst = process(
            20,
            "python3",
            argv: ["python3", "/tmp/codex", "--experimental-loader", "loader.js"]
        )
        let pythonLetta = process(
            40, "python3", argv: ["python3", "--inspect-port", "9229", "/tmp/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([pythonLoader, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([pythonLoaderNext, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([pythonLoaderEquals, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([pythonPort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([pythonPortEquals, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, pythonScriptFirst]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, pythonLetta]) == 10)
        #expect(Diagnoser.cpuSamplePid([pythonLetta, interactive]) == 30)
    }

    @Test("a node flag value is not the agent script")
    func nodeFlagValueIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])

        let title = process(4, "node", argv: ["node", "--title", "codex", "server.js"])
        let nodejsTitle = process(4, "nodejs", argv: ["nodejs", "--title", "codex", "server.js"])
        let warnings = process(
            4, "node", argv: ["node", "--redirect-warnings", "codex", "server.js"]
        )
        let profName = process(
            4,
            "node",
            argv: ["node", "--cpu-prof", "--cpu-prof-name", "codex", "server.js"]
        )
        let conditions = process(4, "node", argv: ["node", "-C", "codex", "server.js"])
        let diagnostic = process(
            4, "node", argv: ["node", "--diagnostic-dir", "/tmp/codex", "server.js"]
        )
        let inputType = process(
            4, "node", argv: ["node", "--input-type", "module", "server.js"]
        )
        let allowRead = process(
            4, "node", argv: ["node", "--allow-fs-read", "codex", "server.js"]
        )
        let testPattern = process(
            4, "node", argv: ["node", "--test-name-pattern", "codex", "server.js"]
        )
        #expect(Diagnoser.cpuSamplePid([title, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([nodejsTitle, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([warnings, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([profName, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([conditions, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([diagnostic, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([inputType, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([allowRead, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([testPattern, claude]) == 12)

        let titleScript = process(
            20, "node", argv: ["node", "--title", "helper", "/usr/local/bin/codex"]
        )
        let interval = process(
            20, "node.exe", argv: ["node.exe", "--cpu-prof-interval", "1000", "/tmp/codex"]
        )
        let attached = process(20, "node", argv: ["node", "--title=helper", "/tmp/codex"])
        let rejections = process(
            20,
            "node",
            argv: ["node", "--unhandled-rejections", "strict", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, titleScript]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, interval]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, attached]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, rejections]) == 20)

        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let leader = process(
            20,
            "node",
            argv: ["node", "--title", "helper", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([mcp, leader]) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, leader], foregroundProcessGroupId: 20) == 20)

        let letta = process(
            30,
            "node",
            argv: [
                "node", "--title", "app",
                "/home/user/node_modules/.bin/letta", "--conversation", "id",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([helper, letta]) == 30)
        let oneShot = process(
            8,
            "node",
            argv: ["node", "--diagnostic-dir", "/tmp", "letta", "--prompt", "hello"]
        )
        let interactive = process(30, "letta", argv: ["letta"])
        #expect(Diagnoser.cpuSamplePid([oneShot, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([oneShot]) == 8)
        #expect(
            Diagnoser.cpuSamplePid([oneShot, interactive], foregroundProcessGroupId: 8) == 30
        )

        // Python does not take node's flags. The next word is the script.
        let pythonTitle = process(4, "python3", argv: ["python3", "--title", "/tmp/codex"])
        #expect(Diagnoser.cpuSamplePid([pythonTitle, claude]) == 4)

        // `node --run`'s word is the package script, so that name stays the program.
        let packageRun = process(4, "node", argv: ["node", "--run", "codex"])
        #expect(Diagnoser.cpuSamplePid([packageRun, claude]) == 4)

        // Node's --inspect does not consume the next word. A port there is
        // the script, so the agent path after it is not this process.
        let nodeInspect = process(20, "node", argv: ["node", "--inspect", "./codex"])
        let nodeInspectPort = process(
            4, "node", argv: ["node", "--inspect", "9229", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, nodeInspect]) == 20)
        #expect(Diagnoser.cpuSamplePid([nodeInspectPort, claude]) == 12)
    }

    @Test("a dash word is not a node value, and a flag node rejects is not the script")
    func nodeDashValueAndRejectedFlagAreNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Node 22.23 exits when the next word starts with `-`. The path
        // after it does not run, so this node is not the group leader.
        let titleWatch = process(
            4, "node", argv: ["node", "--title", "--watch", "/usr/local/bin/codex"]
        )
        let requireWatch = process(
            4, "nodejs", argv: ["nodejs", "--require", "--watch", "/tmp/codex"]
        )
        let shortWatch = process(
            4, "node.exe", argv: ["node.exe", "-r", "--watch", "/tmp/codex"]
        )
        let portWatch = process(
            4, "node", argv: ["node", "--inspect-port", "--", "/usr/local/bin/codex"]
        )
        let envWatch = process(
            4, "node", argv: ["node", "--env-file", "-my.env", "/tmp/codex"]
        )
        let intervalWatch = process(
            4, "node", argv: ["node", "--cpu-prof-interval", "-1", "/tmp/codex"]
        )
        let conditionsWatch = process(
            4, "node", argv: ["node", "-C", "--watch", "/tmp/codex"]
        )
        let emptyTitle = process(4, "node", argv: ["node", "--title=", "/tmp/codex"])
        let emptyPort = process(4, "node", argv: ["node", "--require=", "/usr/local/bin/codex"])
        let missingTitle = process(4, "node", argv: ["node", "--title"])
        #expect(Diagnoser.cpuSamplePid([titleWatch, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([requireWatch, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([shortWatch, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([portWatch, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([envWatch, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([intervalWatch, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([conditionsWatch, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([emptyTitle, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([emptyPort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([missingTitle, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([mcp, titleWatch], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([titleWatch]) == 4)

        // A real value, including one glued with `=`, still names the script.
        let title = process(
            20, "node", argv: ["node", "--title", "helper", "/usr/local/bin/codex"]
        )
        let titled = process(20, "node", argv: ["node", "--title=helper", "/tmp/codex"])
        let preload = process(
            20, "node", argv: ["node", "-r", "./preload.js", "/usr/local/bin/codex"]
        )
        let required = process(
            20, "nodejs", argv: ["nodejs", "--require=./preload.js", "/tmp/codex"]
        )
        let dottedEnv = process(
            20, "node", argv: ["node", "--env-file", "./-my.env", "/tmp/codex"]
        )
        let scriptFirst = process(
            20, "node", argv: ["node", "/usr/local/bin/codex", "--title", "--watch"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, title]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, titled]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, preload]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, required]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, dottedEnv]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, scriptFirst]) == 20)

        // Node rejects the shared flags it does not own. The path after
        // the value, and a glued short, are not the program.
        let cwd = process(
            4, "node", argv: ["node", "--cwd", "/tmp", "/usr/local/bin/codex"]
        )
        let cwdEquals = process(
            4, "node.exe", argv: ["node.exe", "--cwd=/tmp", "/tmp/codex"]
        )
        let filter = process(
            4, "node", argv: ["node", "--filter", "pkg", "/usr/local/bin/codex"]
        )
        let pre = process(
            4, "nodejs", argv: ["nodejs", "--preload", "helper.js", "/tmp/codex"]
        )
        let tsconfig = process(
            4,
            "node",
            argv: ["node", "--tsconfig-override", "tsconfig.json", "/tmp/codex"]
        )
        let warning = process(
            4, "node", argv: ["node", "-W", "ignore", "/usr/local/bin/codex"]
        )
        let warningGlued = process(4, "node", argv: ["node", "-Wignore", "/tmp/codex"])
        let dev = process(4, "node", argv: ["node", "-X", "dev", "/tmp/codex"])
        let site = process(4, "node", argv: ["node", "-S", "ignore", "/tmp/codex"])
        let lib = process(4, "node", argv: ["node", "-L", "lib", "/tmp/codex"])
        let option = process(4, "node", argv: ["node", "-o", "pipefail", "/tmp/codex"])
        let filterShort = process(4, "node", argv: ["node", "-F", "pkg", "/tmp/codex"])
        let conditionsGlued = process(4, "node", argv: ["node", "-Cdev", "/tmp/codex"])
        let requireGlued = process(
            4, "node", argv: ["node", "-rpreload.js", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([cwd, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([cwdEquals, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([filter, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([pre, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([tsconfig, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([warning, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([warningGlued, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([dev, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([site, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([lib, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([option, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([filterShort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([conditionsGlued, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([requireGlued, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([mcp, cwd], foregroundProcessGroupId: 4) == 10)
        let cwdFirst = process(
            20, "node", argv: ["node", "/usr/local/bin/codex", "--cwd", "/tmp"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, cwdFirst]) == 20)

        // The same shape on Bun still runs. `-W` does not: bun exits.
        let bunTitle = process(
            20, "bun", argv: ["bun", "--title", "--watch", "/usr/local/bin/codex"]
        )
        let bunCwd = process(
            20, "bun", argv: ["bun", "--cwd", "/tmp", "/usr/local/bin/codex"]
        )
        let bunRequire = process(
            20, "bun", argv: ["bun", "-r./preload.js", "/tmp/codex"]
        )
        let bunWarning = process(
            4, "bun", argv: ["bun", "-W", "ignore", "/usr/local/bin/codex"]
        )
        let bunGlued = process(4, "bun.exe", argv: ["bun.exe", "-Wignore", "/tmp/codex"])
        let bunOption = process(4, "bun", argv: ["bun", "-o", "pipefail", "/tmp/codex"])
        #expect(Diagnoser.cpuSamplePid([helper, bunTitle]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bunCwd]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bunRequire]) == 20)
        #expect(Diagnoser.cpuSamplePid([bunWarning, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([bunGlued, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([bunOption, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([mcp, bunWarning], foregroundProcessGroupId: 4) == 10)
        #expect(
            Diagnoser.cpuSamplePid([mcp, bunTitle], foregroundProcessGroupId: 20) == 20
        )

        // Python still takes `-W` and `-X`. The next word is the script.
        let pythonWarning = process(
            20, "python3", argv: ["python3", "-W", "ignore", "/usr/local/bin/codex"]
        )
        let pythonDev = process(
            20, "python3.11", argv: ["python3.11", "-Xdev", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, pythonWarning]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, pythonDev]) == 20)

        // A dash word or a rejected flag in front of Letta is not the TUI.
        // `bun --title --watch` still is.
        let falseLetta = process(
            8,
            "node",
            argv: [
                "node", "--title", "--watch",
                "/home/user/node_modules/.bin/letta",
            ]
        )
        let cwdLetta = process(
            8,
            "node",
            argv: ["node", "--cwd", "/tmp", "/home/user/node_modules/.bin/letta"]
        )
        let cwdPrompt = process(
            9,
            "node",
            argv: ["node", "--cwd", "/tmp", "/home/user/node_modules/.bin/letta", "--prompt", "hi"]
        )
        #expect(Diagnoser.cpuSamplePid([falseLetta, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([falseLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([falseLetta]) == 8)
        #expect(Diagnoser.cpuSamplePid([mcp, falseLetta], foregroundProcessGroupId: 8) == 10)
        #expect(Diagnoser.cpuSamplePid([cwdLetta, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([cwdLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([cwdPrompt, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([cwdPrompt]) == 9)
        let bunLetta = process(
            30,
            "bun",
            argv: [
                "bun", "--title", "--watch",
                "/home/user/node_modules/.bin/letta", "--conversation", "id",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([helper, bunLetta]) == 30)
        let bunWarningLetta = process(
            8,
            "bun",
            argv: ["bun", "-W", "ignore", "/home/user/node_modules/.bin/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([bunWarningLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([bunWarningLetta]) == 8)
    }

    @Test("a deno flag value is not the agent script")
    func denoFlagValueIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])

        let importMap = process(
            4, "deno", argv: ["deno", "run", "--import-map", "codex", "server.js"]
        )
        let cert = process(
            4, "deno", argv: ["deno", "run", "--cert", "codex", "server.js"]
        )
        let location = process(
            4,
            "deno",
            argv: ["deno", "run", "--location", "https://example.com/codex", "server.js"]
        )
        let ext = process(4, "deno", argv: ["deno", "run", "--ext", "codex", "server.js"])
        let conditions = process(
            4, "deno", argv: ["deno", "run", "--conditions", "codex", "server.js"]
        )
        let seed = process(4, "deno", argv: ["deno", "run", "--seed", "codex", "server.js"])
        let minDep = process(
            4, "deno", argv: ["deno", "run", "--min-dep-age", "codex", "server.js"]
        )
        let linker = process(
            4, "deno", argv: ["deno", "run", "--node-modules-linker", "codex", "server.js"]
        )
        let lock = process(4, "deno", argv: ["deno", "run", "--lock", "codex", "server.js"])
        let publish = process(
            4, "deno", argv: ["deno", "run", "--inspect-publish-uid", "codex", "server.js"]
        )
        let logLevel = process(
            4, "deno", argv: ["deno", "run", "--log-level", "codex", "server.js"]
        )
        let config = process(
            4, "deno", argv: ["deno", "run", "--config", "codex", "server.js"]
        )
        #expect(Diagnoser.cpuSamplePid([importMap, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([cert, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([location, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([ext, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([conditions, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([seed, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([minDep, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([linker, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([lock, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([publish, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([logLevel, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([config, claude]) == 12)

        let mapped = process(
            20, "deno", argv: ["deno", "--import-map", "/tmp/map.json", "/tmp/codex"]
        )
        let configured = process(
            20, "deno", argv: ["deno", "run", "-c", "/tmp/deno.json", "/tmp/codex"]
        )
        let gluedConfig = process(
            20, "deno.exe", argv: ["deno.exe", "run", "-c/tmp/deno.json", "/tmp/codex"]
        )
        let equalsConfig = process(
            20, "deno", argv: ["deno", "-c=/tmp/deno.json", "/usr/local/bin/codex"]
        )
        let served = process(
            20, "deno", argv: ["deno", "serve", "--port", "8000", "/tmp/codex"]
        )
        let servedHost = process(
            20, "deno", argv: ["deno", "--host", "127.0.0.1", "serve", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, mapped]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, configured]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, gluedConfig]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, equalsConfig]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, served]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, servedHost]) == 20)

        // The value's basename is an agent. The script after it is not.
        let servePort = process(
            4, "deno", argv: ["deno", "serve", "--port", "codex", "server.js"]
        )
        let serveHostName = process(
            4, "deno", argv: ["deno", "serve", "--host", "codex", "server.js"]
        )
        #expect(Diagnoser.cpuSamplePid([servePort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([serveHostName, claude]) == 12)

        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let leader = process(
            20,
            "deno",
            argv: ["deno", "run", "--import-map", "helper.json", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([mcp, leader]) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, leader], foregroundProcessGroupId: 20) == 20)

        // These do not consume a separate word on Deno 2.9.7. The path is
        // the script. Node still consumes `--env-file` and `-r`.
        let reloaded = process(20, "deno", argv: ["deno", "run", "-r", "/tmp/codex"])
        let allowWrite = process(20, "deno", argv: ["deno", "run", "-W", "/tmp/codex"])
        let allowSys = process(20, "deno", argv: ["deno", "run", "-S", "/tmp/codex"])
        let envFile = process(20, "deno", argv: ["deno", "run", "--env-file", "/tmp/codex"])
        let envEquals = process(
            20, "deno", argv: ["deno", "run", "--env-file=/tmp/dev.env", "/tmp/codex"]
        )
        let allowRead = process(
            20, "deno", argv: ["deno", "run", "--allow-read", "/tmp/codex"]
        )
        let inspect = process(20, "deno", argv: ["deno", "run", "--inspect", "./codex"])
        let modulesMode = process(
            20, "deno", argv: ["deno", "run", "--node-modules-dir=manual", "/tmp/codex"]
        )
        let lockQuiet = process(
            20, "deno", argv: ["deno", "run", "--lock", "--quiet", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, reloaded]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, allowWrite]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, allowSys]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, envFile]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, envEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, allowRead]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, inspect]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, modulesMode]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, lockQuiet]) == 20)

        let inspectPort = process(
            4, "deno", argv: ["deno", "run", "--inspect", "127.0.0.1:9229", "/tmp/codex"]
        )
        let modulesWord = process(
            4, "deno", argv: ["deno", "run", "--node-modules-dir", "manual", "/tmp/codex"]
        )
        // One condition is consumed. The next word is the script, so a
        // second condition named `codex` is the agent, not another value.
        let secondCondition = process(
            4, "deno", argv: ["deno", "run", "--conditions", "a", "codex"]
        )
        #expect(Diagnoser.cpuSamplePid([inspectPort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([modulesWord, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([secondCondition, claude]) == 4)

        let nodeEnv = process(
            4, "node", argv: ["node", "--env-file", "codex", "server.js"]
        )
        let nodeRequire = process(
            20, "node", argv: ["node", "-r", "preload.js", "/tmp/codex"]
        )
        // Node rejects `--import-map`. Deno still consumes it above.
        let nodeImportMap = process(
            4, "node", argv: ["node", "--import-map", "codex", "server.js"]
        )
        let pythonWarn = process(
            20, "python3", argv: ["python3", "-W", "ignore", "/tmp/codex"]
        )
        let pythonEval = process(
            4, "python3", argv: ["python3", "-c", "code", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([nodeEnv, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, nodeRequire]) == 20)
        #expect(Diagnoser.cpuSamplePid([nodeImportMap, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, pythonWarn]) == 20)
        #expect(Diagnoser.cpuSamplePid([pythonEval, claude]) == 12)

        // Deno is not a Letta entrypoint. The file named letta stays a
        // plain runtime, and the interactive TUI is the sample.
        let denoLetta = process(
            40,
            "deno",
            argv: [
                "deno", "run", "--import-map", "map.json",
                "/tmp/letta", "--conversation", "id",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([helper, denoLetta]) == 10)
        let interactive = process(30, "letta", argv: ["letta"])
        #expect(Diagnoser.cpuSamplePid([denoLetta, interactive]) == 30)
    }

    @Test("The shell that is the agent interpreter is the sample when nothing else is")
    func interpreterShellIsTheSample() {
        let shell = process(2, "sh", argv: ["sh", "codex"])
        #expect(Diagnoser.cpuSamplePid([shell]) == 2)
    }

    @Test("A bare shell is not a CPU sample")
    func bareShellIsNotSampled() {
        let shells = [
            process(10, "zsh", argv: ["-zsh"]),
            process(11, "bash", argv: ["bash"]),
        ]
        #expect(Diagnoser.cpuSamplePid(shells) == nil)
        #expect(Diagnoser.cpuSamplePid([]) == nil)
        #expect(Diagnoser.cpuSamplePid([process(0, "node", argv: ["node", "codex"])]) == nil)
        let git = process(5, "git", argv: ["git", "status"])
        #expect(Diagnoser.cpuSamplePid([
            process(0, "node", argv: ["node", "codex"]),
            git,
        ]) == 5)
    }

    @Test("A generic runtime outranks an unrelated helper, and the older pid wins a tie")
    func runtimeOutranksHelperAndLowerPidWins() {
        let git = process(40, "git", argv: ["git", "status"])
        let python = process(15, "python3.11", argv: ["python3.11", "tool.py"])
        #expect(Diagnoser.cpuSamplePid([git, python]) == 15)
        let newer = process(22, "node", argv: ["node", "a.js"])
        let older = process(18, "node", argv: ["node", "b.js"])
        #expect(Diagnoser.cpuSamplePid([newer, older]) == 18)
        // `python3.` is not a python runtime. A real node still outranks it.
        let dotted = process(5, "python3.", argv: ["python3.", "tool.py"])
        let node = process(50, "node", argv: ["node", "server.js"])
        #expect(Diagnoser.cpuSamplePid([dotted, node]) == 50)
    }

    @Test("MainThread with a node argv0 is the runtime")
    func mainThreadNode() {
        let shell = process(7, "zsh")
        let node = process(8, "MainThread", argv: ["node", "codex"], argv0: "node")
        #expect(Diagnoser.cpuSamplePid([shell, node]) == 8)
    }

    @Test("The agent binary is the sample, not the shell that launched it")
    func directAgentOutranksItsShell() {
        let shell = process(2, "sh", argv: ["sh", "claude"])
        let claude = process(8, "claude", argv: ["claude"])
        #expect(Diagnoser.cpuSamplePid([shell, claude]) == 8)
        #expect(Diagnoser.cpuSamplePid([claude, shell]) == 8)
        let helper = process(1, "node", argv: ["node", "server.js"])
        #expect(Diagnoser.cpuSamplePid([helper, shell, claude]) == 8)
    }

    @Test("A wrapper whose argv0 is the agent outranks a helper runtime")
    func wrapperArgv0IsTheSample() {
        let helper = process(3, "node", argv: ["node", "server.js"])
        let wrapped = process(
            40,
            ".codex-wrapped",
            argv: ["/etc/profiles/per-user/user/bin/codex", "--model", "gpt-5"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, wrapped]) == 40)
        #expect(Diagnoser.cpuSamplePid([wrapped, helper]) == 40)
        let shell = process(2, "sh", argv: ["sh", "/etc/profiles/per-user/user/bin/codex"])
        #expect(Diagnoser.cpuSamplePid([shell, helper, wrapped]) == 40)

        let main = process(
            15,
            "MainThread",
            argv: ["/home/user/.local/share/pnpm/global/node_modules/opencode-ai/bin/opencode.exe"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, main]) == 15)

        let fromArgv0 = process(11, "MainThread", argv0: "/nix/store/example/bin/claude-code")
        #expect(Diagnoser.cpuSamplePid([helper, fromArgv0]) == 11)

        let fromCmdline = process(
            12,
            ".codex-wrapped",
            cmdline: "/etc/profiles/per-user/user/bin/codex --model gpt-5"
        )
        #expect(Diagnoser.cpuSamplePid([helper, fromCmdline]) == 12)

        // The basename is not an agent. The helper runtime stays the sample.
        let other = process(40, ".codex-wrapped", argv: ["/tmp/my-codex-helper"])
        #expect(Diagnoser.cpuSamplePid([helper, other]) == 3)
        // Eval is not a script, so a later path does not make this node the agent.
        let eval = process(9, "node", argv: ["node", "-e", "setTimeout(() => {}, 60000)", "/tmp/codex"])
        #expect(Diagnoser.cpuSamplePid([eval, wrapped]) == 40)
    }

    @Test("A glued eval or module flag is not a script, so a later agent path is not the process")
    func gluedEvalIsNotTheAgent() {
        let wrapped = process(
            40,
            ".codex-wrapped",
            argv: ["/etc/profiles/per-user/user/bin/codex"]
        )
        let claude = process(42, "claude", argv: ["claude"])
        let interactive = process(30, "letta", argv: ["letta", "--backend", "local"])
        let vectors: [[String]] = [
            ["node", "-econsole.log(1)", "/tmp/codex"],
            ["node", "--eval=console.log(1)", "/tmp/codex"],
            ["node", "-pconsole.log(1)", "/tmp/codex"],
            ["bun", "--print=1", "/tmp/codex"],
            ["python3", "-cimport time", "/tmp/codex"],
            ["python3.11", "-mhttp.server", "/tmp/codex"],
            ["node", "-m=codex", "/tmp/other"],
            ["nodejs", "-eCODE", "--", "/tmp/codex"],
        ]
        for argv in vectors {
            let eval = process(9, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([eval, wrapped]) == 40)
            // The glued node is not the leader herdr would return.
            #expect(Diagnoser.cpuSamplePid([eval, claude], foregroundProcessGroupId: 9) == 42)
        }
        let lettaEval = process(
            9,
            "node",
            argv: ["node", "-econsole.log(1)", "/home/user/project/node_modules/.bin/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([lettaEval, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([lettaEval, interactive], foregroundProcessGroupId: 9) == 30)

        // Alone, the eval process is still the only sample.
        let only = process(9, "node", argv: ["node", "--eval=console.log(1)", "/tmp/codex"])
        #expect(Diagnoser.cpuSamplePid([only]) == 9)

        // A real script after an ordinary flag, or after `--`, is still the agent.
        let script = process(4, "node", argv: ["node", "--experimental-strip-types", "codex"])
        #expect(Diagnoser.cpuSamplePid([script, claude]) == 4)
        let dashed = process(4, "node", argv: ["node", "--", "codex"])
        #expect(Diagnoser.cpuSamplePid([dashed]) == 4)
        // Node 22 rejects a preload glued onto `-r`. A separate word is the value.
        let gluedRequire = process(4, "node", argv: ["node", "-rpreload.js", "codex"])
        #expect(Diagnoser.cpuSamplePid([gluedRequire, claude]) == 42)
        let required = process(4, "node", argv: ["node", "-r", "preload.js", "codex"])
        #expect(Diagnoser.cpuSamplePid([required, claude]) == 4)
    }

    @Test("Windows Cursor's bundled node is the sample, and a lookalike is not")
    func cursorBundledNodeIsTheSample() {
        let version = #"C:\Users\user\AppData\Local\cursor-agent\versions\2026.08.11-e8db854"#
        let cursor = process(
            30,
            "node.exe",
            argv: [version + #"\node.exe"#, version + #"\index.js"#]
        )
        let helper = process(4, "node", argv: ["node", "server.js"])
        #expect(Diagnoser.cpuSamplePid([helper, cursor]) == 30)
        #expect(Diagnoser.cpuSamplePid([cursor, helper]) == 30)

        let postinstall = process(
            3,
            "node.exe",
            argv: [version + #"\node.exe"#, version + #"\scripts\postinstall.js"#]
        )
        let claude = process(12, "claude", argv: ["claude"])
        #expect(Diagnoser.cpuSamplePid([postinstall, claude]) == 12)

        let lookalike = process(
            3,
            "node.exe",
            argv: [
                #"C:\Program Files\nodejs\node.exe"#,
                #"C:\workspace\cursor-agent\versions\test\index.js"#,
            ]
        )
        #expect(Diagnoser.cpuSamplePid([lookalike, claude]) == 12)
        let git = process(8, "git", argv: ["git", "status"])
        #expect(Diagnoser.cpuSamplePid([lookalike, git]) == 3)

        // herdr's bundle check is `node.exe`, not `node`. The script agent wins.
        let macNode = process(
            30,
            "node",
            argv: [
                "/Users/user/.local/share/cursor-agent/versions/2026.08.11/node",
                "/Users/user/.local/share/cursor-agent/versions/2026.08.11/index.js",
            ]
        )
        let script = process(4, "node", argv: ["node", "codex"])
        #expect(Diagnoser.cpuSamplePid([macNode, script]) == 4)
    }

    @Test("The foreground group leader herdr calls the agent is the sample")
    func groupLeaderIsTheSample() {
        let claude = process(42, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        // No group id: same rank, and the runtime wins the tie.
        #expect(Diagnoser.cpuSamplePid([claude, mcp]) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, claude]) == 10)
        #expect(Diagnoser.cpuSamplePid([claude, mcp], foregroundProcessGroupId: 42) == 42)
        #expect(Diagnoser.cpuSamplePid([mcp, claude], foregroundProcessGroupId: 42) == 42)

        let codex = process(7, "codex", argv: ["codex"])
        #expect(Diagnoser.cpuSamplePid([claude, codex]) == 7)
        #expect(Diagnoser.cpuSamplePid([claude, codex], foregroundProcessGroupId: 42) == 42)

        // The leader is the runtime herdr names, not the other agent.
        #expect(Diagnoser.cpuSamplePid([claude, mcp], foregroundProcessGroupId: 10) == 10)

        let shell = process(4, "bash", argv: ["bash"])
        let node = process(43, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        #expect(Diagnoser.cpuSamplePid([shell, node], foregroundProcessGroupId: 4) == 43)

        let interpreter = process(2, "sh", argv: ["sh", "claude"])
        #expect(Diagnoser.cpuSamplePid([interpreter, claude], foregroundProcessGroupId: 2) == 42)

        #expect(Diagnoser.cpuSamplePid([claude, mcp], foregroundProcessGroupId: 99) == 10)
        #expect(Diagnoser.cpuSamplePid([claude, mcp], foregroundProcessGroupId: 0) == 10)

        // Two plain runtimes are not agents. The leader does not break the tie.
        let older = process(18, "node", argv: ["node", "a.js"])
        let newer = process(22, "node", argv: ["node", "b.js"])
        #expect(Diagnoser.cpuSamplePid([newer, older], foregroundProcessGroupId: 22) == 18)
    }

    @Test("A one-shot Letta is not the interactive agent")
    func noninteractiveLettaIsNotTheAgent() {
        let interactive = process(30, "letta", argv: ["letta", "--backend", "local"])
        let helper = process(4, "node", argv: ["node", "server.js"])
        #expect(Diagnoser.cpuSamplePid([helper, interactive]) == 30)

        let equalsBackend = process(33, "letta", argv: ["letta", "--backend=local"])
        #expect(Diagnoser.cpuSamplePid([helper, equalsBackend]) == 33)
        let spaced = process(34, "Letta Code.exe", argv: ["Letta Code.exe", "--backend", "local"])
        #expect(Diagnoser.cpuSamplePid([helper, spaced]) == 34)

        // herdr's entrypoint walk is node/bun. python is not the TUI.
        let python = process(40, "python3", argv: ["python3", "/tmp/letta", "--prompt", "hi"])
        #expect(Diagnoser.cpuSamplePid([python, interactive]) == 30)
        let pythonBare = process(41, "python3", argv: ["python3", "/tmp/letta"])
        #expect(Diagnoser.cpuSamplePid([pythonBare, interactive]) == 30)

        let bare = process(21, "letta", argv: ["letta"])
        #expect(Diagnoser.cpuSamplePid([helper, bare]) == 21)
        let named = process(23, "letta")
        #expect(Diagnoser.cpuSamplePid([helper, named]) == 23)

        let conversation = process(
            31,
            "node",
            argv: ["node", "/home/user/project/node_modules/.bin/letta", "--conversation", "id"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, conversation]) == 31)

        let windows = process(
            32,
            "node.exe",
            argv: [
                "node.exe",
                #"C:\Users\user\AppData\Roaming\npm\node_modules\@letta-ai\letta-code\letta.js"#,
                "--agent",
                "agent-id",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([helper, windows]) == 32)

        let prompt = process(
            5,
            "node",
            argv: ["node", "/home/user/project/node_modules/.bin/letta", "--prompt", "hello"]
        )
        #expect(Diagnoser.cpuSamplePid([prompt, interactive]) == 30)
        // The only foreground process is still a sample.
        #expect(Diagnoser.cpuSamplePid([prompt]) == 5)

        let server = process(6, "letta", argv: ["letta", "server"])
        #expect(Diagnoser.cpuSamplePid([server, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([server]) == 6)
        #expect(Diagnoser.cpuSamplePid([server, interactive], foregroundProcessGroupId: 6) == 30)

        let leaderPrompt = process(8, "letta", argv: ["letta", "--prompt", "hello"])
        #expect(Diagnoser.cpuSamplePid([leaderPrompt, interactive], foregroundProcessGroupId: 8) == 30)

        let turns = process(9, "letta", argv: ["letta", "--max-turns=1"])
        #expect(Diagnoser.cpuSamplePid([turns, interactive]) == 30)
        let format = process(11, "node", argv: ["node", "letta", "--output-format", "json"])
        #expect(Diagnoser.cpuSamplePid([format, interactive]) == 30)
        let inputFormat = process(15, "letta", argv: ["letta", "--input-format=stream-json"])
        #expect(Diagnoser.cpuSamplePid([inputFormat, interactive]) == 30)
        let ephemeral = process(12, "letta", argv: ["letta", "--ephemeral"])
        #expect(Diagnoser.cpuSamplePid([ephemeral, interactive]) == 30)
        let backendServer = process(13, "letta", argv: ["letta", "--backend", "local", "server"])
        #expect(Diagnoser.cpuSamplePid([backendServer, interactive]) == 30)
        let positional = process(14, "letta", argv: ["letta", "fix"])
        #expect(Diagnoser.cpuSamplePid([positional, interactive]) == 30)
        let help = process(17, "letta", argv: ["letta", "--help"])
        #expect(Diagnoser.cpuSamplePid([help, interactive]) == 30)

        let unrelated = process(3, "node", argv: ["node", "/tmp/server.js", "letta"])
        #expect(Diagnoser.cpuSamplePid([unrelated, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([unrelated, helper]) == 3)

        let checkout = process(
            16,
            "node",
            argv: ["node", "/home/user/src/letta-code/letta/build.js"]
        )
        #expect(Diagnoser.cpuSamplePid([checkout, interactive]) == 30)

        let eval = process(19, "node", argv: ["node", "-e", "letta"])
        #expect(Diagnoser.cpuSamplePid([eval, interactive]) == 30)

        // The shell that is launching Letta stays the sample when it is alone.
        let shell = process(2, "sh", argv: ["sh", "letta"])
        #expect(Diagnoser.cpuSamplePid([shell]) == 2)
        #expect(Diagnoser.cpuSamplePid([shell, interactive]) == 30)
    }

    @Test("node's --debug-port is the inspect port, and bun's word is the script")
    func nodeDebugPortIsTheInspectPort() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])

        // Node 22.23 consumes the next word unless it starts with `-`.
        let port = process(
            20, "node", argv: ["node", "--debug-port", "9229", "/usr/local/bin/codex"]
        )
        let nodejsPort = process(
            20, "nodejs", argv: ["nodejs", "--debug-port", "localhost:9229", "/tmp/codex"]
        )
        let bracket = process(
            20, "node.exe", argv: ["node.exe", "--debug-port", "[::1]:9229", "/tmp/codex"]
        )
        let equals = process(
            20, "node", argv: ["node", "--debug-port=9229", "/tmp/codex"]
        )
        let equalsDash = process(
            20, "node", argv: ["node", "--debug-port=-", "/usr/local/bin/codex"]
        )
        let scriptFirst = process(
            20, "node", argv: ["node", "/usr/local/bin/codex", "--debug-port", "9229"]
        )
        let afterWatch = process(
            20,
            "node",
            argv: ["node", "--debug-port", "9229", "--watch", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, port]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, nodejsPort]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bracket]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, equals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, equalsDash]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, scriptFirst]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, afterWatch]) == 20)
        #expect(Diagnoser.cpuSamplePid([mcp, port]) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, port], foregroundProcessGroupId: 20) == 20)

        // The port word is not the script, including when it is an agent path.
        let namedPort = process(
            4, "node", argv: ["node", "--debug-port", "codex", "server.js"]
        )
        let pathPort = process(
            4, "node", argv: ["node", "--debug-port", "/usr/local/bin/codex", "server.js"]
        )
        let onlyPort = process(
            4, "node", argv: ["node", "--debug-port", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([namedPort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([pathPort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([onlyPort, claude]) == 12)

        // A missing port makes node exit. The path after it is not the script.
        let watch = process(
            4, "node", argv: ["node", "--debug-port", "--watch", "/usr/local/bin/codex"]
        )
        let doubleDash = process(
            4, "node", argv: ["node", "--debug-port", "--", "/usr/local/bin/codex"]
        )
        let dash = process(
            4, "node", argv: ["node", "--debug-port", "-", "/usr/local/bin/codex"]
        )
        let negative = process(
            4, "node", argv: ["node", "--debug-port", "-1", "/tmp/codex"]
        )
        let emptyEquals = process(
            4, "node", argv: ["node", "--debug-port=", "/tmp/codex"]
        )
        let missing = process(4, "node", argv: ["node", "--debug-port"])
        #expect(Diagnoser.cpuSamplePid([watch, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([doubleDash, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([dash, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([negative, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([emptyEquals, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([missing, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([mcp, watch], foregroundProcessGroupId: 4) == 10)

        let letta = process(
            30,
            "node",
            argv: [
                "node", "--debug-port", "9229",
                "/home/user/node_modules/.bin/letta", "--conversation", "id",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([helper, letta]) == 30)
        let lettaEquals = process(
            30,
            "node",
            argv: ["node", "--debug-port=9229", "/home/user/node_modules/.bin/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, lettaEquals]) == 30)
        let oneShot = process(
            8,
            "node",
            argv: [
                "node", "--debug-port", "9229",
                "/home/user/node_modules/.bin/letta", "--prompt", "hello",
            ]
        )
        let interactive = process(30, "letta", argv: ["letta"])
        #expect(Diagnoser.cpuSamplePid([oneShot, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([oneShot]) == 8)
        #expect(
            Diagnoser.cpuSamplePid([oneShot, interactive], foregroundProcessGroupId: 8) == 30
        )
        let portIsLetta = process(
            8,
            "node",
            argv: [
                "node", "--debug-port",
                "/home/user/node_modules/.bin/letta", "server.js",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([portIsLetta, interactive]) == 30)

        // Bun 1.4.2 does not consume the flag. The next word is the script.
        let bunPath = process(
            20, "bun", argv: ["bun", "--debug-port", "/usr/local/bin/codex"]
        )
        let bunRun = process(
            20, "bun", argv: ["bun", "run", "--debug-port", "/tmp/codex"]
        )
        let bunEquals = process(
            20, "bun.exe", argv: ["bun.exe", "--debug-port=9229", "/tmp/codex"]
        )
        let bunDash = process(
            20, "bun", argv: ["bun", "--debug-port=-", "/tmp/codex"]
        )
        let bunWatch = process(
            20, "bun", argv: ["bun", "--debug-port", "--watch", "/tmp/codex"]
        )
        let bunEnd = process(
            20, "bun", argv: ["bun", "--debug-port", "--", "/usr/local/bin/codex"]
        )
        let bunRunWatch = process(
            20, "bun", argv: ["bun", "run", "--debug-port", "--watch", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, bunPath]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bunRun]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bunEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bunDash]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bunWatch]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bunEnd]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bunRunWatch]) == 20)
        #expect(Diagnoser.cpuSamplePid([mcp, bunPath]) == 10)
        #expect(
            Diagnoser.cpuSamplePid([mcp, bunPath], foregroundProcessGroupId: 20) == 20
        )

        let bunPort = process(
            4, "bun", argv: ["bun", "--debug-port", "9229", "/usr/local/bin/codex"]
        )
        let bunRunPort = process(
            4, "bun", argv: ["bun", "run", "--debug-port", "9229", "/tmp/codex"]
        )
        let bunHost = process(
            4, "bun", argv: ["bun", "--debug-port", "127.0.0.1:9229", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([bunPort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([bunRunPort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([bunHost, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([mcp, bunPort]) == 10)
        #expect(
            Diagnoser.cpuSamplePid([mcp, bunPort], foregroundProcessGroupId: 4) == 10
        )

        let bunLetta = process(
            30,
            "bun",
            argv: ["bun", "--debug-port", "/home/user/node_modules/.bin/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, bunLetta]) == 30)
        let bunPortLetta = process(
            8,
            "bun",
            argv: [
                "bun", "--debug-port", "9229",
                "/home/user/node_modules/.bin/letta",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([bunPortLetta, interactive]) == 30)
        let bunOneShot = process(
            8,
            "bun",
            argv: [
                "bun", "--debug-port",
                "/home/user/node_modules/.bin/letta", "--prompt", "hello",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([bunOneShot, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([bunOneShot]) == 8)

        // Python 3.13 rejects the flag and exits. A script before it still runs.
        let pythonPort = process(
            4, "python3", argv: ["python3", "--debug-port", "/usr/local/bin/codex"]
        )
        let pythonNext = process(
            4, "python3", argv: ["python3", "--debug-port", "9229", "/tmp/codex"]
        )
        let pythonEquals = process(
            4, "python3.11", argv: ["python3.11", "--debug-port=9229", "/tmp/codex"]
        )
        let pythonDash = process(
            4, "Python.exe", argv: ["Python.exe", "--debug-port=-", "/tmp/codex"]
        )
        let pythonFirst = process(
            20, "python3", argv: ["python3", "/tmp/codex", "--debug-port", "9229"]
        )
        let pythonLetta = process(
            40, "python3", argv: ["python3", "--debug-port", "/tmp/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([pythonPort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([pythonNext, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([pythonEquals, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([pythonDash, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, pythonFirst]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, pythonLetta]) == 10)
        #expect(Diagnoser.cpuSamplePid([pythonLetta, interactive]) == 30)
    }

    @Test("bun's --loader value needs a colon, and the script is the word after it")
    func bunLoaderValueNeedsAColon() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Bun 1.4.2 runs the file after a value that contains `:`.
        let colon = process(
            20, "bun", argv: ["bun", "--loader", ".js:jsx", "/usr/local/bin/codex"]
        )
        let colonRun = process(
            20, "bun", argv: ["bun", "run", "--loader", ".md:text", "/tmp/codex"]
        )
        let colonEquals = process(
            20, "bun", argv: ["bun", "--loader=.js:jsx", "/tmp/codex"]
        )
        let colonCase = process(
            20, "bun", argv: ["bun", "--loader", ".JS:JSX", "/tmp/codex"]
        )
        let colonOnly = process(
            20, "bun", argv: ["bun", "--loader=:jsx", "/usr/local/bin/codex"]
        )
        let short = process(
            20, "bun", argv: ["bun", "-l", ".js:jsx", "/usr/local/bin/codex"]
        )
        let shortGlued = process(
            20, "bun", argv: ["bun", "-l.js:jsx", "/tmp/codex"]
        )
        let shortEquals = process(
            20, "bun.exe", argv: ["bun.exe", "-l=.js:jsx", "/tmp/codex"]
        )
        let shortColon = process(
            20, "bun", argv: ["bun", "-l:jsx", "/usr/local/bin/codex"]
        )
        let watch = process(
            20, "bun", argv: ["bun", "--loader", ".js:jsx", "--watch", "/tmp/codex"]
        )
        let scriptFirst = process(
            20, "bun", argv: ["bun", "/usr/local/bin/codex", "--loader", "nocolon"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, colon]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, colonRun]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, colonEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, colonCase]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, colonOnly]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, short]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, shortGlued]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, shortEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, shortColon]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, watch]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, scriptFirst]) == 20)
        #expect(Diagnoser.cpuSamplePid([mcp, colon]) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, colon], foregroundProcessGroupId: 20) == 20)

        // No colon: bun exits, and the agent path after the value is not
        // the script. That bun does not take the sample as the leader.
        let noColon = process(
            4,
            "bun",
            argv: ["bun", "--loader", "/tmp/codex.js", "/usr/local/bin/codex"]
        )
        let noColonRun = process(
            4, "bun", argv: ["bun", "run", "--loader", "nope", "/tmp/codex"]
        )
        let noColonEquals = process(
            4, "bun", argv: ["bun", "--loader=script.js", "/usr/local/bin/codex"]
        )
        let emptyEquals = process(
            4, "bun", argv: ["bun", "--loader=", "/tmp/codex"]
        )
        let shortBad = process(
            4, "bun", argv: ["bun", "-l", "nocolon", "/usr/local/bin/codex"]
        )
        let shortGluedBad = process(
            4, "bun.exe", argv: ["bun.exe", "-lnocolon", "/tmp/codex"]
        )
        let shortEqualsBad = process(
            4, "bun", argv: ["bun", "-l=script.js", "/tmp/codex"]
        )
        let watchValue = process(
            4, "bun", argv: ["bun", "--loader", "--watch", "/usr/local/bin/codex"]
        )
        let missing = process(4, "bun", argv: ["bun", "--loader"])
        #expect(Diagnoser.cpuSamplePid([noColon, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([noColonRun, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([noColonEquals, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([emptyEquals, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([shortBad, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([shortGluedBad, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([shortEqualsBad, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([watchValue, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([missing, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([mcp, noColon]) == 10)
        #expect(
            Diagnoser.cpuSamplePid([mcp, noColon], foregroundProcessGroupId: 4) == 10
        )

        // The word after a real mapping is the program, including Letta.
        // A value with no colon is not that program.
        let letta = process(
            30,
            "bun",
            argv: ["bun", "--loader", ".js:jsx", "/home/user/node_modules/.bin/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, letta]) == 30)
        let shortLetta = process(
            30,
            "bun",
            argv: ["bun", "-l", ".md:text", "/home/user/node_modules/.bin/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, shortLetta]) == 30)
        let oneShot = process(
            8,
            "bun",
            argv: [
                "bun", "--loader", ".js:jsx",
                "/home/user/node_modules/.bin/letta", "--prompt", "hello",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([oneShot, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([oneShot]) == 8)
        #expect(
            Diagnoser.cpuSamplePid([oneShot, interactive], foregroundProcessGroupId: 8) == 30
        )
        let notLetta = process(
            40,
            "bun",
            argv: [
                "bun", "--loader", "/tmp/foo.js",
                "/home/user/node_modules/.bin/letta",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([notLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([helper, notLetta]) == 10)
        #expect(Diagnoser.cpuSamplePid([notLetta]) == 40)

        // Node still consumes the module specifier. The script follows it.
        let nodeValue = process(
            4, "node", argv: ["node", "--loader", "codex", "server.js"]
        )
        let nodeScript = process(
            20,
            "node",
            argv: ["node", "--loader", "preload.js", "/usr/local/bin/codex"]
        )
        let nodeEquals = process(
            20, "nodejs", argv: ["nodejs", "--loader=preload.js", "/tmp/codex"]
        )
        let nodeExe = process(
            20, "node.exe", argv: ["node.exe", "--loader", "preload.js", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([nodeValue, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, nodeScript]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, nodeEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, nodeExe]) == 20)
        #expect(Diagnoser.cpuSamplePid([mcp, nodeScript]) == 10)
        #expect(
            Diagnoser.cpuSamplePid(
                [mcp, nodeScript], foregroundProcessGroupId: 20
            ) == 20
        )
        let nodeLetta = process(
            30,
            "node",
            argv: ["node", "--loader", "preload.js", "/home/user/node_modules/.bin/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, nodeLetta]) == 30)

        // Deno still consumes the shared flag. The value is not the script.
        let denoValue = process(
            4, "deno", argv: ["deno", "run", "--loader", "codex", "server.js"]
        )
        let denoScript = process(
            20,
            "deno",
            argv: ["deno", "run", "--loader", "preload.js", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([denoValue, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, denoScript]) == 20)
    }

    @Test("a bun inspect address is not the agent script")
    func bunInspectAddressIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // A path stays the script, including when the inspector pauses
        // on it. The port glued to the flag stays in that word.
        let path = process(20, "bun", argv: ["bun", "--inspect", "./codex"])
        let waitPath = process(20, "bun", argv: ["bun", "--inspect-wait", "/tmp/codex"])
        let brkPath = process(
            20, "bun", argv: ["bun", "--inspect-brk", "/usr/local/bin/codex"]
        )
        let equals = process(
            20, "bun", argv: ["bun", "--inspect=9229", "/tmp/codex"]
        )
        let equalsHost = process(
            20, "bun", argv: ["bun", "--inspect=0.0.0.0:9229", "/usr/local/bin/codex"]
        )
        let brkEquals = process(
            20, "bun.exe", argv: ["bun.exe", "--inspect-brk=9229", "/tmp/codex"]
        )
        let watched = process(
            20, "bun", argv: ["bun", "--inspect", "--watch", "/tmp/codex"]
        )
        let runPath = process(
            20, "bun", argv: ["bun", "run", "--inspect", "/usr/local/bin/codex"]
        )
        let windows = process(
            20, "bun.exe", argv: ["bun.exe", "--inspect", "C:\\Users\\codex.js"]
        )
        let scriptFirst = process(
            20, "bun", argv: ["bun", "/usr/local/bin/codex", "--inspect", "9229"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, path]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, waitPath]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, brkPath]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, equals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, equalsHost]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, brkEquals]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, watched]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, runPath]) == 20)
        #expect(Diagnoser.cpuSamplePid([windows, claude]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, scriptFirst]) == 20)
        #expect(Diagnoser.cpuSamplePid([mcp, brkPath]) == 10)
        #expect(
            Diagnoser.cpuSamplePid([mcp, brkPath], foregroundProcessGroupId: 20) == 20
        )

        // The address is the missing script. The agent path after it,
        // including one whose own basename is an agent, is not the program.
        let port = process(
            4, "bun", argv: ["bun", "--inspect", "9229", "/usr/local/bin/codex"]
        )
        let brkPort = process(
            4, "bun", argv: ["bun", "--inspect-brk", "9333", "/tmp/codex"]
        )
        let host = process(
            4,
            "bun",
            argv: ["bun", "--inspect-wait", "127.0.0.1:9229", "/tmp/codex"]
        )
        let prefix = process(
            4,
            "bun",
            argv: ["bun", "--inspect", "localhost:6499/prefix", "/tmp/codex"]
        )
        let namedPrefix = process(
            20,
            "bun",
            argv: ["bun", "--inspect", "localhost:6499/codex", "/tmp/server.js"]
        )
        let v6 = process(
            4, "bun", argv: ["bun", "--inspect-wait", "[::1]:9229", "/tmp/codex"]
        )
        let v6Named = process(
            20,
            "bun",
            argv: ["bun", "--inspect-brk", "[::1]:9229/codex", "/tmp/server.js"]
        )
        let hostNamed = process(
            20, "bun", argv: ["bun", "--inspect", "codex:9229", "/usr/local/bin/codex"]
        )
        let runPort = process(
            4,
            "bun",
            argv: ["bun", "run", "--inspect", "9229", "/usr/local/bin/codex"]
        )
        let packagePort = process(
            4, "bun", argv: ["bun", "x", "--inspect", "9229", "/tmp/codex"]
        )
        let watchAfter = process(
            4,
            "bun",
            argv: ["bun", "--inspect", "9229", "--watch", "/usr/local/bin/codex"]
        )
        let bunExe = process(
            4, "bun.exe", argv: ["bun.exe", "--inspect-brk", "9229", "/tmp/codex"]
        )
        let missing = process(4, "bun", argv: ["bun", "--inspect"])
        #expect(Diagnoser.cpuSamplePid([port, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([brkPort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([host, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([prefix, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([namedPrefix, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([v6, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([v6Named, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([hostNamed, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([runPort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([packagePort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([watchAfter, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([bunExe, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([missing, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([mcp, port]) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, namedPrefix]) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, v6Named]) == 10)
        #expect(
            Diagnoser.cpuSamplePid([mcp, port], foregroundProcessGroupId: 4) == 10
        )
        #expect(
            Diagnoser.cpuSamplePid(
                [mcp, namedPrefix], foregroundProcessGroupId: 20
            ) == 10
        )

        // The path after a real flag is Letta. An address in front of
        // that path is not, including when the address's own basename is.
        let letta = process(
            30,
            "bun",
            argv: ["bun", "--inspect", "/home/user/node_modules/.bin/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, letta]) == 30)
        let oneShot = process(
            8,
            "bun",
            argv: [
                "bun", "--inspect-wait", "127.0.0.1:9229",
                "/home/user/node_modules/.bin/letta", "--prompt", "hello",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([oneShot, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([oneShot]) == 8)
        #expect(
            Diagnoser.cpuSamplePid([oneShot, interactive], foregroundProcessGroupId: 8) == 30
        )
        #expect(Diagnoser.cpuSamplePid([helper, oneShot]) == 10)
        let addressLetta = process(
            40,
            "bun",
            argv: ["bun", "--inspect-brk", "[::1]:9229/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([addressLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([helper, addressLetta]) == 10)
        #expect(Diagnoser.cpuSamplePid([addressLetta]) == 40)

        // Node and Deno still do not consume a separate address.
        let nodePort = process(
            4, "node", argv: ["node", "--inspect", "9229", "/tmp/codex"]
        )
        let nodePath = process(20, "node", argv: ["node", "--inspect", "./codex"])
        let denoPort = process(
            4, "deno", argv: ["deno", "run", "--inspect", "127.0.0.1:9229", "/tmp/codex"]
        )
        let denoPath = process(20, "deno", argv: ["deno", "run", "--inspect", "./codex"])
        #expect(Diagnoser.cpuSamplePid([nodePort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, nodePath]) == 20)
        #expect(Diagnoser.cpuSamplePid([denoPort, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, denoPath]) == 20)
    }

    @Test("a flag Python rejects is not the agent script")
    func pythonRejectedFlagIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Python 3.13 exits. The path after the flag is not the script,
        // and this python is not the group leader.
        let require = process(
            4,
            "python3",
            argv: ["python3", "--require", "preload.js", "/usr/local/bin/codex"]
        )
        let requireEquals = process(
            4, "python3.11", argv: ["python3.11", "--require=preload.js", "/tmp/codex"]
        )
        let requireOnly = process(
            4, "python3", argv: ["python3", "--require", "/usr/local/bin/codex"]
        )
        let loaderValue = process(
            4,
            "python3",
            argv: ["python3", "--loader", "/usr/local/bin/codex", "server.js"]
        )
        let importFlag = process(
            4, "Python.exe", argv: ["Python.exe", "--import", "mod", "/tmp/codex"]
        )
        let cwd = process(
            4, "python3", argv: ["python3", "--cwd", "/tmp", "/usr/local/bin/codex"]
        )
        let cwdEquals = process(
            4, "python3", argv: ["python3", "--cwd=/tmp", "/tmp/codex"]
        )
        let envFile = process(
            4, "python3", argv: ["python3", "--env-file", ".env", "/tmp/codex"]
        )
        let filter = process(
            4, "python3", argv: ["python3", "--filter", "pkg", "/usr/local/bin/codex"]
        )
        let preload = process(
            4, "python3", argv: ["python3", "--preload", "pre.js", "/tmp/codex"]
        )
        let tsconfig = process(
            4,
            "python3",
            argv: ["python3", "--tsconfig-override=tsconfig.json", "/usr/local/bin/codex"]
        )
        let experimental = process(
            4,
            "python3",
            argv: ["python3", "--experimental-loader", "mod.js", "/tmp/codex"]
        )
        let unknown = process(
            4, "python3", argv: ["python3", "--not-a-flag", "/usr/local/bin/codex"]
        )
        let help = process(
            4, "python3", argv: ["python3", "--help", "/usr/local/bin/codex"]
        )
        let version = process(
            4, "python3", argv: ["python3", "--version", "/tmp/codex"]
        )
        let helpEquals = process(
            4, "python3", argv: ["python3", "--help=1", "/tmp/codex"]
        )
        let shortR = process(
            4, "python3", argv: ["python3", "-r", "preload.js", "/usr/local/bin/codex"]
        )
        let gluedR = process(
            4, "python3", argv: ["python3", "-rpreload.js", "/tmp/codex"]
        )
        let shortL = process(
            4, "Python.exe", argv: ["Python.exe", "-L", "dir", "/usr/local/bin/codex"]
        )
        let gluedL = process(
            4, "python3", argv: ["python3", "-Ldir", "/tmp/codex"]
        )
        let shortO = process(
            4, "python3", argv: ["python3", "-o", "out", "/tmp/codex"]
        )
        let gluedO = process(
            4, "python3.11", argv: ["python3.11", "-ofile", "/usr/local/bin/codex"]
        )
        let shortF = process(
            4, "python3", argv: ["python3", "-F", "pkg", "/tmp/codex"]
        )
        let gluedF = process(
            4, "python3", argv: ["python3", "-Fpkg", "/usr/local/bin/codex"]
        )
        let shortH = process(
            4, "python3", argv: ["python3", "-h", "/usr/local/bin/codex"]
        )
        let gluedH = process(
            4, "python3", argv: ["python3", "-help", "/tmp/codex"]
        )
        let shortV = process(
            4, "python3", argv: ["python3", "-V", "/usr/local/bin/codex"]
        )
        let gluedV = process(
            4, "python3", argv: ["python3", "-VV", "/tmp/codex"]
        )
        let question = process(
            4, "python3", argv: ["python3", "-?", "/usr/local/bin/codex"]
        )
        let bare = process(4, "python3", argv: ["python3", "--require"])
        let afterSite = process(
            4,
            "python3",
            argv: ["python3", "-S", "--require", "pre.js", "/usr/local/bin/codex"]
        )
        let rejected = [
            require, requireEquals, requireOnly, loaderValue, importFlag, cwd, cwdEquals,
            envFile, filter, preload, tsconfig, experimental, unknown, help, version,
            helpEquals, shortR, gluedR, shortL, gluedL, shortO, gluedO, shortF, gluedF,
            shortH, gluedH, shortV, gluedV, question, bare, afterSite,
        ]
        for exited in rejected {
            #expect(Diagnoser.cpuSamplePid([exited, claude]) == 12)
        }
        #expect(Diagnoser.cpuSamplePid([mcp, require], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([require]) == 4)

        // A script written first still runs, and so do Python's own options.
        // `--` ends the option list. `-O` is optimize, not the rejected `-o`.
        let scriptFirst = process(
            20,
            "python3",
            argv: ["python3", "/usr/local/bin/codex", "--require", "pre.js"]
        )
        let endOptions = process(
            20, "python3", argv: ["python3", "--", "/usr/local/bin/codex"]
        )
        let warning = process(
            20, "python3", argv: ["python3", "-W", "ignore", "/tmp/codex"]
        )
        let gluedWarning = process(
            20, "python3", argv: ["python3", "-Wignore", "/usr/local/bin/codex"]
        )
        let option = process(
            20, "Python.exe", argv: ["Python.exe", "-X", "dev", "/tmp/codex"]
        )
        let gluedOption = process(
            20, "python3", argv: ["python3", "-Xdev", "/usr/local/bin/codex"]
        )
        let site = process(
            20, "python3", argv: ["python3", "-S", "/usr/local/bin/codex"]
        )
        let optimize = process(
            20, "python3", argv: ["python3", "-O", "/usr/local/bin/codex"]
        )
        let optimizeTwice = process(
            20, "python3.11", argv: ["python3.11", "-OO", "/tmp/codex"]
        )
        let skipLine = process(
            20, "python3", argv: ["python3", "-x", "/usr/local/bin/codex"]
        )
        let hashMode = process(
            20,
            "python3",
            argv: ["python3", "--check-hash-based-pycs", "always", "/tmp/codex"]
        )
        let kept = [
            scriptFirst, endOptions, warning, gluedWarning, option, gluedOption, site,
            optimize, optimizeTwice, skipLine, hashMode,
        ]
        for running in kept {
            #expect(Diagnoser.cpuSamplePid([helper, running]) == 20)
        }
        #expect(
            Diagnoser.cpuSamplePid([mcp, scriptFirst], foregroundProcessGroupId: 20) == 20
        )

        // Bun and Node still run the script after the flags they accept.
        // Node still exits on `--cwd` and on a glued `-r`. Deno still
        // consumes `--require`.
        let bunRequire = process(
            20, "bun", argv: ["bun", "--require", "preload.js", "/usr/local/bin/codex"]
        )
        let bunCwd = process(
            20, "bun.exe", argv: ["bun.exe", "--cwd", "/tmp", "/usr/local/bin/codex"]
        )
        let bunImport = process(
            20, "bun", argv: ["bun", "--import", "mod.js", "/tmp/codex"]
        )
        let nodeRequire = process(
            20, "node", argv: ["node", "--require", "preload.js", "/usr/local/bin/codex"]
        )
        let nodeImport = process(
            20, "nodejs", argv: ["nodejs", "--import", "mod.js", "/tmp/codex"]
        )
        let nodeEnv = process(
            20, "node", argv: ["node", "--env-file", ".env", "/usr/local/bin/codex"]
        )
        let nodeCwd = process(
            4, "node", argv: ["node", "--cwd", "/tmp", "/usr/local/bin/codex"]
        )
        let nodeGlued = process(
            4, "node", argv: ["node", "-rpreload.js", "/usr/local/bin/codex"]
        )
        let denoRequire = process(
            20, "deno", argv: ["deno", "run", "--require", "preload.js", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, bunRequire]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bunCwd]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bunImport]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, nodeRequire]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, nodeImport]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, nodeEnv]) == 20)
        #expect(Diagnoser.cpuSamplePid([nodeCwd, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([nodeGlued, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, denoRequire]) == 20)
        #expect(
            Diagnoser.cpuSamplePid([mcp, bunRequire], foregroundProcessGroupId: 20) == 20
        )

        // A rejected flag in front of a Letta path is not the TUI.
        // `-W` in front of that path still is not: Python is not Letta's runtime.
        let falseLetta = process(
            8,
            "python3",
            argv: [
                "python3", "--require", "pre.js",
                "/home/user/node_modules/.bin/letta",
            ]
        )
        let helpLetta = process(
            8,
            "python3",
            argv: ["python3", "--help", "/home/user/node_modules/.bin/letta"]
        )
        let warningLetta = process(
            40, "python3", argv: ["python3", "-W", "ignore", "/tmp/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([falseLetta, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([falseLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([falseLetta]) == 8)
        #expect(Diagnoser.cpuSamplePid([mcp, falseLetta], foregroundProcessGroupId: 8) == 10)
        #expect(Diagnoser.cpuSamplePid([helpLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([helper, warningLetta]) == 10)
        #expect(Diagnoser.cpuSamplePid([warningLetta, interactive]) == 30)
    }

    @Test("an unknown Python short is not the agent script")
    func pythonUnknownShortIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Python 3.13 exits. The path is not the script, and this python
        // is not the group leader. A lone `-` is stdin. `-c` and `-m`
        // inside a cluster end the options, so the file is not the program.
        let unknown = process(
            4, "python3", argv: ["python3", "-z", "/usr/local/bin/codex"]
        )
        let letter = process(
            4, "python3.11", argv: ["python3.11", "-a", "/tmp/codex"]
        )
        let reserved = process(
            4, "Python.exe", argv: ["Python.exe", "-J", "/usr/local/bin/codex"]
        )
        let digit = process(
            4, "python3", argv: ["python3", "-1", "/tmp/codex"]
        )
        let colon = process(
            4, "python3", argv: ["python3", "-:", "/usr/local/bin/codex"]
        )
        let cluster = process(
            4, "python3", argv: ["python3", "-qz", "/usr/local/bin/codex"]
        )
        let clusterLetter = process(
            4, "python3", argv: ["python3", "-bZ", "/tmp/codex"]
        )
        let helpCluster = process(
            4, "python3", argv: ["python3", "-qh", "/usr/local/bin/codex"]
        )
        let versionCluster = process(
            4, "Python.exe", argv: ["Python.exe", "-qV", "/tmp/codex"]
        )
        let questionCluster = process(
            4, "python3", argv: ["python3", "-q?", "/usr/local/bin/codex"]
        )
        let stdin = process(
            4, "python3", argv: ["python3", "-", "/usr/local/bin/codex"]
        )
        let quietStdin = process(
            4, "python3", argv: ["python3", "-q", "-", "/tmp/codex"]
        )
        let command = process(
            4, "python3", argv: ["python3", "-qc", "/usr/local/bin/codex"]
        )
        let module = process(
            4,
            "python3.11",
            argv: ["python3.11", "-qm", "json", "/usr/local/bin/codex"]
        )
        let unknownEval = process(
            4, "python3", argv: ["python3", "-qe", "/tmp/codex"]
        )
        let missingWarning = process(
            4, "python3", argv: ["python3", "-W"]
        )
        let rejected = [
            unknown, letter, reserved, digit, colon, cluster, clusterLetter,
            helpCluster, versionCluster, questionCluster, stdin, quietStdin,
            command, module, unknownEval, missingWarning,
        ]
        for exited in rejected {
            #expect(Diagnoser.cpuSamplePid([exited, claude]) == 12)
        }
        #expect(Diagnoser.cpuSamplePid([mcp, unknown], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, stdin], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, command], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([unknown]) == 4)

        // A real cluster still names the file, including `-R` and `-t`,
        // which the runtime accepts and the help text does not list.
        // `-qW` takes `ignore` and the path after it is the script.
        let quietSite = process(
            20, "python3", argv: ["python3", "-qS", "/usr/local/bin/codex"]
        )
        let bytes = process(
            20, "python3", argv: ["python3", "-bb", "/tmp/codex"]
        )
        let optimize = process(
            20, "python3.11", argv: ["python3.11", "-OOO", "/usr/local/bin/codex"]
        )
        let unbuffered = process(
            20, "python3", argv: ["python3", "-vu", "/tmp/codex"]
        )
        let hashSeed = process(
            20, "Python.exe", argv: ["Python.exe", "-R", "/usr/local/bin/codex"]
        )
        let tabs = process(
            20, "python3", argv: ["python3", "-t", "/tmp/codex"]
        )
        let tabsTwice = process(
            20, "python3", argv: ["python3", "-tt", "/usr/local/bin/codex"]
        )
        let inspect = process(
            20, "python3", argv: ["python3", "-qi", "/tmp/codex"]
        )
        let skipLine = process(
            20, "python3", argv: ["python3", "-x", "/usr/local/bin/codex"]
        )
        let gluedWarning = process(
            20, "python3", argv: ["python3", "-bWignore", "/tmp/codex"]
        )
        let clusteredWarning = process(
            20,
            "python3",
            argv: ["python3", "-qW", "ignore", "/usr/local/bin/codex"]
        )
        let clusteredOption = process(
            20, "Python.exe", argv: ["Python.exe", "-qX", "dev", "/tmp/codex"]
        )
        let warningDash = process(
            20, "python3", argv: ["python3", "-W", "--", "/usr/local/bin/codex"]
        )
        let endOptions = process(
            20, "python3", argv: ["python3", "-q", "--", "/tmp/codex"]
        )
        let scriptFirst = process(
            20, "python3", argv: ["python3", "/usr/local/bin/codex", "-z"]
        )
        let kept = [
            quietSite, bytes, optimize, unbuffered, hashSeed, tabs, tabsTwice,
            inspect, skipLine, gluedWarning, clusteredWarning, clusteredOption,
            warningDash, endOptions, scriptFirst,
        ]
        for running in kept {
            #expect(Diagnoser.cpuSamplePid([helper, running]) == 20)
        }
        #expect(
            Diagnoser.cpuSamplePid([mcp, quietSite], foregroundProcessGroupId: 20) == 20
        )
        #expect(
            Diagnoser.cpuSamplePid(
                [mcp, clusteredWarning], foregroundProcessGroupId: 20
            ) == 20
        )

        // An unknown short in front of a Letta path is not the TUI.
        // A real cluster in front of one is the same noninteractive
        // entry as `-W ignore`, so the helper's lower pid still wins.
        let falseLetta = process(
            8,
            "python3",
            argv: ["python3", "-z", "/home/user/node_modules/.bin/letta"]
        )
        let stdinLetta = process(
            8,
            "python3",
            argv: ["python3", "-", "/home/user/node_modules/.bin/letta"]
        )
        let commandLetta = process(
            8,
            "python3",
            argv: ["python3", "-qc", "/home/user/node_modules/.bin/letta"]
        )
        let clusteredLetta = process(
            40,
            "python3",
            argv: ["python3", "-qW", "ignore", "/tmp/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([falseLetta, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([falseLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([falseLetta]) == 8)
        #expect(
            Diagnoser.cpuSamplePid([mcp, falseLetta], foregroundProcessGroupId: 8) == 10
        )
        #expect(Diagnoser.cpuSamplePid([stdinLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([commandLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([helper, clusteredLetta]) == 10)
        #expect(Diagnoser.cpuSamplePid([clusteredLetta, interactive]) == 30)
    }

    @Test("an unknown node or bun short is not the agent script")
    func nodeAndBunUnknownShortIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Node 22.23 does not cluster and does not run the file. `-i` is
        // the one short boolean that still does. A lone `-` is stdin.
        let nodeUnknown = process(
            4, "node", argv: ["node", "-z", "/usr/local/bin/codex"]
        )
        let nodeQuiet = process(
            4, "nodejs", argv: ["nodejs", "-q", "/tmp/codex"]
        )
        let nodeLetter = process(
            4, "node.exe", argv: ["node.exe", "-a", "/usr/local/bin/codex"]
        )
        let nodeCluster = process(
            4, "node", argv: ["node", "-qh", "/tmp/codex"]
        )
        let nodeRepeated = process(
            4, "node", argv: ["node", "-ii", "/usr/local/bin/codex"]
        )
        let nodeHelp = process(
            4, "node", argv: ["node", "-h", "/usr/local/bin/codex"]
        )
        let nodeVersion = process(
            4, "Node.EXE", argv: ["Node.EXE", "-v", "/tmp/codex"]
        )
        let nodeStdin = process(
            4, "node", argv: ["node", "-", "/usr/local/bin/codex"]
        )
        let nodeInteractiveStdin = process(
            4, "node", argv: ["node", "-i", "-", "/tmp/codex"]
        )
        let nodeRejected = [
            nodeUnknown, nodeQuiet, nodeLetter, nodeCluster, nodeRepeated,
            nodeHelp, nodeVersion, nodeStdin, nodeInteractiveStdin,
        ]
        for exited in nodeRejected {
            #expect(Diagnoser.cpuSamplePid([exited, claude]) == 12)
        }
        #expect(Diagnoser.cpuSamplePid([mcp, nodeUnknown], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, nodeHelp], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, nodeStdin], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([nodeUnknown]) == 4)

        // Bun 1.4.2 walks the cluster. An unknown letter, help, version,
        // and stdin do not run the file. `-u` with no value takes the
        // next word, so that path is not the script. A bad define or
        // loader value, and eval, are the same exit.
        let bunUnknown = process(
            4, "bun", argv: ["bun", "-z", "/usr/local/bin/codex"]
        )
        let bunQuiet = process(
            4, "bun.exe", argv: ["bun.exe", "-q", "/tmp/codex"]
        )
        let bunCluster = process(
            4, "bun", argv: ["bun", "-bz", "/usr/local/bin/codex"]
        )
        let bunInstallUnknown = process(
            4, "bun", argv: ["bun", "-iz", "/tmp/codex"]
        )
        let bunHelp = process(
            4, "bun", argv: ["bun", "-h", "/usr/local/bin/codex"]
        )
        let bunVersion = process(
            4, "bun", argv: ["bun", "-v", "/tmp/codex"]
        )
        let bunHelpAfter = process(
            4, "bun", argv: ["bun", "-hu", "/usr/local/bin/codex"]
        )
        let bunHelpWord = process(
            4, "bun", argv: ["bun", "-bi", "-h", "/tmp/codex"]
        )
        let bunStdin = process(
            4, "bun", argv: ["bun", "-", "/usr/local/bin/codex"]
        )
        let bunEquals = process(
            4, "bun", argv: ["bun", "-b=/usr/local/bin/codex"]
        )
        let bunModule = process(
            4, "bun", argv: ["bun", "-m", "/tmp/codex"]
        )
        let bunRunUnknown = process(
            4, "bun", argv: ["bun", "run", "-z", "/usr/local/bin/codex"]
        )
        let bunValueOnly = process(
            4, "bun", argv: ["bun", "-u", "/usr/local/bin/codex"]
        )
        let bunInstallValue = process(
            4, "bun", argv: ["bun", "-iu", "/tmp/codex"]
        )
        let bunDefine = process(
            4, "bun", argv: ["bun", "-id", "K", "/usr/local/bin/codex"]
        )
        let bunLoader = process(
            4, "bun", argv: ["bun", "-il", "nocolon", "/tmp/codex"]
        )
        let bunEval = process(
            4, "bun", argv: ["bun", "-ie", "console.log(1)", "/usr/local/bin/codex"]
        )
        let bunRejected = [
            bunUnknown, bunQuiet, bunCluster, bunInstallUnknown, bunHelp,
            bunVersion, bunHelpAfter, bunHelpWord, bunStdin, bunEquals,
            bunModule, bunRunUnknown, bunValueOnly, bunInstallValue,
            bunDefine, bunLoader, bunEval,
        ]
        for exited in bunRejected {
            #expect(Diagnoser.cpuSamplePid([exited, claude]) == 12)
        }
        #expect(Diagnoser.cpuSamplePid([mcp, bunUnknown], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, bunHelp], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, bunValueOnly], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([bunUnknown]) == 4)

        // The shorts that still run the file name it, including when
        // that process is the group leader. A value's word is not the
        // script. `--cpu-prof` before the name flag still counts when
        // the preload is a cluster.
        let nodeInteractive = process(
            20, "node", argv: ["node", "-i", "/usr/local/bin/codex"]
        )
        let nodejsInteractive = process(
            20, "nodejs", argv: ["nodejs", "-i", "/tmp/codex"]
        )
        let nodeExeInteractive = process(
            20, "node.exe", argv: ["node.exe", "-i", "-i", "/usr/local/bin/codex"]
        )
        let nodeLong = process(
            20, "node", argv: ["node", "--interactive", "/tmp/codex"]
        )
        let nodeScriptFirst = process(
            20, "node", argv: ["node", "/usr/local/bin/codex", "-z"]
        )
        let bunInstall = process(
            20, "bun", argv: ["bun", "-i", "/usr/local/bin/codex"]
        )
        let bunForce = process(
            20, "bun", argv: ["bun", "-b", "/tmp/codex"]
        )
        let bunBoth = process(
            20, "bun.exe", argv: ["bun.exe", "-bi", "/usr/local/bin/codex"]
        )
        let bunRepeated = process(
            20, "bun", argv: ["bun", "-ii", "/tmp/codex"]
        )
        let bunRun = process(
            20, "bun", argv: ["bun", "run", "-i", "/usr/local/bin/codex"]
        )
        let bunConfig = process(
            20, "bun", argv: ["bun", "-ic", "/tmp/codex"]
        )
        let bunConfigOther = process(
            20, "bun", argv: ["bun", "-bc", "/usr/local/bin/codex"]
        )
        let bunGluedValue = process(
            20, "bun", argv: ["bun", "-uz", "/tmp/codex"]
        )
        let bunSeparateValue = process(
            20, "bun", argv: ["bun", "-u", "foo", "/usr/local/bin/codex"]
        )
        let bunValueHelp = process(
            20, "bun", argv: ["bun", "-uh", "/tmp/codex"]
        )
        let bunPreload = process(
            20,
            "bun",
            argv: ["bun", "-ir", "preload.js", "/usr/local/bin/codex"]
        )
        let bunDefineOk = process(
            20, "bun", argv: ["bun", "-id", "K:1", "/tmp/codex"]
        )
        let bunLoaderOk = process(
            20, "bun", argv: ["bun", "-il", ".js:jsx", "/usr/local/bin/codex"]
        )
        let bunSubcommand = process(
            20, "bun", argv: ["bun", "-i", "run", "/tmp/codex"]
        )
        let bunLong = process(
            20, "bun", argv: ["bun", "--bun", "/usr/local/bin/codex"]
        )
        let bunUnknownLong = process(
            20, "bun", argv: ["bun", "--not-a-flag", "/tmp/codex"]
        )
        let bunProfile = process(
            20,
            "bun",
            argv: [
                "bun", "-ir", "preload.js", "--cpu-prof",
                "--cpu-prof-name", "out.js", "/usr/local/bin/codex",
            ]
        )
        let bunScriptFirst = process(
            20, "bun", argv: ["bun", "/usr/local/bin/codex", "-z"]
        )
        let kept = [
            nodeInteractive, nodejsInteractive, nodeExeInteractive, nodeLong,
            nodeScriptFirst, bunInstall, bunForce, bunBoth, bunRepeated,
            bunRun, bunConfig, bunConfigOther, bunGluedValue, bunSeparateValue,
            bunValueHelp, bunPreload, bunDefineOk, bunLoaderOk, bunSubcommand,
            bunLong, bunUnknownLong, bunProfile, bunScriptFirst,
        ]
        for running in kept {
            #expect(Diagnoser.cpuSamplePid([helper, running]) == 20)
        }
        #expect(
            Diagnoser.cpuSamplePid([mcp, nodeInteractive], foregroundProcessGroupId: 20) == 20
        )
        #expect(
            Diagnoser.cpuSamplePid([mcp, bunBoth], foregroundProcessGroupId: 20) == 20
        )
        #expect(
            Diagnoser.cpuSamplePid([mcp, bunPreload], foregroundProcessGroupId: 20) == 20
        )
        #expect(
            Diagnoser.cpuSamplePid([mcp, bunProfile], foregroundProcessGroupId: 20) == 20
        )
        let bunProfileMissing = process(
            4,
            "bun",
            argv: [
                "bun", "-ir", "preload.js", "--cpu-prof-name", "out.js",
                "/usr/local/bin/codex",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([bunProfileMissing, claude]) == 12)

        // An unknown short in front of a Letta path is not the TUI.
        // `-i` and `-b` in front of one still are. `--prompt` after the
        // path is a one-shot, so the helper's lower pid still wins.
        let nodeFalseLetta = process(
            8,
            "node",
            argv: ["node", "-z", "/home/user/node_modules/.bin/letta"]
        )
        let nodeHelpLetta = process(
            8,
            "node",
            argv: ["node", "-h", "/home/user/node_modules/.bin/letta"]
        )
        let bunFalseLetta = process(
            8,
            "bun",
            argv: ["bun", "-z", "/home/user/node_modules/.bin/letta"]
        )
        let nodeLetta = process(
            40,
            "node",
            argv: ["node", "-i", "/home/user/node_modules/.bin/letta"]
        )
        let bunLetta = process(
            40,
            "bun",
            argv: ["bun", "-b", "/tmp/letta"]
        )
        let bunOneShot = process(
            40,
            "bun",
            argv: ["bun", "-b", "/tmp/letta", "--prompt"]
        )
        #expect(Diagnoser.cpuSamplePid([nodeFalseLetta, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([nodeFalseLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([nodeFalseLetta]) == 8)
        #expect(
            Diagnoser.cpuSamplePid([mcp, nodeFalseLetta], foregroundProcessGroupId: 8) == 10
        )
        #expect(Diagnoser.cpuSamplePid([nodeHelpLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([bunFalseLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([helper, nodeLetta]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, bunLetta]) == 40)
        #expect(Diagnoser.cpuSamplePid([nodeLetta, interactive]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, bunOneShot]) == 10)
        #expect(Diagnoser.cpuSamplePid([bunOneShot, interactive]) == 30)

        // Deno was not installed. An unknown short is still skipped.
        // `node --not-a-flag` exits and does not name the path.
        let denoUnknown = process(
            20, "deno", argv: ["deno", "run", "-z", "/usr/local/bin/codex"]
        )
        let nodeBadLong = process(
            20, "node", argv: ["node", "--not-a-flag", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, denoUnknown]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, nodeBadLong]) == 10)
    }

    @Test("node and bun help and version are not the agent script")
    func nodeAndBunHelpAreNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Node 22.23 and Bun 1.4.2 print and exit. The path is not the
        // file, including an attached `=` and a boolean in front.
        // Bun's `--revision` is the same print.
        let nodeHelp = process(
            4, "node", argv: ["node", "--help", "/usr/local/bin/codex"]
        )
        let nodeVersion = process(
            4, "nodejs", argv: ["nodejs", "--version", "/tmp/codex"]
        )
        let nodeHelpEquals = process(
            4, "node.exe", argv: ["node.exe", "--help=1", "/usr/local/bin/codex"]
        )
        let nodeVersionEquals = process(
            4, "Node.EXE", argv: ["Node.EXE", "--version=", "/tmp/codex"]
        )
        let nodeStrictHelp = process(
            4, "node", argv: ["node", "--use-strict", "--help", "/usr/local/bin/codex"]
        )
        let nodeWarningsVersion = process(
            4, "node", argv: ["node", "--no-warnings", "--version", "/tmp/codex"]
        )
        let bunHelp = process(
            4, "bun", argv: ["bun", "--help", "/usr/local/bin/codex"]
        )
        let bunVersion = process(
            4, "bun.exe", argv: ["bun.exe", "--version", "/tmp/codex"]
        )
        let bunRevision = process(
            4, "bun", argv: ["bun", "--revision", "/usr/local/bin/codex"]
        )
        let bunHelpEquals = process(
            4, "bun", argv: ["bun", "--help=1", "/tmp/codex"]
        )
        let bunVersionEquals = process(
            4, "bun", argv: ["bun", "--version=", "/usr/local/bin/codex"]
        )
        let bunRevisionEquals = process(
            4, "bun", argv: ["bun", "--revision=1", "/tmp/codex"]
        )
        let bunBunHelp = process(
            4, "bun", argv: ["bun", "--bun", "--help", "/usr/local/bin/codex"]
        )
        let bunHotVersion = process(
            4, "bun", argv: ["bun", "--hot", "--version", "/tmp/codex"]
        )
        let bunRunHelp = process(
            4, "bun", argv: ["bun", "run", "--help", "/usr/local/bin/codex"]
        )
        let bunRunHelpEquals = process(
            4, "bun.exe", argv: ["bun.exe", "run", "--help=1", "/tmp/codex"]
        )
        let bunHelpBeforeRun = process(
            4, "bun", argv: ["bun", "--help", "run", "/usr/local/bin/codex"]
        )
        let bunHelpEqualsBeforeRun = process(
            4, "bun", argv: ["bun", "--help=1", "run", "/tmp/codex"]
        )
        let exited = [
            nodeHelp, nodeVersion, nodeHelpEquals, nodeVersionEquals,
            nodeStrictHelp, nodeWarningsVersion, bunHelp, bunVersion,
            bunRevision, bunHelpEquals, bunVersionEquals, bunRevisionEquals,
            bunBunHelp, bunHotVersion, bunRunHelp, bunRunHelpEquals,
            bunHelpBeforeRun, bunHelpEqualsBeforeRun,
        ]
        for sample in exited {
            #expect(Diagnoser.cpuSamplePid([sample, claude]) == 12)
        }
        #expect(Diagnoser.cpuSamplePid([mcp, nodeHelp], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, bunVersion], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, bunRunHelp], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([nodeHelp]) == 4)
        #expect(Diagnoser.cpuSamplePid([bunRevision]) == 4)

        // Flags that still run the file name it, including when that
        // process is the group leader. Version before `run` still runs
        // the file, and so does help or version around `x`. A version
        // word that is `--title`'s value is not the print, and `run`
        // in that slot is not the subcommand.
        let nodeScriptFirst = process(
            20, "node", argv: ["node", "/usr/local/bin/codex", "--help"]
        )
        let nodeEndOptions = process(
            20, "node", argv: ["node", "--", "/usr/local/bin/codex"]
        )
        let nodeInteractive = process(
            20, "node", argv: ["node", "--interactive", "/tmp/codex"]
        )
        let nodeWatch = process(
            20, "nodejs", argv: ["nodejs", "--watch", "/usr/local/bin/codex"]
        )
        let nodeStrict = process(
            20, "node.exe", argv: ["node.exe", "--use-strict", "/tmp/codex"]
        )
        let nodeTitleEquals = process(
            20, "node", argv: ["node", "--title=--version", "/usr/local/bin/codex"]
        )
        let bunUnknown = process(
            20, "bun", argv: ["bun", "--not-a-flag", "/tmp/codex"]
        )
        let bunBun = process(
            20, "bun", argv: ["bun", "--bun", "/usr/local/bin/codex"]
        )
        let bunHot = process(
            20, "bun", argv: ["bun", "--hot", "/tmp/codex"]
        )
        let bunWatch = process(
            20, "bun.exe", argv: ["bun.exe", "--watch", "/usr/local/bin/codex"]
        )
        let bunSmol = process(
            20, "bun", argv: ["bun", "--smol", "/tmp/codex"]
        )
        let bunRunVersion = process(
            20, "bun", argv: ["bun", "run", "--version", "/usr/local/bin/codex"]
        )
        let bunRunVersionEquals = process(
            20, "bun", argv: ["bun", "run", "--version=1", "/tmp/codex"]
        )
        let bunVersionBeforeRun = process(
            20, "bun", argv: ["bun", "--version", "run", "/usr/local/bin/codex"]
        )
        let bunRevisionBeforeRun = process(
            20, "bun.exe", argv: ["bun.exe", "--revision", "run", "/tmp/codex"]
        )
        let bunVersionEqualsBeforeRun = process(
            20, "bun", argv: ["bun", "--version=1", "run", "/usr/local/bin/codex"]
        )
        let bunRevisionEqualsBeforeRun = process(
            20, "bun", argv: ["bun", "--revision=1", "run", "/tmp/codex"]
        )
        let bunRunRevision = process(
            20, "bun.exe", argv: ["bun.exe", "run", "--revision", "/usr/local/bin/codex"]
        )
        let bunRunRevisionEquals = process(
            20, "bun", argv: ["bun", "run", "--revision=1", "/tmp/codex"]
        )
        let bunExecVersion = process(
            20, "bun", argv: ["bun", "x", "--version", "/usr/local/bin/codex"]
        )
        let bunExecHelp = process(
            20, "bun", argv: ["bun", "x", "--help", "/tmp/codex"]
        )
        let bunHelpBeforeExec = process(
            20, "bun", argv: ["bun", "--help", "x", "/usr/local/bin/codex"]
        )
        let bunVersionBeforeExec = process(
            20, "bun", argv: ["bun", "--version", "x", "/tmp/codex"]
        )
        let bunTitleRun = process(
            20, "bun", argv: ["bun", "--title", "run", "/usr/local/bin/codex"]
        )
        let bunTitleVersion = process(
            20, "bun", argv: ["bun", "--title", "--version", "/usr/local/bin/codex"]
        )
        let bunTitleHelp = process(
            20, "bun", argv: ["bun", "--title", "--help", "/tmp/codex"]
        )
        let bunTitleRevision = process(
            20, "bun", argv: ["bun", "--title", "--revision", "/usr/local/bin/codex"]
        )
        let bunUserAgent = process(
            20, "bun", argv: ["bun", "--user-agent", "--version", "/tmp/codex"]
        )
        let bunScriptFirst = process(
            20, "bun", argv: ["bun", "/usr/local/bin/codex", "--version"]
        )
        let bunRunScriptFirst = process(
            20, "bun", argv: ["bun", "run", "/usr/local/bin/codex", "--help"]
        )
        let kept = [
            nodeScriptFirst, nodeEndOptions, nodeInteractive, nodeWatch,
            nodeStrict, nodeTitleEquals, bunUnknown, bunBun, bunHot, bunWatch,
            bunSmol, bunRunVersion, bunRunVersionEquals, bunVersionBeforeRun,
            bunRevisionBeforeRun, bunVersionEqualsBeforeRun, bunRevisionEqualsBeforeRun,
            bunRunRevision, bunRunRevisionEquals, bunExecVersion, bunExecHelp,
            bunHelpBeforeExec, bunVersionBeforeExec, bunTitleRun, bunTitleVersion,
            bunTitleHelp, bunTitleRevision, bunUserAgent, bunScriptFirst,
            bunRunScriptFirst,
        ]
        for running in kept {
            #expect(Diagnoser.cpuSamplePid([helper, running]) == 20)
        }
        #expect(
            Diagnoser.cpuSamplePid([mcp, nodeWatch], foregroundProcessGroupId: 20) == 20
        )
        #expect(
            Diagnoser.cpuSamplePid([mcp, bunRunVersion], foregroundProcessGroupId: 20) == 20
        )
        #expect(
            Diagnoser.cpuSamplePid(
                [mcp, bunVersionBeforeRun], foregroundProcessGroupId: 20
            ) == 20
        )
        #expect(
            Diagnoser.cpuSamplePid([mcp, bunTitleHelp], foregroundProcessGroupId: 20) == 20
        )

        // Help in front of a Letta path is not the TUI. `--bun` in front
        // of one still is.
        let nodeFalseLetta = process(
            8,
            "node",
            argv: ["node", "--help", "/home/user/node_modules/.bin/letta"]
        )
        let bunFalseLetta = process(
            8,
            "bun",
            argv: ["bun", "--version", "/home/user/node_modules/.bin/letta"]
        )
        let bunLetta = process(
            40,
            "bun",
            argv: ["bun", "--bun", "/tmp/letta"]
        )
        #expect(Diagnoser.cpuSamplePid([nodeFalseLetta, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([nodeFalseLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([bunFalseLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([nodeFalseLetta]) == 8)
        #expect(
            Diagnoser.cpuSamplePid([mcp, nodeFalseLetta], foregroundProcessGroupId: 8) == 10
        )
        #expect(Diagnoser.cpuSamplePid([helper, bunLetta]) == 40)
        #expect(Diagnoser.cpuSamplePid([bunLetta, interactive]) == 40)

        // Deno was not installed. Its long help and version are still
        // skipped. Node's other rejected long options are the next test.
        let denoHelp = process(
            20, "deno", argv: ["deno", "run", "--help", "/usr/local/bin/codex"]
        )
        let denoVersion = process(
            20, "deno", argv: ["deno", "run", "--version", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, denoHelp]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, denoVersion]) == 20)
    }

    @Test("an unknown node long option is not the agent script")
    func nodeUnknownLongOptionIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Node 22.23 exits before the file runs. The path is not the
        // script, and that node is not the group leader. An attached
        // `=` is the same bad option.
        let nodeBad = process(
            4, "node", argv: ["node", "--not-a-flag", "/usr/local/bin/codex"]
        )
        let nodeBadEquals = process(
            4, "node.exe", argv: ["node.exe", "--not-a-flag=1", "/tmp/codex"]
        )
        let nodeRevision = process(
            4, "nodejs", argv: ["nodejs", "--revision", "/usr/local/bin/codex"]
        )
        let nodeRevisionEquals = process(
            4, "Node.EXE", argv: ["Node.EXE", "--revision=1", "/tmp/codex"]
        )
        let nodePort = process(
            4, "node", argv: ["node", "--port", "codex", "/usr/local/bin/codex"]
        )
        let nodeDefine = process(
            4, "node", argv: ["node", "--define", "KEY:1", "/tmp/codex"]
        )
        let nodeImportMap = process(
            4, "node", argv: ["node", "--import-map", "codex", "server.js"]
        )
        let nodeHarmonyEquals = process(
            4, "node", argv: ["node", "--harmony=true", "/usr/local/bin/codex"]
        )
        let nodeHeapWord = process(
            4, "node", argv: ["node", "--max-old-space-size", "4096", "/tmp/codex"]
        )
        let nodeTestEquals = process(
            4, "nodejs", argv: ["nodejs", "--test=true", "/usr/local/bin/codex"]
        )
        let nodeEmptyTrace = process(
            4, "node", argv: ["node", "--stack-trace-limit=", "/tmp/codex"]
        )
        let nodeCheck = process(
            4, "node", argv: ["node", "--check", "/usr/local/bin/codex"]
        )
        let nodeCompletion = process(
            4, "node.exe", argv: ["node.exe", "--completion-bash", "/tmp/codex"]
        )
        let nodeV8Options = process(
            4, "node", argv: ["node", "--v8-options", "/usr/local/bin/codex"]
        )
        let nodeProfProcess = process(
            4, "node", argv: ["node", "--prof-process", "/tmp/codex"]
        )
        let nodeShortWatch = process(
            4, "node", argv: ["node", "-watch", "/usr/local/bin/codex"]
        )
        let nodeShortBad = process(
            4, "nodejs", argv: ["nodejs", "-not-a-flag", "/tmp/codex"]
        )
        let nodeDoubleNo = process(
            4, "node", argv: ["node", "--no-no-warnings", "/usr/local/bin/codex"]
        )
        let exited = [
            nodeBad, nodeBadEquals, nodeRevision, nodeRevisionEquals,
            nodePort, nodeDefine, nodeImportMap, nodeHarmonyEquals,
            nodeHeapWord, nodeTestEquals, nodeEmptyTrace, nodeCheck,
            nodeCompletion, nodeV8Options, nodeProfProcess, nodeShortWatch,
            nodeShortBad, nodeDoubleNo,
        ]
        for sample in exited {
            #expect(Diagnoser.cpuSamplePid([sample, claude]) == 12)
        }
        #expect(Diagnoser.cpuSamplePid([helper, nodeBad]) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, nodeRevision], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([mcp, nodeHeapWord], foregroundProcessGroupId: 4) == 10)
        #expect(Diagnoser.cpuSamplePid([nodeBad]) == 4)

        // Flags Node 22.23 actually runs still name the file, including
        // when that node is the group leader. A V8 value stays in the
        // flag word. A script written first stays the script.
        let nodeWatch = process(
            20, "node", argv: ["node", "--watch", "/usr/local/bin/codex"]
        )
        let nodeWatchEquals = process(
            20, "nodejs", argv: ["nodejs", "--watch=", "/tmp/codex"]
        )
        let nodeStrict = process(
            20, "node.exe", argv: ["node.exe", "--use-strict", "/usr/local/bin/codex"]
        )
        let nodeHarmony = process(
            20, "node", argv: ["node", "--harmony", "/tmp/codex"]
        )
        let nodeNoHarmony = process(
            20, "node", argv: ["node", "--no-harmony", "/usr/local/bin/codex"]
        )
        let nodeShortHarmony = process(
            20, "nodejs", argv: ["nodejs", "-harmony", "/tmp/codex"]
        )
        let nodeShortStrict = process(
            20, "node.exe", argv: ["node.exe", "-use-strict", "/usr/local/bin/codex"]
        )
        let nodeHeap = process(
            20, "node", argv: ["node", "--max-old-space-size=4096", "/usr/local/bin/codex"]
        )
        let nodeHeapShort = process(
            20, "node", argv: ["node", "-max-old-space-size=4096", "/tmp/codex"]
        )
        let nodeTrace = process(
            20, "node", argv: ["node", "--stack-trace-limit=20", "/usr/local/bin/codex"]
        )
        let nodeStrip = process(
            20, "nodejs", argv: ["nodejs", "--experimental-strip-types", "/tmp/codex"]
        )
        let nodeNoHelp = process(
            20, "node", argv: ["node", "--no-help=1", "/usr/local/bin/codex"]
        )
        let nodeNoTest = process(
            20, "node", argv: ["node", "--no-test=true", "/tmp/codex"]
        )
        let nodeTest = process(
            20, "node.exe", argv: ["node.exe", "--test", "/usr/local/bin/codex"]
        )
        let nodeRun = process(
            20, "node", argv: ["node", "--run", "codex"]
        )
        let nodeTitle = process(
            20, "node", argv: ["node", "--title=--not-a-flag", "/usr/local/bin/codex"]
        )
        let nodeScriptFirst = process(
            20, "node", argv: ["node", "/usr/local/bin/codex", "--not-a-flag"]
        )
        let nodeNoAbort = process(
            20, "node", argv: ["node", "--no-abort-on-far-code-range", "/tmp/codex"]
        )
        let kept = [
            nodeWatch, nodeWatchEquals, nodeStrict, nodeHarmony, nodeNoHarmony,
            nodeShortHarmony, nodeShortStrict, nodeHeap, nodeHeapShort, nodeTrace,
            nodeStrip, nodeNoHelp, nodeNoTest, nodeTest, nodeRun, nodeTitle,
            nodeScriptFirst, nodeNoAbort,
        ]
        for running in kept {
            #expect(Diagnoser.cpuSamplePid([helper, running]) == 20)
        }
        #expect(Diagnoser.cpuSamplePid([mcp, nodeHeap], foregroundProcessGroupId: 20) == 20)
        #expect(Diagnoser.cpuSamplePid([mcp, nodeShortHarmony], foregroundProcessGroupId: 20) == 20)
        #expect(Diagnoser.cpuSamplePid([mcp, nodeRun], foregroundProcessGroupId: 20) == 20)
        #expect(Diagnoser.cpuSamplePid([nodeRun, claude]) == 20)

        // An unknown flag in front of a Letta path is not the TUI.
        // `--use-strict` and `-harmony` in front of one still are.
        let nodeFalseLetta = process(
            8,
            "node",
            argv: ["node", "--not-a-flag", "/home/user/node_modules/.bin/letta"]
        )
        let nodeRevisionLetta = process(
            8,
            "node",
            argv: ["node", "--revision", "/tmp/letta"]
        )
        let nodeLetta = process(
            40,
            "node",
            argv: ["node", "--use-strict", "/home/user/node_modules/.bin/letta"]
        )
        let nodeHarmonyLetta = process(
            40,
            "nodejs",
            argv: ["nodejs", "-harmony", "/tmp/letta"]
        )
        let nodeHeapLetta = process(
            40,
            "node.exe",
            argv: ["node.exe", "--max-old-space-size=4096", "/tmp/letta"]
        )
        let nodeOneShot = process(
            40,
            "node",
            argv: ["node", "--watch", "/tmp/letta", "--prompt"]
        )
        #expect(Diagnoser.cpuSamplePid([nodeFalseLetta, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([nodeFalseLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([nodeRevisionLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([nodeFalseLetta]) == 8)
        #expect(
            Diagnoser.cpuSamplePid([mcp, nodeFalseLetta], foregroundProcessGroupId: 8) == 10
        )
        #expect(Diagnoser.cpuSamplePid([helper, nodeLetta]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, nodeHarmonyLetta]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, nodeHeapLetta]) == 40)
        #expect(Diagnoser.cpuSamplePid([nodeLetta, interactive]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, nodeOneShot]) == 10)
        #expect(Diagnoser.cpuSamplePid([nodeOneShot, interactive]) == 30)

        // Bun still runs the file after an unknown long option. Deno's
        // unknown short and `--help` are still skipped.
        let bunUnknown = process(
            20, "bun", argv: ["bun", "--not-a-flag", "/usr/local/bin/codex"]
        )
        let denoUnknown = process(
            20, "deno", argv: ["deno", "run", "-z", "/usr/local/bin/codex"]
        )
        let denoHelp = process(
            20, "deno", argv: ["deno", "run", "--help", "/tmp/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, bunUnknown]) == 20)
        #expect(Diagnoser.cpuSamplePid([mcp, bunUnknown], foregroundProcessGroupId: 20) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, denoUnknown]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, denoHelp]) == 20)
    }

    @Test("a node value the runtime rejects is not the agent script")
    func nodeRejectedValueIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Node 22.23 exits on these operands, so the path is not the script
        // and that node is not the group leader.
        let rejected: [(String, [String])] = [
            ("rejections", ["node", "--unhandled-rejections", "nope", "/usr/local/bin/codex"]),
            ("rejections-case", ["nodejs", "--unhandled-rejections", "Strict", "/tmp/codex"]),
            ("rejections-eq", ["node", "--unhandled-rejections=nope", "/tmp/codex"]),
            ("dns", ["node", "--dns-result-order", "Verbatim", "/usr/local/bin/codex"]),
            ("proto", ["node.exe", "--disable-proto", "off", "/tmp/codex"]),
            ("input", ["node", "--input-type", "nope", "/usr/local/bin/codex"]),
            ("default-type", ["node", "--experimental-default-type", "module-typescript", "/tmp/codex"]),
            ("trace", ["node", "--trace-require-module", "true", "/usr/local/bin/codex"]),
            ("pages", ["node", "--use-largepages", "OFF", "/tmp/codex"]),
            ("pages-eq", ["nodejs", "--use-largepages=default", "/tmp/codex"]),
            ("uid", ["node", "--inspect-publish-uid", "STDERR", "/usr/local/bin/codex"]),
            ("uid-tail", ["node", "--inspect-publish-uid", "stderr,nope", "/tmp/codex"]),
            ("cpu-name", ["node", "--cpu-prof-name", "out", "/usr/local/bin/codex"]),
            ("cpu-name-eq", ["node.exe", "--cpu-prof-name=out", "/tmp/codex"]),
            ("cpu-dir", ["node", "--cpu-prof-dir", "/tmp", "/usr/local/bin/codex"]),
            ("cpu-off", ["node", "--cpu-prof", "--no-cpu-prof", "--cpu-prof-name", "out", "/tmp/codex"]),
            ("cpu-interval", ["node", "--cpu-prof-interval", "100", "/usr/local/bin/codex"]),
            ("cpu-interval-eq", ["nodejs", "--cpu-prof-interval=1e3", "/tmp/codex"]),
            ("heap-name", ["node", "--heap-prof-name", "out", "/usr/local/bin/codex"]),
            ("heap-interval", ["node", "--heap-prof-interval", "1", "/tmp/codex"]),
            ("heap-off", ["node", "--heap-prof", "--no-heap-prof", "--heap-prof-interval", "1", "/tmp/codex"]),
            ("tls", ["node", "--tls-min-v1.3", "--tls-max-v1.2", "/usr/local/bin/codex"]),
            ("tls-eq", ["node.exe", "--tls-min-v1.3=true", "--tls-max-v1.2", "/tmp/codex"]),
            ("ca", ["node", "--use-openssl-ca", "--use-bundled-ca", "/usr/local/bin/codex"]),
            ("ca-eq", ["nodejs", "--use-openssl-ca=true", "--use-bundled-ca", "/tmp/codex"]),
            ("fs-read", ["node", "--allow-fs-read", "/tmp", "/usr/local/bin/codex"]),
            ("fs-write", ["node.exe", "--allow-fs-write", "/tmp", "/tmp/codex"]),
            ("fs-off", ["node", "--permission", "--no-permission", "--allow-fs-read", "/tmp", "/usr/local/bin/codex"]),
            ("fs-no-eq", ["nodejs", "--no-permission=true", "--allow-fs-read=/tmp", "/tmp/codex"]),
        ]
        for (label, argv) in rejected {
            let exited = process(4, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([exited, claude]) == 12, "\(label) ranked the path")
            #expect(
                Diagnoser.cpuSamplePid([mcp, exited], foregroundProcessGroupId: 4) == 10,
                "\(label) took the sample from the leader slot"
            )
        }
        #expect(
            Diagnoser.cpuSamplePid([
                process(4, "node", argv: ["node", "--unhandled-rejections", "nope", "/tmp/codex"])
            ]) == 4
        )

        // The same flags with a value Node runs, including a default
        // profiler interval and a companion that appears after the name.
        let kept: [(String, [String])] = [
            ("rejections", ["node", "--unhandled-rejections", "strict", "/usr/local/bin/codex"]),
            ("rejections-eq", ["node", "--unhandled-rejections=none", "/tmp/codex"]),
            ("rejections-long", ["nodejs", "--unhandled-rejections", "warn-with-error-code", "/tmp/codex"]),
            ("dns", ["node", "--dns-result-order", "ipv4first", "/usr/local/bin/codex"]),
            ("dns-eq", ["node", "--dns-result-order=verbatim", "/tmp/codex"]),
            ("proto", ["node.exe", "--disable-proto", "delete", "/tmp/codex"]),
            ("proto-throw", ["node", "--disable-proto=throw", "/usr/local/bin/codex"]),
            ("input", ["node", "--input-type", "module-typescript", "/tmp/codex"]),
            ("input-eq", ["node", "--input-type=commonjs", "/usr/local/bin/codex"]),
            ("default-type", ["nodejs", "--experimental-default-type", "commonjs", "/tmp/codex"]),
            ("trace", ["node", "--trace-require-module", "no-node-modules", "/usr/local/bin/codex"]),
            ("trace-all", ["node", "--trace-require-module=all", "/tmp/codex"]),
            ("pages", ["node", "--use-largepages", "silent", "/usr/local/bin/codex"]),
            ("pages-eq", ["node.exe", "--use-largepages=off", "/tmp/codex"]),
            ("uid", ["node", "--inspect-publish-uid", "stderr,http", "/usr/local/bin/codex"]),
            ("uid-empty", ["node", "--inspect-publish-uid", ",", "/tmp/codex"]),
            ("cpu-with", ["node", "--cpu-prof", "--cpu-prof-name", "out", "/usr/local/bin/codex"]),
            ("cpu-after", ["node", "--cpu-prof-name", "out", "--cpu-prof", "/tmp/codex"]),
            ("cpu-eq", ["nodejs", "--cpu-prof=false", "--cpu-prof-dir", "/tmp", "/usr/local/bin/codex"]),
            ("cpu-back", ["node", "--no-cpu-prof", "--cpu-prof", "--cpu-prof-name", "out", "/tmp/codex"]),
            ("cpu-1000", ["node", "--cpu-prof-interval", "1000", "/usr/local/bin/codex"]),
            ("cpu-plus", ["node.exe", "--cpu-prof-interval", "+1000", "/tmp/codex"]),
            ("cpu-zeros", ["node", "--cpu-prof-interval", "01000", "/usr/local/bin/codex"]),
            ("cpu-tail", ["node", "--cpu-prof-interval", "1000abc", "/tmp/codex"]),
            ("cpu-dot", ["nodejs", "--cpu-prof-interval=1000.5abc", "/tmp/codex"]),
            ("cpu-space", ["node", "--cpu-prof-interval", " 1000", "/usr/local/bin/codex"]),
            ("cpu-on-nope", ["node", "--cpu-prof", "--cpu-prof-interval", "nope", "/tmp/codex"]),
            ("heap-default", ["node", "--heap-prof-interval", "524288", "/usr/local/bin/codex"]),
            ("heap-plus", ["node.exe", "--heap-prof-interval", "+524288", "/tmp/codex"]),
            ("heap-tail", ["node", "--heap-prof-interval", "524288.9", "/usr/local/bin/codex"]),
            ("heap-with", ["node", "--heap-prof", "--heap-prof-name", "out", "/tmp/codex"]),
            ("heap-on-one", ["nodejs", "--heap-prof", "--heap-prof-interval", "1", "/usr/local/bin/codex"]),
            ("heap-default-off", ["node", "--heap-prof", "--no-heap-prof", "--heap-prof-interval", "524288", "/tmp/codex"]),
            ("tls-one", ["node", "--tls-min-v1.3", "/usr/local/bin/codex"]),
            ("tls-cleared", ["node", "--tls-min-v1.3", "--no-tls-min-v1.3", "--tls-max-v1.2", "/tmp/codex"]),
            ("ca-one", ["node.exe", "--use-openssl-ca", "/usr/local/bin/codex"]),
            ("script-first", ["node", "/usr/local/bin/codex", "--tls-min-v1.3", "--tls-max-v1.2"]),
            ("script-first-ca", ["nodejs", "/tmp/codex", "--use-openssl-ca", "--use-bundled-ca"]),
            ("fs-on", ["node", "--permission", "--allow-fs-read", "/tmp", "/usr/local/bin/codex"]),
            ("fs-after", ["node", "--allow-fs-read", "/tmp", "--permission", "/tmp/codex"]),
            ("fs-alias", ["nodejs", "--experimental-permission=true", "--allow-fs-write", "/tmp", "/usr/local/bin/codex"]),
            ("fs-back", ["node.exe", "--no-experimental-permission", "--permission", "--allow-fs-read", "*", "/tmp/codex"]),
        ]
        for (label, argv) in kept {
            let running = process(20, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([helper, running]) == 20, "\(label) dropped the script")
        }
        let leader = process(
            20,
            "node",
            argv: ["node", "--cpu-prof", "--cpu-prof-name", "out", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([mcp, leader], foregroundProcessGroupId: 20) == 20)

        let badLetta = process(
            8,
            "node",
            argv: ["node", "--unhandled-rejections", "nope", "/tmp/letta"]
        )
        let tlsLetta = process(
            8,
            "node",
            argv: ["node", "--tls-min-v1.3", "--tls-max-v1.2", "/home/user/node_modules/.bin/letta"]
        )
        let keptLetta = process(
            40,
            "node",
            argv: ["node", "--unhandled-rejections", "throw", "/tmp/letta"]
        )
        let profLetta = process(
            40,
            "nodejs",
            argv: ["nodejs", "--cpu-prof-interval", "1000", "/tmp/letta", "--prompt"]
        )
        #expect(Diagnoser.cpuSamplePid([badLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([badLetta, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([tlsLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([helper, keptLetta]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, profLetta]) == 10)
        #expect(Diagnoser.cpuSamplePid([profLetta, interactive]) == 30)
    }

    @Test("a node percentage the runtime rejects is not the agent script")
    func nodePercentageRejectIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Node 22.23 exits on these operands, so the path is not the script
        // and that node is not the group leader. A separate word that
        // starts with `-` is missing an argument. `--flag=` is empty.
        let rejected: [(String, [String])] = [
            ("nope", ["node", "--max-old-space-size-percentage", "nope", "/usr/local/bin/codex"]),
            ("nope-eq", ["nodejs", "--max-old-space-size-percentage=nope", "/tmp/codex"]),
            ("zero", ["node", "--max-old-space-size-percentage", "0", "/usr/local/bin/codex"]),
            ("zero-dot", ["node.exe", "--max-old-space-size-percentage=0.0", "/tmp/codex"]),
            ("plus-zero", ["node", "--max-old-space-size-percentage=+0", "/tmp/codex"]),
            ("over", ["node", "--max-old-space-size-percentage", "101", "/usr/local/bin/codex"]),
            ("over-eq", ["nodejs", "--max-old-space-size-percentage=100.1", "/tmp/codex"]),
            ("inf", ["node", "--max-old-space-size-percentage", "inf", "/usr/local/bin/codex"]),
            ("infinity", ["node.exe", "--max-old-space-size-percentage=Infinity", "/tmp/codex"]),
            ("percent", ["node", "--max-old-space-size-percentage", "50%", "/usr/local/bin/codex"]),
            ("tail", ["node", "--max-old-space-size-percentage=1e2x", "/tmp/codex"]),
            ("hex-bare", ["nodejs", "--max-old-space-size-percentage", "0x", "/usr/local/bin/codex"]),
            ("hex-over", ["node", "--max-old-space-size-percentage=0x65", "/tmp/codex"]),
            ("under", ["node", "--max-old-space-size-percentage", "1e-324", "/usr/local/bin/codex"]),
            ("under-hex", ["node.exe", "--max-old-space-size-percentage=0x1p-1075", "/tmp/codex"]),
            ("spaces", ["node", "--max-old-space-size-percentage", "   ", "/usr/local/bin/codex"]),
            ("trail-space", ["node", "--max-old-space-size-percentage=50 ", "/tmp/codex"]),
            ("nan-tail", ["nodejs", "--max-old-space-size-percentage=nan(a-b)", "/tmp/codex"]),
            ("nan-space", ["node", "--max-old-space-size-percentage=nan ", "/usr/local/bin/codex"]),
            ("empty-eq", ["node", "--max-old-space-size-percentage=", "/tmp/codex"]),
            ("dash", ["node.exe", "--max-old-space-size-percentage", "-1", "/usr/local/bin/codex"]),
            ("neg", ["node", "--max-old-space-size-percentage=-1", "/tmp/codex"]),
            ("round-up", ["nodejs", "--max-old-space-size-percentage=100.00000000000001", "/tmp/codex"]),
            ("round-up-hex", ["node", "--max-old-space-size-percentage=0x1.9000000000001p6", "/usr/local/bin/codex"]),
        ]
        for (label, argv) in rejected {
            let exited = process(4, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([exited, claude]) == 12, "\(label) ranked the path")
            #expect(
                Diagnoser.cpuSamplePid([mcp, exited], foregroundProcessGroupId: 4) == 10,
                "\(label) took the sample from the leader slot"
            )
        }
        #expect(
            Diagnoser.cpuSamplePid([
                process(4, "node", argv: [
                    "node", "--max-old-space-size-percentage", "nope", "/tmp/codex",
                ])
            ]) == 4
        )

        // Values Node runs, including hex, an exponent, and NaN. An empty
        // separate word is the unset field, so the file still runs.
        // `-nan` as its own word is a missing argument; `=-nan` runs.
        let kept: [(String, [String])] = [
            ("fifty", ["node", "--max-old-space-size-percentage", "50", "/usr/local/bin/codex"]),
            ("tenth", ["node", "--max-old-space-size-percentage", "0.1", "/tmp/codex"]),
            ("hundred", ["nodejs", "--max-old-space-size-percentage", "100", "/usr/local/bin/codex"]),
            ("hundred-dot", ["node.exe", "--max-old-space-size-percentage=100.0", "/tmp/codex"]),
            ("exp", ["node", "--max-old-space-size-percentage=1e2", "/usr/local/bin/codex"]),
            ("plus", ["node", "--max-old-space-size-percentage", "+0.5", "/tmp/codex"]),
            ("trail-dot", ["nodejs", "--max-old-space-size-percentage=1.", "/tmp/codex"]),
            ("lead-dot", ["node", "--max-old-space-size-percentage", ".5", "/usr/local/bin/codex"]),
            ("hex", ["node.exe", "--max-old-space-size-percentage", "0x10", "/tmp/codex"]),
            ("hex-p", ["node", "--max-old-space-size-percentage=0x1p4", "/usr/local/bin/codex"]),
            ("hex-100", ["nodejs", "--max-old-space-size-percentage=0x64", "/tmp/codex"]),
            ("hex-exact", ["node", "--max-old-space-size-percentage=0x1.9p6", "/usr/local/bin/codex"]),
            ("hex-dot", ["node", "--max-old-space-size-percentage", "0x.8", "/tmp/codex"]),
            ("nan", ["node.exe", "--max-old-space-size-percentage", "nan", "/usr/local/bin/codex"]),
            ("nan-eq", ["node", "--max-old-space-size-percentage=NaN", "/tmp/codex"]),
            ("nan-plus", ["nodejs", "--max-old-space-size-percentage=+nan", "/tmp/codex"]),
            ("nan-neg", ["node", "--max-old-space-size-percentage=-nan", "/usr/local/bin/codex"]),
            ("nan-empty", ["node", "--max-old-space-size-percentage=nan()", "/tmp/codex"]),
            ("nan-payload", ["node.exe", "--max-old-space-size-percentage", "nan(abc)", "/usr/local/bin/codex"]),
            ("space", ["node", "--max-old-space-size-percentage", " 50", "/tmp/codex"]),
            ("tiny", ["nodejs", "--max-old-space-size-percentage=1e-323", "/usr/local/bin/codex"]),
            ("subnormal", ["node", "--max-old-space-size-percentage", "5e-324", "/tmp/codex"]),
            ("hex-sub", ["node", "--max-old-space-size-percentage=0x1p-1074", "/usr/local/bin/codex"]),
            ("round-down", ["node.exe", "--max-old-space-size-percentage=100.000000000000007", "/tmp/codex"]),
            ("empty", ["node", "--max-old-space-size-percentage", "", "/usr/local/bin/codex"]),
            ("script-first", ["nodejs", "/usr/local/bin/codex", "--max-old-space-size-percentage", "nope"]),
        ]
        for (label, argv) in kept {
            let running = process(20, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([helper, running]) == 20, "\(label) dropped the script")
        }
        let leader = process(
            20,
            "node",
            argv: ["node", "--max-old-space-size-percentage", "0x10", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([mcp, leader], foregroundProcessGroupId: 20) == 20)

        let badLetta = process(
            8,
            "node",
            argv: ["node", "--max-old-space-size-percentage", "nope", "/tmp/letta"]
        )
        let keptLetta = process(
            40,
            "node",
            argv: ["node", "--max-old-space-size-percentage", "50", "/tmp/letta"]
        )
        let nanLetta = process(
            40,
            "nodejs",
            argv: [
                "nodejs", "--max-old-space-size-percentage=nan", "/tmp/letta", "--prompt",
            ]
        )
        #expect(Diagnoser.cpuSamplePid([badLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([badLetta, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, keptLetta]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, nanLetta]) == 10)
        #expect(Diagnoser.cpuSamplePid([nanLetta, interactive]) == 30)

        // Bun does not use the node check. The word after the flag is the
        // script, and `nope` is not an agent, so the codex path is not.
        let bun = process(
            20,
            "bun",
            argv: ["bun", "--max-old-space-size-percentage", "nope", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, bun]) == 10)
    }

    @Test("a node test-isolation value the runtime rejects is not the agent script")
    func nodeTestIsolationRejectIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Node 22.23 rejects the operand only when `--test` is on, and
        // only the last operand counts. `none` and `process` run.
        // `--test=` is still an exit on its own, before this check.
        let rejected: [(String, [String])] = [
            ("nope", ["node", "--test", "--experimental-test-isolation", "nope", "/usr/local/bin/codex"]),
            ("nope-eq", ["nodejs", "--test", "--experimental-test-isolation=nope", "/tmp/codex"]),
            ("case", ["node.exe", "--experimental-test-isolation", "NONE", "--test", "/usr/local/bin/codex"]),
            ("space", ["node", "--test", "--experimental-test-isolation=none ", "/tmp/codex"]),
            ("lead-space", ["nodejs", "--experimental-test-isolation", " none", "--test", "/usr/local/bin/codex"]),
            ("empty", ["node", "--test", "--experimental-test-isolation", "", "/tmp/codex"]),
            ("empty-eq", ["node.exe", "--experimental-test-isolation=", "--test", "/usr/local/bin/codex"]),
            ("dash", ["node", "--test", "--experimental-test-isolation", "--watch", "/tmp/codex"]),
            ("last-nope", [
                "nodejs", "--experimental-test-isolation", "none", "--test",
                "--experimental-test-isolation=nope", "/usr/local/bin/codex",
            ]),
            ("reenabled", [
                "node", "--no-test", "--experimental-test-isolation", "nope", "--test", "/tmp/codex",
            ]),
            ("title", [
                "node.exe", "--title", "helper", "--test",
                "--experimental-test-isolation", "Process", "/usr/local/bin/codex",
            ]),
        ]
        for (label, argv) in rejected {
            let exited = process(4, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([exited, claude]) == 12, "\(label) ranked the path")
            #expect(
                Diagnoser.cpuSamplePid([mcp, exited], foregroundProcessGroupId: 4) == 10,
                "\(label) took the sample from the leader slot"
            )
        }
        #expect(
            Diagnoser.cpuSamplePid([
                process(4, "node", argv: [
                    "node", "--test", "--experimental-test-isolation", "nope", "/tmp/codex",
                ])
            ]) == 4
        )

        // Without `--test` the operand is ignored, so `nope` still names
        // the file. `--no-test` after `--test` does too. The last `none`
        // or `process` names the file when the runner is on. A script
        // written first is already the program.
        let kept: [(String, [String])] = [
            ("no-test", ["node", "--experimental-test-isolation", "nope", "/usr/local/bin/codex"]),
            ("no-test-eq", ["nodejs", "--experimental-test-isolation=NONE", "/tmp/codex"]),
            ("empty-off", ["node.exe", "--experimental-test-isolation", "", "/usr/local/bin/codex"]),
            ("none", ["node", "--test", "--experimental-test-isolation", "none", "/usr/local/bin/codex"]),
            ("process", ["nodejs", "--experimental-test-isolation", "process", "--test", "/tmp/codex"]),
            ("none-eq", ["node.exe", "--test", "--experimental-test-isolation=none", "/usr/local/bin/codex"]),
            ("process-eq", ["node", "--experimental-test-isolation=process", "--test", "/tmp/codex"]),
            ("last-none", [
                "nodejs", "--test", "--experimental-test-isolation", "nope",
                "--experimental-test-isolation=none", "/usr/local/bin/codex",
            ]),
            ("cleared", [
                "node", "--test", "--no-test", "--experimental-test-isolation", "nope", "/tmp/codex",
            ]),
            ("only", ["node", "--test-only", "--experimental-test-isolation", "nope", "/tmp/codex"]),
            ("script-first", [
                "nodejs", "/usr/local/bin/codex", "--test", "--experimental-test-isolation", "nope",
            ]),
            ("title-off", [
                "node", "--title", "helper", "--experimental-test-isolation", "nope",
                "/usr/local/bin/codex",
            ]),
        ]
        for (label, argv) in kept {
            let running = process(20, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([helper, running]) == 20, "\(label) dropped the script")
        }
        let leader = process(
            20,
            "node",
            argv: ["node", "--test", "--experimental-test-isolation", "process", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([mcp, leader], foregroundProcessGroupId: 20) == 20)

        let badLetta = process(
            8,
            "node",
            argv: ["node", "--test", "--experimental-test-isolation", "nope", "/tmp/letta"]
        )
        let keptLetta = process(
            40,
            "node",
            argv: ["node", "--experimental-test-isolation", "nope", "/tmp/letta"]
        )
        let runnerLetta = process(
            40,
            "nodejs",
            argv: ["nodejs", "--test", "--experimental-test-isolation=none", "/tmp/letta", "--prompt"]
        )
        #expect(Diagnoser.cpuSamplePid([badLetta, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([badLetta, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, keptLetta]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, runnerLetta]) == 10)
        #expect(Diagnoser.cpuSamplePid([runnerLetta, interactive]) == 30)

        // Bun does not use the node check. `nope` is the script word.
        let bun = process(
            20,
            "bun",
            argv: ["bun", "--test", "--experimental-test-isolation", "nope", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, bun]) == 10)
    }

    @Test("node --test with --interactive or --watch-path is not the agent script")
    func nodeTestInteractiveOrWatchPathIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Node 22.23 exits on `--test` with `--interactive` / `-i`, and
        // on `--test` with `--watch-path`. The attached boolean word is
        // ignored, so `--interactive=false` is still interactive. The
        // last `--no-` wins. `--test=` is still an exit on its own.
        let rejected: [(String, [String])] = [
            ("interactive", ["node", "--test", "--interactive", "/usr/local/bin/codex"]),
            ("interactive-first", ["nodejs", "--interactive", "--test", "/tmp/codex"]),
            ("short", ["node.exe", "-i", "--test", "/usr/local/bin/codex"]),
            ("short-after", ["node", "--test", "-i", "/tmp/codex"]),
            ("eq-true", ["nodejs", "--test", "--interactive=true", "/usr/local/bin/codex"]),
            ("eq-false", ["node", "--interactive=false", "--test", "/tmp/codex"]),
            ("reenabled", [
                "node.exe", "--no-interactive", "--interactive", "--test", "/usr/local/bin/codex",
            ]),
            ("short-reenabled", ["node", "--no-interactive", "-i", "--test", "/tmp/codex"]),
            ("watch-path", ["node", "--test", "--watch-path", "/tmp", "/usr/local/bin/codex"]),
            ("watch-path-first", ["nodejs", "--watch-path", "/tmp", "--test", "/tmp/codex"]),
            ("watch-path-eq", ["node.exe", "--test", "--watch-path=/tmp", "/usr/local/bin/codex"]),
            ("two-paths", [
                "node", "--watch-path", "/tmp", "--watch-path", "/var", "--test", "/usr/local/bin/codex",
            ]),
            ("title", ["nodejs", "--title", "helper", "--test", "--interactive", "/tmp/codex"]),
            ("isolation-none", [
                "node", "--test", "--experimental-test-isolation", "none", "--interactive",
                "/usr/local/bin/codex",
            ]),
            ("isolation-process", [
                "node.exe", "--experimental-test-isolation=process", "--watch-path", "/tmp", "--test",
                "/tmp/codex",
            ]),
            ("cleared-then-test", [
                "node", "--watch-path", "/tmp", "--no-test", "--test", "/usr/local/bin/codex",
            ]),
            ("require", ["nodejs", "--require", "./preload.js", "-i", "--test", "/tmp/codex"]),
            ("path-only", ["node", "--test", "--watch-path", "/usr/local/bin/codex"]),
        ]
        for (label, argv) in rejected {
            let exited = process(4, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([exited, claude]) == 12, "\(label) ranked the path")
            #expect(
                Diagnoser.cpuSamplePid([mcp, exited], foregroundProcessGroupId: 4) == 10,
                "\(label) took the sample from the leader slot"
            )
        }
        #expect(
            Diagnoser.cpuSamplePid([
                process(4, "node", argv: ["node", "--test", "--interactive", "/tmp/codex"])
            ]) == 4
        )

        // Without `--test` the file runs, including `--watch` beside
        // `--test` and a later `--no-test`. `--test-only` is not the
        // runner. A script written first is already the program, so
        // flags after it are arguments. The word after `--watch-path`
        // is the directory, and the next word is the script.
        let kept: [(String, [String])] = [
            ("interactive", ["node", "--interactive", "/usr/local/bin/codex"]),
            ("short", ["nodejs", "-i", "/tmp/codex"]),
            ("watch-path", ["node.exe", "--watch-path", "/tmp", "/usr/local/bin/codex"]),
            ("watch-path-eq", ["node", "--watch-path=/tmp", "/tmp/codex"]),
            ("watch-path-other", [
                "nodejs", "--watch-path", "/usr/local/bin/claude", "/usr/local/bin/codex",
            ]),
            ("test", ["node", "--test", "/usr/local/bin/codex"]),
            ("test-watch", ["node.exe", "--test", "--watch", "/tmp/codex"]),
            ("watch-first", ["node", "--watch", "--test", "/usr/local/bin/codex"]),
            ("no-interactive", ["nodejs", "--test", "--no-interactive", "/tmp/codex"]),
            ("no-interactive-eq", ["node", "--test", "--no-interactive=false", "/usr/local/bin/codex"]),
            ("cleared-interactive", [
                "node.exe", "--interactive", "--no-interactive", "--test", "/tmp/codex",
            ]),
            ("cleared-short", ["node", "-i", "--no-interactive", "--test", "/usr/local/bin/codex"]),
            ("cleared-test", [
                "nodejs", "--test", "--no-test", "--interactive", "/tmp/codex",
            ]),
            ("cleared-watch-path", [
                "node", "--test", "--watch-path", "/tmp", "--no-test", "/usr/local/bin/codex",
            ]),
            ("only", ["node.exe", "--test-only", "--interactive", "/tmp/codex"]),
            ("preserve", ["node", "--test", "--watch-preserve-output", "/usr/local/bin/codex"]),
            ("script-first", ["nodejs", "/usr/local/bin/codex", "--test", "--interactive"]),
            ("script-first-path", ["node", "/tmp/codex", "--watch-path", "/tmp", "--test"]),
            ("flag-after-script", ["node.exe", "--interactive", "/usr/local/bin/codex", "--test"]),
            ("isolation-off", [
                "node", "--interactive", "--experimental-test-isolation", "nope", "/usr/local/bin/codex",
            ]),
            ("watch-path-isolation", [
                "nodejs", "--watch-path", "/tmp", "--experimental-test-isolation", "nope", "/tmp/codex",
            ]),
            ("title", ["node", "--title", "helper", "--watch-path", "/tmp", "/usr/local/bin/codex"]),
        ]
        for (label, argv) in kept {
            let running = process(20, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([helper, running]) == 20, "\(label) dropped the script")
        }
        let leader = process(
            20,
            "node",
            argv: ["node", "--watch", "--test", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([mcp, leader], foregroundProcessGroupId: 20) == 20)

        let badInteractive = process(
            8,
            "node",
            argv: ["node", "--test", "--interactive", "/tmp/letta"]
        )
        let badPath = process(
            8,
            "nodejs",
            argv: ["nodejs", "--watch-path", "/tmp", "--test", "/tmp/letta"]
        )
        let keptLetta = process(
            40,
            "node",
            argv: ["node", "--interactive", "/tmp/letta"]
        )
        let keptPath = process(
            40,
            "node.exe",
            argv: ["node.exe", "--watch-path", "/tmp", "/tmp/letta"]
        )
        let oneShot = process(
            40,
            "nodejs",
            argv: ["nodejs", "--interactive", "/tmp/letta", "--prompt"]
        )
        #expect(Diagnoser.cpuSamplePid([badInteractive, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([badInteractive, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([badPath, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([badPath, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, keptLetta]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, keptPath]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, oneShot]) == 10)
        #expect(Diagnoser.cpuSamplePid([oneShot, interactive]) == 30)

        // Bun does not use the node check. Both words are flags, and
        // the codex path is the script.
        let bun = process(
            20,
            "bun",
            argv: ["bun", "--test", "--interactive", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, bun]) == 20)
    }

    @Test("node --watch with --interactive or --test-force-exit is not the agent script")
    func nodeWatchInteractiveOrForceExitIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Node 22.23 exits on `--watch` with `--interactive` / `-i`, and
        // on `--watch` with `--test-force-exit`. `--watch-path` implies
        // `--watch` at that word. The attached boolean word is ignored.
        // The last `--no-` wins. `--watch` beside `--test` still runs.
        let rejected: [(String, [String])] = [
            ("interactive", ["node", "--watch", "--interactive", "/usr/local/bin/codex"]),
            ("interactive-first", ["nodejs", "--interactive", "--watch", "/tmp/codex"]),
            ("short", ["node.exe", "--watch", "-i", "/usr/local/bin/codex"]),
            ("short-first", ["node", "-i", "--watch", "/tmp/codex"]),
            ("eq-true", ["nodejs", "--watch", "--interactive=true", "/usr/local/bin/codex"]),
            ("eq-false", ["node", "--interactive=false", "--watch", "/tmp/codex"]),
            ("watch-eq-false", ["node.exe", "--watch=false", "--interactive", "/usr/local/bin/codex"]),
            ("reenabled", [
                "node", "--no-interactive", "--interactive", "--watch", "/tmp/codex",
            ]),
            ("short-reenabled", [
                "nodejs", "--no-interactive", "-i", "--watch", "/usr/local/bin/codex",
            ]),
            ("watch-reenabled", [
                "node.exe", "--interactive", "--no-watch", "--watch", "/tmp/codex",
            ]),
            ("watch-path", ["node", "--watch-path", "/tmp", "--interactive", "/usr/local/bin/codex"]),
            ("watch-path-eq", ["nodejs", "--watch-path=/tmp", "-i", "/tmp/codex"]),
            ("watch-path-reimplies", [
                "node.exe", "--no-watch", "--watch-path", "/tmp", "--interactive",
                "/usr/local/bin/codex",
            ]),
            ("two-paths", [
                "node", "--watch-path", "/tmp", "--watch-path", "/var", "--interactive",
                "/tmp/codex",
            ]),
            ("force", ["nodejs", "--watch", "--test-force-exit", "/usr/local/bin/codex"]),
            ("force-first", ["node", "--test-force-exit", "--watch", "/tmp/codex"]),
            ("force-eq-false", [
                "node.exe", "--watch", "--test-force-exit=false", "/usr/local/bin/codex",
            ]),
            ("force-eq-true", ["node", "--test-force-exit=true", "--watch", "/tmp/codex"]),
            ("force-reenabled", [
                "nodejs", "--watch", "--no-test-force-exit", "--test-force-exit",
                "/usr/local/bin/codex",
            ]),
            ("watch-path-force", [
                "node.exe", "--watch-path", "/tmp", "--test-force-exit", "/tmp/codex",
            ]),
            ("watch-path-eq-force", [
                "node", "--watch-path=/tmp", "--test-force-exit", "/usr/local/bin/codex",
            ]),
            ("test-watch-force", [
                "nodejs", "--test", "--watch", "--test-force-exit", "/tmp/codex",
            ]),
            ("title", ["node", "--title", "helper", "--watch", "--interactive", "/tmp/codex"]),
            ("require", [
                "node.exe", "--require", "./preload.js", "-i", "--watch", "/usr/local/bin/codex",
            ]),
            ("isolation-off", [
                "node", "--experimental-test-isolation", "nope", "--watch", "--interactive",
                "/tmp/codex",
            ]),
            ("isolation-none-force", [
                "nodejs", "--experimental-test-isolation=none", "--watch", "--test-force-exit",
                "/usr/local/bin/codex",
            ]),
            ("test-isolation-force", [
                "node.exe", "--test", "--experimental-test-isolation", "none", "--watch",
                "--test-force-exit", "/tmp/codex",
            ]),
            ("only", ["node", "--test-only", "--watch", "--interactive", "/usr/local/bin/codex"]),
            ("only-force", ["nodejs", "--test-only", "--test-force-exit", "--watch", "/tmp/codex"]),
            ("no-test", ["node.exe", "--no-test", "--watch", "--interactive", "/tmp/codex"]),
            ("cleared-test-path", [
                "node", "--test", "--watch-path=/tmp", "--no-test", "--interactive",
                "/usr/local/bin/codex",
            ]),
            ("preserve", [
                "nodejs", "--watch-preserve-output", "--watch", "--interactive", "/tmp/codex",
            ]),
            ("path-still-tested", [
                "node", "--watch-path", "/tmp", "--no-watch", "--test", "/usr/local/bin/codex",
            ]),
        ]
        for (label, argv) in rejected {
            let exited = process(4, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([exited, claude]) == 12, "\(label) ranked the path")
            #expect(
                Diagnoser.cpuSamplePid([mcp, exited], foregroundProcessGroupId: 4) == 10,
                "\(label) took the sample from the leader slot"
            )
        }
        #expect(
            Diagnoser.cpuSamplePid([
                process(4, "node", argv: ["node", "--watch", "--interactive", "/tmp/codex"])
            ]) == 4
        )

        // A later `--no-` clears the pair. `--watch` beside `--test`
        // still names the file. `--watch-preserve-output` does not
        // imply `--watch`. A script written first is already the program.
        let kept: [(String, [String])] = [
            ("watch", ["node", "--watch", "/usr/local/bin/codex"]),
            ("interactive", ["nodejs", "--interactive", "/tmp/codex"]),
            ("short", ["node.exe", "-i", "/usr/local/bin/codex"]),
            ("force", ["node", "--test-force-exit", "/usr/local/bin/codex"]),
            ("test-watch", ["nodejs", "--test", "--watch", "/tmp/codex"]),
            ("watch-first", ["node.exe", "--watch", "--test", "/usr/local/bin/codex"]),
            ("watch-path", ["node", "--watch-path", "/tmp", "/usr/local/bin/codex"]),
            ("watch-path-eq", ["nodejs", "--watch-path=/tmp", "/tmp/codex"]),
            ("watch-path-other", [
                "node.exe", "--watch-path", "/usr/local/bin/claude", "/usr/local/bin/codex",
            ]),
            ("no-interactive", ["node", "--watch", "--no-interactive", "/tmp/codex"]),
            ("no-interactive-eq", [
                "nodejs", "--watch", "--no-interactive=false", "/usr/local/bin/codex",
            ]),
            ("no-watch", ["node.exe", "--interactive", "--no-watch", "/tmp/codex"]),
            ("cleared-short", ["node", "-i", "--no-interactive", "--watch", "/usr/local/bin/codex"]),
            ("cleared-force", [
                "nodejs", "--watch", "--test-force-exit", "--no-test-force-exit", "/tmp/codex",
            ]),
            ("cleared-watch-after-pair", [
                "node.exe", "--watch", "--interactive", "--no-watch", "/usr/local/bin/codex",
            ]),
            ("path-no-watch-interactive", [
                "node", "--watch-path", "/tmp", "--no-watch", "--interactive", "/tmp/codex",
            ]),
            ("path-no-watch-force", [
                "nodejs", "--watch-path", "/tmp", "--no-watch", "--test-force-exit",
                "/usr/local/bin/codex",
            ]),
            ("path-cleared-short", [
                "node.exe", "--watch-path", "/tmp", "-i", "--no-interactive", "/tmp/codex",
            ]),
            ("path-cleared-interactive", [
                "node", "--interactive", "--watch-path", "/tmp", "--no-interactive",
                "/usr/local/bin/codex",
            ]),
            ("path-cleared-force", [
                "nodejs", "--test-force-exit", "--watch-path=/tmp", "--no-test-force-exit",
                "/tmp/codex",
            ]),
            ("watch-eq-then-no", [
                "node", "--watch=false", "--no-watch", "--interactive", "/usr/local/bin/codex",
            ]),
            ("no-watch-eq", ["node.exe", "--no-watch=false", "--interactive", "/tmp/codex"]),
            ("preserve", ["node", "--watch-preserve-output", "--interactive", "/usr/local/bin/codex"]),
            ("kill-signal", [
                "nodejs", "--watch-kill-signal", "SIGTERM", "--interactive", "/tmp/codex",
            ]),
            ("script-first", ["node", "/usr/local/bin/codex", "--watch", "--interactive"]),
            ("flag-after-script", ["node.exe", "--watch", "/tmp/codex", "--interactive"]),
            ("isolation-off", [
                "nodejs", "--watch", "--experimental-test-isolation", "nope", "/usr/local/bin/codex",
            ]),
            ("title", ["node", "--title", "helper", "--watch", "/tmp/codex"]),
            ("both-cleared", [
                "node.exe", "--no-watch", "--no-interactive", "--watch-path", "/tmp", "--no-watch",
                "--test-force-exit", "--no-test-force-exit", "/usr/local/bin/codex",
            ]),
        ]
        for (label, argv) in kept {
            let running = process(20, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([helper, running]) == 20, "\(label) dropped the script")
        }
        let leader = process(
            20,
            "node",
            argv: ["node", "--watch", "--no-interactive", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([mcp, leader], foregroundProcessGroupId: 20) == 20)

        let badInteractive = process(
            8,
            "node",
            argv: ["node", "--watch", "--interactive", "/tmp/letta"]
        )
        let badForce = process(
            8,
            "nodejs",
            argv: ["nodejs", "--watch-path", "/tmp", "--test-force-exit", "/tmp/letta"]
        )
        let keptLetta = process(
            40,
            "node",
            argv: ["node", "--watch", "/tmp/letta"]
        )
        let keptPath = process(
            40,
            "node.exe",
            argv: ["node.exe", "--watch-path", "/tmp", "--no-watch", "--interactive", "/tmp/letta"]
        )
        let oneShot = process(
            40,
            "nodejs",
            argv: ["nodejs", "--watch", "--no-interactive", "/tmp/letta", "--prompt"]
        )
        #expect(Diagnoser.cpuSamplePid([badInteractive, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([badInteractive, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([badForce, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([badForce, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, keptLetta]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, keptPath]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, oneShot]) == 10)
        #expect(Diagnoser.cpuSamplePid([oneShot, interactive]) == 30)

        let bun = process(
            20,
            "bun",
            argv: ["bun", "--watch", "--interactive", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([helper, bun]) == 20)
    }

    @Test("a node secure heap or snapshot limit the runtime rejects is not the agent script")
    func nodeSecureHeapAndSnapshotLimitAreNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Node 22.23 exits before the file when `--secure-heap` is
        // negative or, once it is at least 2, not a power of two.
        // `--secure-heap-min` is checked only then, after the clamp.
        // `--heapsnapshot-near-heap-limit` exits when `atoll` is
        // negative. The last operand wins. `4abc` is 4 and `abc` is 0.
        let rejected: [(String, [String])] = [
            ("heap-3", ["node", "--secure-heap", "3", "/usr/local/bin/codex"]),
            ("heap-eq", ["nodejs", "--secure-heap=3", "/tmp/codex"]),
            ("heap-tail", ["node.exe", "--secure-heap", "3abc", "/usr/local/bin/codex"]),
            ("heap-plus", ["node", "--secure-heap", "+3", "/tmp/codex"]),
            ("heap-space", ["nodejs", "--secure-heap", " 3", "/usr/local/bin/codex"]),
            ("heap-tab", ["node.exe", "--secure-heap", "\t3", "/tmp/codex"]),
            ("heap-form", ["node", "--secure-heap", "\u{000C}3", "/usr/local/bin/codex"]),
            ("heap-neg", ["nodejs", "--secure-heap=-1", "/tmp/codex"]),
            ("heap-esc", ["node.exe", "--secure-heap", "\\-1", "/usr/local/bin/codex"]),
            ("heap-min64", ["node", "--secure-heap=-9223372036854775808", "/tmp/codex"]),
            ("heap-huge", ["nodejs", "--secure-heap", "9223372036854775807", "/usr/local/bin/codex"]),
            ("heap-last", ["node.exe", "--secure-heap", "4", "--secure-heap", "3", "/tmp/codex"]),
            ("min", ["node", "--secure-heap", "8", "--secure-heap-min", "3", "/usr/local/bin/codex"]),
            ("min-6", ["nodejs", "--secure-heap=8", "--secure-heap-min=6", "/tmp/codex"]),
            ("min-first", ["node.exe", "--secure-heap-min", "4", "--secure-heap", "3", "/usr/local/bin/codex"]),
            ("min-clamp", [
                "node", "--secure-heap", "4294967296", "--secure-heap-min", "2147483647",
                "/tmp/codex",
            ]),
            ("near", ["nodejs", "--heapsnapshot-near-heap-limit=-1", "/usr/local/bin/codex"]),
            ("near-esc", ["node.exe", "--heapsnapshot-near-heap-limit", "\\-1", "/tmp/codex"]),
            ("near-space", ["node", "--heapsnapshot-near-heap-limit", " -2", "/usr/local/bin/codex"]),
            ("near-form", ["nodejs", "--heapsnapshot-near-heap-limit=\u{000C}-1", "/tmp/codex"]),
            ("near-last", [
                "node.exe", "--heapsnapshot-near-heap-limit=2", "--heapsnapshot-near-heap-limit=-3",
                "/usr/local/bin/codex",
            ]),
            ("near-min64", [
                "node", "--heapsnapshot-near-heap-limit=-9223372036854775808", "/tmp/codex",
            ]),
            ("near-overflow", [
                "nodejs", "--heapsnapshot-near-heap-limit=-9223372036854775809",
                "/usr/local/bin/codex",
            ]),
            ("near-then-heap", [
                "node.exe", "--heapsnapshot-near-heap-limit=2", "--secure-heap", "3", "/tmp/codex",
            ]),
            ("heap-then-near", [
                "node", "--secure-heap", "4", "--heapsnapshot-near-heap-limit=-1",
                "/usr/local/bin/codex",
            ]),
            ("title", ["nodejs", "--title", "helper", "--secure-heap", "3", "/tmp/codex"]),
            ("strict", ["node.exe", "--use-strict", "--secure-heap=3", "/usr/local/bin/codex"]),
            ("empty-eq", ["node", "--secure-heap=", "/tmp/codex"]),
            ("near-dash", ["nodejs", "--heapsnapshot-near-heap-limit", "-1", "/usr/local/bin/codex"]),
        ]
        for (label, argv) in rejected {
            let exited = process(4, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([exited, claude]) == 12, "\(label) ranked the path")
            #expect(
                Diagnoser.cpuSamplePid([mcp, exited], foregroundProcessGroupId: 4) == 10,
                "\(label) took the sample from the leader slot"
            )
        }
        #expect(
            Diagnoser.cpuSamplePid([
                process(4, "node", argv: ["node", "--secure-heap", "3", "/usr/local/bin/codex"])
            ]) == 4
        )

        // `0` and `1` leave the heap off. A power of two runs, including
        // a later `4` that replaces `3`. The minimum is clamped into
        // the heap, so `6` beside `4` is `4`. A script written first is
        // already the program.
        let kept: [(String, [String])] = [
            ("zero", ["node", "--secure-heap", "0", "/usr/local/bin/codex"]),
            ("one", ["nodejs", "--secure-heap", "1", "/tmp/codex"]),
            ("two", ["node.exe", "--secure-heap", "2", "/usr/local/bin/codex"]),
            ("four", ["node", "--secure-heap=4", "/tmp/codex"]),
            ("eight", ["nodejs", "--secure-heap", "+8", "/usr/local/bin/codex"]),
            ("octal", ["node.exe", "--secure-heap", "08", "/tmp/codex"]),
            ("tail", ["node", "--secure-heap", "4abc", "/usr/local/bin/codex"]),
            ("hex", ["nodejs", "--secure-heap", "0x10", "/tmp/codex"]),
            ("space", ["node.exe", "--secure-heap", " 4", "/usr/local/bin/codex"]),
            ("eq-esc", ["node", "--secure-heap=\\-4", "/tmp/codex"]),
            ("empty", ["nodejs", "--secure-heap", "", "/usr/local/bin/codex"]),
            ("last", ["node.exe", "--secure-heap", "3", "--secure-heap", "4", "/tmp/codex"]),
            ("min-only", ["node", "--secure-heap-min", "3", "/usr/local/bin/codex"]),
            ("min-off", ["nodejs", "--secure-heap", "0", "--secure-heap-min", "3", "/tmp/codex"]),
            ("min-clamped", ["node.exe", "--secure-heap", "4", "--secure-heap-min", "6", "/usr/local/bin/codex"]),
            ("min-larger", ["node", "--secure-heap=4", "--secure-heap-min=16", "/tmp/codex"]),
            ("min-two", ["nodejs", "--secure-heap", "2", "--secure-heap-min", "3", "/usr/local/bin/codex"]),
            ("min-intmax", [
                "node.exe", "--secure-heap", "16", "--secure-heap-min", "2147483647", "/tmp/codex",
            ]),
            ("min-neg", [
                "node", "--secure-heap=8", "--secure-heap-min=-9223372036854775808",
                "/usr/local/bin/codex",
            ]),
            ("megabyte", ["nodejs", "--secure-heap", "1048576", "/tmp/codex"]),
            ("two-gig", ["node.exe", "--secure-heap", "2147483648", "/usr/local/bin/codex"]),
            ("near-zero", ["node", "--heapsnapshot-near-heap-limit", "0", "/tmp/codex"]),
            ("near-one", ["nodejs", "--heapsnapshot-near-heap-limit=1", "/usr/local/bin/codex"]),
            ("near-abc", ["node.exe", "--heapsnapshot-near-heap-limit", "abc", "/tmp/codex"]),
            ("near-trunc", ["node", "--heapsnapshot-near-heap-limit", "1.5", "/usr/local/bin/codex"]),
            ("near-plus", ["nodejs", "--heapsnapshot-near-heap-limit", "+1", "/tmp/codex"]),
            ("near-neg-zero", ["node.exe", "--heapsnapshot-near-heap-limit=-0", "/usr/local/bin/codex"]),
            ("near-eq-esc", ["node", "--heapsnapshot-near-heap-limit=\\-1", "/tmp/codex"]),
            ("near-last", [
                "nodejs", "--heapsnapshot-near-heap-limit=-1", "--heapsnapshot-near-heap-limit=2",
                "/usr/local/bin/codex",
            ]),
            ("near-overflow", [
                "node.exe", "--heapsnapshot-near-heap-limit=9223372036854775808", "/tmp/codex",
            ]),
            ("script-first", ["node", "/usr/local/bin/codex", "--secure-heap", "3"]),
            ("flag-after", ["nodejs", "--secure-heap", "4", "/tmp/codex", "--heapsnapshot-near-heap-limit=-1"]),
            ("title", ["node.exe", "--secure-heap", "4", "--title", "helper", "/usr/local/bin/codex"]),
        ]
        for (label, argv) in kept {
            let running = process(20, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([helper, running]) == 20, "\(label) dropped the script")
        }
        let leader = process(
            20,
            "node",
            argv: ["node", "--secure-heap", "4", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([mcp, leader], foregroundProcessGroupId: 20) == 20)

        let badHeap = process(
            8, "node", argv: ["node", "--secure-heap", "3", "/tmp/letta"]
        )
        let badNear = process(
            8, "nodejs", argv: ["nodejs", "--heapsnapshot-near-heap-limit=-1", "/tmp/letta"]
        )
        let keptLetta = process(
            40, "node.exe", argv: ["node.exe", "--secure-heap", "4", "/tmp/letta"]
        )
        let keptNear = process(
            40, "node", argv: ["node", "--heapsnapshot-near-heap-limit", "abc", "/tmp/letta"]
        )
        let oneShot = process(
            40,
            "nodejs",
            argv: ["nodejs", "--secure-heap", "4", "/tmp/letta", "--prompt"]
        )
        #expect(Diagnoser.cpuSamplePid([badHeap, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([badHeap, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([badNear, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([badNear, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, keptLetta]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, keptNear]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, oneShot]) == 10)
        #expect(Diagnoser.cpuSamplePid([oneShot, interactive]) == 30)

        // Bun does not take `--secure-heap`'s next word, so `3` is the
        // script and the codex path is not. An attached snapshot limit
        // is one word, and the path after it still is the script.
        // Python exits on the unknown option.
        let bunHeap = process(
            20, "bun", argv: ["bun", "--secure-heap", "3", "/usr/local/bin/codex"]
        )
        let bunNear = process(
            20, "bun", argv: ["bun", "--heapsnapshot-near-heap-limit=-1", "/usr/local/bin/codex"]
        )
        let python = process(
            4, "python3", argv: ["python3", "--secure-heap", "3", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([bunHeap]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bunHeap]) == 10)
        #expect(Diagnoser.cpuSamplePid([helper, bunNear]) == 20)
        #expect(Diagnoser.cpuSamplePid([python, claude]) == 12)
    }

    @Test("a node test-runner value the harness rejects is not the agent script")
    func nodeTestHarnessRejectionIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Node 22.23's test harness throws before the file when `--test`
        // is on and a shard, timeout, concurrency, coverage threshold,
        // or reporter list is one `parseCommandLine` / `run` reject.
        // The last scalar wins. `0` is the unset timeout and concurrency.
        let rejected: [(String, [String])] = [
            ("shard", ["node", "--test", "--test-shard", "nope", "/usr/local/bin/codex"]),
            ("shard-eq", ["nodejs", "--test", "--test-shard=0/2", "/tmp/codex"]),
            ("shard-zero", ["node.exe", "--test", "--test-shard", "0/2", "/usr/local/bin/codex"]),
            ("shard-over", ["node", "--test", "--test-shard", "2/1", "/tmp/codex"]),
            ("shard-lead", ["nodejs", "--test", "--test-shard", "00/01", "/usr/local/bin/codex"]),
            ("shard-total", ["node.exe", "--test", "--test-shard=1/00", "/tmp/codex"]),
            ("shard-plus", ["node", "--test", "--test-shard", "+1/2", "/usr/local/bin/codex"]),
            ("shard-extra", ["nodejs", "--test", "--test-shard", "1/2/3", "/tmp/codex"]),
            ("shard-space", ["node.exe", "--test", "--test-shard", "1/2 ", "/usr/local/bin/codex"]),
            ("shard-huge", [
                "node", "--test", "--test-shard", "1/9007199254740993", "/tmp/codex",
            ]),
            ("shard-esc", ["nodejs", "--test", "--test-shard", "\\-1/2", "/usr/local/bin/codex"]),
            ("shard-last", [
                "node.exe", "--test", "--test-shard", "1/1", "--test-shard", "0/2", "/tmp/codex",
            ]),
            ("shard-then-test", [
                "node", "--test-shard", "0/2", "--test", "/usr/local/bin/codex",
            ]),
            ("shard-no-then-test", [
                "nodejs", "--no-test", "--test-shard", "0/2", "--test", "/tmp/codex",
            ]),
            ("lines", [
                "nodejs", "--test", "--experimental-test-coverage", "--test-coverage-lines", "101",
                "/usr/local/bin/codex",
            ]),
            ("lines-eq", [
                "node.exe", "--test", "--experimental-test-coverage", "--test-coverage-lines=101",
                "/tmp/codex",
            ]),
            ("lines-tail", [
                "node", "--test", "--experimental-test-coverage", "--test-coverage-lines", "101abc",
                "/usr/local/bin/codex",
            ]),
            ("lines-neg", [
                "nodejs", "--test", "--experimental-test-coverage", "--test-coverage-lines=-1",
                "/tmp/codex",
            ]),
            ("lines-esc", [
                "node.exe", "--test", "--experimental-test-coverage", "--test-coverage-lines",
                "\\-1", "/usr/local/bin/codex",
            ]),
            ("lines-space", [
                "node", "--test", "--experimental-test-coverage", "--test-coverage-lines", " 101",
                "/tmp/codex",
            ]),
            ("lines-false", [
                "nodejs", "--test", "--experimental-test-coverage=false",
                "--test-coverage-lines", "101", "/usr/local/bin/codex",
            ]),
            ("lines-last", [
                "node.exe", "--test", "--experimental-test-coverage",
                "--test-coverage-lines", "50", "--test-coverage-lines", "101", "/tmp/codex",
            ]),
            ("branches", [
                "node", "--test", "--experimental-test-coverage", "--test-coverage-branches", "101",
                "/usr/local/bin/codex",
            ]),
            ("functions", [
                "nodejs", "--test", "--experimental-test-coverage",
                "--test-coverage-functions=-1", "/tmp/codex",
            ]),
            ("timeout", ["node.exe", "--test", "--test-timeout=-1", "/usr/local/bin/codex"]),
            ("timeout-esc", ["node", "--test", "--test-timeout", "\\-1", "/tmp/codex"]),
            ("timeout-max", [
                "nodejs", "--test", "--test-timeout", "2147483648", "/usr/local/bin/codex",
            ]),
            ("timeout-plus", ["node.exe", "--test", "--test-timeout=+2147483648", "/tmp/codex"]),
            ("timeout-form", [
                "node", "--test", "--test-timeout", "\u{000C}2147483648", "/usr/local/bin/codex",
            ]),
            ("timeout-last", [
                "nodejs", "--test", "--test-timeout", "1000", "--test-timeout=-1", "/tmp/codex",
            ]),
            ("concurrency", ["node.exe", "--test", "--test-concurrency=-1", "/usr/local/bin/codex"]),
            ("concurrency-esc", ["node", "--test", "--test-concurrency", "\\-1", "/tmp/codex"]),
            ("concurrency-max", [
                "nodejs", "--test", "--test-concurrency", "4294967296", "/usr/local/bin/codex",
            ]),
            ("concurrency-last", [
                "node.exe", "--test", "--test-concurrency", "1", "--test-concurrency=-1",
                "/tmp/codex",
            ]),
            ("reporters", [
                "node", "--test", "--test-reporter", "spec", "--test-reporter", "tap",
                "/usr/local/bin/codex",
            ]),
            ("destination", [
                "nodejs", "--test", "--test-reporter-destination", "stdout", "/tmp/codex",
            ]),
            ("reporter-mismatch", [
                "node.exe", "--test", "--test-reporter", "spec",
                "--test-reporter-destination", "/tmp/out", "--test-reporter", "tap",
                "/usr/local/bin/codex",
            ]),
            ("title", [
                "node", "--title", "helper", "--test", "--test-shard", "0/2", "/tmp/codex",
            ]),
        ]
        for (label, argv) in rejected {
            let exited = process(4, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([exited, claude]) == 12, "\(label) ranked the path")
            #expect(
                Diagnoser.cpuSamplePid([mcp, exited], foregroundProcessGroupId: 4) == 10,
                "\(label) took the sample from the leader slot"
            )
        }
        #expect(
            Diagnoser.cpuSamplePid([
                process(4, "node", argv: ["node", "--test", "--test-shard", "0/2", "/usr/local/bin/codex"])
            ]) == 4
        )

        // A shard in range still names the file, including `2/2`: the
        // harness accepts it. Coverage outside 0...100 is ignored while
        // the flag is off. A non-builtin reporter still names the file,
        // because the pane may be able to load that module.
        let kept: [(String, [String])] = [
            ("shard", ["node", "--test", "--test-shard", "1/2", "/usr/local/bin/codex"]),
            ("shard-one", ["nodejs", "--test", "--test-shard=1/1", "/tmp/codex"]),
            ("shard-lead", ["node.exe", "--test", "--test-shard", "01/02", "/usr/local/bin/codex"]),
            ("shard-second", ["node", "--test", "--test-shard", "2/2", "/tmp/codex"]),
            ("shard-safe", [
                "nodejs", "--test", "--test-shard", "1/9007199254740991", "/usr/local/bin/codex",
            ]),
            ("shard-last", [
                "node.exe", "--test", "--test-shard", "0/2", "--test-shard", "1/1", "/tmp/codex",
            ]),
            ("shard-off", ["node", "--test-shard", "0/2", "/usr/local/bin/codex"]),
            ("shard-no-test", ["nodejs", "--test", "--no-test", "--test-shard", "nope", "/tmp/codex"]),
            ("script-first", ["node", "/usr/local/bin/codex", "--test", "--test-shard", "0/2"]),
            ("flag-after", [
                "nodejs", "--test", "--test-shard", "1/1", "/tmp/codex", "--test-shard", "0/2",
            ]),
            ("lines-off", ["node.exe", "--test", "--test-coverage-lines", "101", "/usr/local/bin/codex"]),
            ("lines-zero", [
                "node", "--test", "--experimental-test-coverage", "--test-coverage-lines", "0",
                "/tmp/codex",
            ]),
            ("lines-hundred", [
                "nodejs", "--test", "--experimental-test-coverage", "--test-coverage-lines=100",
                "/usr/local/bin/codex",
            ]),
            ("lines-word", [
                "node.exe", "--test", "--experimental-test-coverage", "--test-coverage-lines",
                "nope", "/tmp/codex",
            ]),
            ("lines-trunc", [
                "node", "--test", "--experimental-test-coverage", "--test-coverage-lines", "100.5",
                "/usr/local/bin/codex",
            ]),
            ("lines-hex", [
                "nodejs", "--test", "--experimental-test-coverage", "--test-coverage-lines", "0x10",
                "/tmp/codex",
            ]),
            ("lines-exp", [
                "node.exe", "--test", "--experimental-test-coverage", "--test-coverage-lines", "1e2",
                "/usr/local/bin/codex",
            ]),
            ("lines-esc", [
                "node", "--test", "--experimental-test-coverage", "--test-coverage-lines=\\-1",
                "/tmp/codex",
            ]),
            ("lines-cleared", [
                "nodejs", "--test", "--experimental-test-coverage",
                "--no-experimental-test-coverage", "--test-coverage-lines", "101",
                "/usr/local/bin/codex",
            ]),
            ("lines-last", [
                "node.exe", "--test", "--experimental-test-coverage",
                "--test-coverage-lines", "101", "--test-coverage-lines", "50", "/tmp/codex",
            ]),
            ("branches", [
                "node", "--test", "--experimental-test-coverage", "--test-coverage-branches", "100",
                "/usr/local/bin/codex",
            ]),
            ("timeout-zero", ["nodejs", "--test", "--test-timeout", "0", "/tmp/codex"]),
            ("timeout-ok", ["node.exe", "--test", "--test-timeout=1000", "/usr/local/bin/codex"]),
            ("timeout-limit", ["node", "--test", "--test-timeout", "2147483647", "/tmp/codex"]),
            ("timeout-word", ["nodejs", "--test", "--test-timeout", "nope", "/usr/local/bin/codex"]),
            ("timeout-tail", ["node.exe", "--test", "--test-timeout", "10abc", "/tmp/codex"]),
            ("timeout-short", ["node", "--test", "--test-timeout", "10", "/usr/local/bin/codex"]),
            ("timeout-esc", ["nodejs", "--test", "--test-timeout=\\-1", "/tmp/codex"]),
            ("timeout-neg-zero", ["node.exe", "--test", "--test-timeout=-0", "/usr/local/bin/codex"]),
            ("timeout-plus-plus", ["node", "--test", "--test-timeout", "++1", "/tmp/codex"]),
            ("timeout-last", [
                "nodejs", "--test", "--test-timeout=-1", "--test-timeout", "1000",
                "/usr/local/bin/codex",
            ]),
            ("timeout-off", ["node.exe", "--test-timeout=-1", "/tmp/codex"]),
            ("concurrency-zero", ["node", "--test", "--test-concurrency", "0", "/usr/local/bin/codex"]),
            ("concurrency-max", [
                "nodejs", "--test", "--test-concurrency", "4294967295", "/tmp/codex",
            ]),
            ("concurrency-word", ["node.exe", "--test", "--test-concurrency", "nope", "/usr/local/bin/codex"]),
            ("concurrency-esc", ["node", "--test", "--test-concurrency=\\-1", "/tmp/codex"]),
            ("concurrency-last", [
                "nodejs", "--test", "--test-concurrency=-1", "--test-concurrency", "1",
                "/usr/local/bin/codex",
            ]),
            ("reporter-spec", ["node.exe", "--test", "--test-reporter", "spec", "/usr/local/bin/codex"]),
            ("reporter-tap", ["node", "--test", "--test-reporter=tap", "/tmp/codex"]),
            ("reporter-dot", ["nodejs", "--test", "--test-reporter", "dot", "/usr/local/bin/codex"]),
            ("reporter-junit", ["node.exe", "--test", "--test-reporter", "junit", "/tmp/codex"]),
            ("reporter-lcov", ["node", "--test", "--test-reporter", "lcov", "/usr/local/bin/codex"]),
            ("reporter-two", [
                "nodejs", "--test", "--test-reporter", "spec", "--test-reporter", "tap",
                "--test-reporter-destination", "stdout", "--test-reporter-destination", "stderr",
                "/tmp/codex",
            ]),
            ("reporter-unknown", ["node.exe", "--test", "--test-reporter", "nope", "/usr/local/bin/codex"]),
            ("title", ["node", "--test", "--test-shard", "1/1", "--title", "helper", "/tmp/codex"]),
        ]
        for (label, argv) in kept {
            let running = process(20, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([helper, running]) == 20, "\(label) dropped the script")
        }
        let leader = process(
            20,
            "node",
            argv: ["node", "--test", "--test-shard", "1/2", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([mcp, leader], foregroundProcessGroupId: 20) == 20)

        let badShard = process(
            8, "node", argv: ["node", "--test", "--test-shard", "0/2", "/tmp/letta"]
        )
        let badTimeout = process(
            8, "nodejs", argv: ["nodejs", "--test", "--test-timeout=-1", "/tmp/letta"]
        )
        let keptLetta = process(
            40, "node.exe", argv: ["node.exe", "--test", "--test-shard", "1/1", "/tmp/letta"]
        )
        let keptReporter = process(
            40, "node", argv: ["node", "--test", "--test-reporter", "spec", "/tmp/letta"]
        )
        let oneShot = process(
            40,
            "nodejs",
            argv: ["nodejs", "--test", "--test-shard", "1/1", "/tmp/letta", "--prompt"]
        )
        #expect(Diagnoser.cpuSamplePid([badShard, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([badShard, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([badTimeout, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([badTimeout, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, keptLetta]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, keptReporter]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, oneShot]) == 10)
        #expect(Diagnoser.cpuSamplePid([oneShot, interactive]) == 30)

        // Bun does not take `--test-shard`'s next word, so `0/2` is the
        // script. Python exits on the unknown option.
        let bun = process(
            20, "bun", argv: ["bun", "--test", "--test-shard", "0/2", "/usr/local/bin/codex"]
        )
        let python = process(
            4, "python3", argv: ["python3", "--test", "--test-shard", "0/2", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([bun]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bun]) == 10)
        #expect(Diagnoser.cpuSamplePid([python, claude]) == 12)
    }

    @Test("a node test pattern the regexp parser rejects is not the agent script")
    func nodeTestPatternRejectionIsNotTheScript() {
        let helper = process(10, "node", argv: ["node", "server.js"])
        let claude = process(12, "claude", argv: ["claude"])
        let mcp = process(10, "node", argv: ["node", "/tmp/mcp/bin/codex"])
        let interactive = process(30, "letta", argv: ["letta"])

        // Node 22.23 compiles every `--test-name-pattern` and
        // `--test-skip-pattern` before the file when `--test` is on.
        // `(` , `*`, a quantifier whose bounds are reversed, bad flags,
        // and a named backreference that does not exist throw there.
        // A later valid pattern does not erase an earlier throw.
        let rejected: [(String, [String])] = [
            ("paren", ["node", "--test", "--test-name-pattern", "(", "/usr/local/bin/codex"]),
            ("paren-eq", ["nodejs", "--test", "--test-name-pattern=(", "/tmp/codex"]),
            ("skip-star", ["node.exe", "--test", "--test-skip-pattern", "*", "/usr/local/bin/codex"]),
            ("skip-plus", ["node", "--test", "--test-skip-pattern=+", "/tmp/codex"]),
            ("question", ["nodejs", "--test", "--test-name-pattern", "?", "/usr/local/bin/codex"]),
            ("class", ["node.exe", "--test", "--test-name-pattern", "[", "/tmp/codex"]),
            ("trail", ["node", "--test", "--test-name-pattern", "\\", "/usr/local/bin/codex"]),
            ("order", ["nodejs", "--test", "--test-name-pattern", "a{2,1}", "/tmp/codex"]),
            ("flags", ["node.exe", "--test", "--test-name-pattern", "/foo/gg", "/usr/local/bin/codex"]),
            ("wrap", ["node", "--test", "--test-name-pattern", "/(/", "/tmp/codex"]),
            ("range", ["nodejs", "--test", "--test-name-pattern", "/[a--b]/u", "/usr/local/bin/codex"]),
            ("named", ["node.exe", "--test", "--test-name-pattern", "(?<n>a)\\k<m>", "/tmp/codex"]),
            ("close", ["node", "--test", "--test-name-pattern", ")", "/usr/local/bin/codex"]),
            ("double", ["nodejs", "--test", "--test-name-pattern", "a**", "/tmp/codex"]),
            ("both", [
                "node.exe", "--test", "--test-name-pattern", "ok",
                "--test-skip-pattern", "(", "/usr/local/bin/codex",
            ]),
            ("later", [
                "node", "--test", "--test-name-pattern", "(",
                "--test-name-pattern", "ok", "/tmp/codex",
            ]),
            ("then-test", [
                "nodejs", "--test-name-pattern", "(", "--test", "/usr/local/bin/codex",
            ]),
            ("no-then-test", [
                "node.exe", "--no-test", "--test-name-pattern", "(", "--test", "/tmp/codex",
            ]),
            ("group", ["node", "--test", "--test-name-pattern", "(?:", "/usr/local/bin/codex"]),
            ("lookbehind", ["nodejs", "--test", "--test-name-pattern", "(?<=a)*", "/tmp/codex"]),
        ]
        for (label, argv) in rejected {
            let exited = process(4, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([exited, claude]) == 12, "\(label) ranked the path")
            #expect(
                Diagnoser.cpuSamplePid([mcp, exited], foregroundProcessGroupId: 4) == 10,
                "\(label) took the sample from the leader slot"
            )
        }
        #expect(
            Diagnoser.cpuSamplePid([
                process(4, "node", argv: ["node", "--test", "--test-name-pattern", "(", "/usr/local/bin/codex"])
            ]) == 4
        )

        // A pattern Node runs still names the file. `/[a--b]/v` is a
        // unicodeSets class and is not the legacy range error.
        // `/\p{NotAThing}/u` throws in Node because the property name
        // is unknown; that database is not checked here, so the file
        // stays the script. `\-*` keeps its backslash.
        let kept: [(String, [String])] = [
            ("word", ["node", "--test", "--test-name-pattern", "ok", "/usr/local/bin/codex"]),
            ("eq", ["nodejs", "--test", "--test-name-pattern=foo", "/tmp/codex"]),
            ("flags", ["node.exe", "--test", "--test-name-pattern", "/foo/i", "/usr/local/bin/codex"]),
            ("class", ["node", "--test", "--test-name-pattern", "[a-z]+", "/tmp/codex"]),
            ("named", ["nodejs", "--test", "--test-name-pattern", "(?<n>a)\\k<n>", "/usr/local/bin/codex"]),
            ("star", ["node.exe", "--test", "--test-name-pattern", "\\-*", "/tmp/codex"]),
            ("sets", ["node", "--test", "--test-name-pattern", "/[a--b]/v", "/usr/local/bin/codex"]),
            ("property", ["nodejs", "--test", "--test-name-pattern", "/\\p{NotAThing}/u", "/tmp/codex"]),
            ("legacy-prop", ["node.exe", "--test", "--test-name-pattern", "\\p{NotAThing}", "/usr/local/bin/codex"]),
            ("off", ["node", "--test-name-pattern", "(", "/usr/local/bin/codex"]),
            ("no-test", ["nodejs", "--test", "--no-test", "--test-name-pattern", "(", "/tmp/codex"]),
            ("script-first", ["node", "/usr/local/bin/codex", "--test", "--test-name-pattern", "("]),
            ("flag-after", [
                "node.exe", "--test", "--test-name-pattern", "ok", "/tmp/codex",
                "--test-name-pattern", "(",
            ]),
            ("empty", ["nodejs", "--test", "--test-name-pattern", "", "/usr/local/bin/codex"]),
            ("skip-ok", ["node", "--test", "--test-skip-pattern", "a+", "/tmp/codex"]),
            ("quant", ["node.exe", "--test", "--test-name-pattern", "a{1,2}", "/usr/local/bin/codex"]),
            ("forward", ["nodejs", "--test", "--test-name-pattern", "\\1(a)", "/tmp/codex"]),
        ]
        for (label, argv) in kept {
            let running = process(20, argv[0], argv: argv)
            #expect(Diagnoser.cpuSamplePid([helper, running]) == 20, "\(label) dropped the script")
        }
        let leader = process(
            20,
            "node",
            argv: ["node", "--test", "--test-name-pattern", "ok", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([mcp, leader], foregroundProcessGroupId: 20) == 20)

        let badParen = process(
            8, "node", argv: ["node", "--test", "--test-name-pattern", "(", "/tmp/letta"]
        )
        let badSkip = process(
            8, "nodejs", argv: ["nodejs", "--test", "--test-skip-pattern", "*", "/tmp/letta"]
        )
        let keptLetta = process(
            40, "node.exe", argv: ["node.exe", "--test", "--test-name-pattern", "ok", "/tmp/letta"]
        )
        let keptSets = process(
            40, "node", argv: ["node", "--test", "--test-name-pattern", "/[a--b]/v", "/tmp/letta"]
        )
        let oneShot = process(
            40,
            "nodejs",
            argv: ["nodejs", "--test", "--test-name-pattern", "ok", "/tmp/letta", "--prompt"]
        )
        #expect(Diagnoser.cpuSamplePid([badParen, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([badParen, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([badSkip, interactive]) == 30)
        #expect(Diagnoser.cpuSamplePid([badSkip, claude]) == 12)
        #expect(Diagnoser.cpuSamplePid([helper, keptLetta]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, keptSets]) == 40)
        #expect(Diagnoser.cpuSamplePid([helper, oneShot]) == 10)
        #expect(Diagnoser.cpuSamplePid([oneShot, interactive]) == 30)

        // Bun does not take `--test-name-pattern`'s next word, so `(`
        // is the script. Python exits on the unknown option.
        let bun = process(
            20, "bun", argv: ["bun", "--test", "--test-name-pattern", "(", "/usr/local/bin/codex"]
        )
        let python = process(
            4, "python3", argv: ["python3", "--test", "--test-name-pattern", "(", "/usr/local/bin/codex"]
        )
        #expect(Diagnoser.cpuSamplePid([bun]) == 20)
        #expect(Diagnoser.cpuSamplePid([helper, bun]) == 10)
        #expect(Diagnoser.cpuSamplePid([python, claude]) == 12)
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
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("launcher"),
            withDestinationURL: muse
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )

        let working = Agent(id: AgentID("w1:p1"), kind: .custom("cursor"), status: .working)
        let diagnoser = Diagnoser()
        func observe(
            _ argv: [String],
            pid: Int32,
            name: String,
            cwd: String? = nil
        ) async -> ProcessGoneObservation {
            await diagnoser.observeProcessGone(
                agent: working,
                adapter: MockHerdrAdapter(processInfoResult: ProcessInfoResult(
                    shellPid: 10,
                    foregroundProcesses: [
                        ForegroundProcess(
                            pid: pid, name: name, argv0: nil, cmdline: nil, cwd: cwd,
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
        // `./agent` is the same link, joined to the cwd herdr reported
        // for this pid. A bare name is a PATH lookup, so the cwd is not
        // searched. No cwd leaves the relative path unresolved.
        let relativeCursor = await observe(
            ["sh", "./agent"], pid: 97, name: "sh", cwd: root.path
        )
        #expect(relativeCursor == .running)
        let relativeBin = await observe(
            ["/bin/bash", "bin/launcher"], pid: 98, name: "bash", cwd: root.path
        )
        #expect(relativeBin == .running)
        let relativeSuffix = await observe(
            ["pwsh", "-File", "./wrapper"], pid: 99, name: "pwsh", cwd: root.path
        )
        #expect(relativeSuffix == .running)
        let relativeSpaced = await observe(
            ["zsh", "./tool"], pid: 100, name: "zsh", cwd: root.path + "/"
        )
        #expect(relativeSpaced == .running)
        let relativeNotes = await observe(
            ["sh", "./helper"], pid: 101, name: "sh", cwd: root.path
        )
        #expect(relativeNotes == .gone(lastLine: "sh (pid 101)"))
        let relativePackage = await observe(
            ["sh", "./pi-shim"], pid: 102, name: "sh", cwd: root.path
        )
        #expect(relativePackage == .gone(lastLine: "sh (pid 102)"))
        // A bare name is not joined onto the cwd, even when that file
        // is the link above.
        let bareName = await observe(
            ["sh", "agent"], pid: 103, name: "sh", cwd: root.path
        )
        #expect(bareName == .gone(lastLine: "sh (pid 103)"))
        let noCwd = await observe(
            ["sh", "./agent"], pid: 104, name: "sh"
        )
        #expect(noCwd == .gone(lastLine: "sh (pid 104)"))
        let missing = await observe(
            ["sh", root.appendingPathComponent("missing-helper").path],
            pid: 105,
            name: "sh"
        )
        #expect(missing == .gone(lastLine: "sh (pid 105)"))
        let missingRelative = await observe(
            ["sh", "./missing-helper"], pid: 106, name: "sh", cwd: root.path
        )
        #expect(missingRelative == .gone(lastLine: "sh (pid 106)"))
        // A Windows path is not a file here, and neither is a cwd that
        // is not absolute.
        let windowsRelative = await observe(
            ["pwsh", "-File", ".\\agent"], pid: 107, name: "pwsh", cwd: root.path
        )
        #expect(windowsRelative == .gone(lastLine: "pwsh (pid 107)"))
        let relativeCwd = await observe(
            ["sh", "./agent"], pid: 108, name: "sh", cwd: "relative"
        )
        #expect(relativeCwd == .gone(lastLine: "sh (pid 108)"))
        let throughParent = await observe(
            ["sh", "sub/../agent"], pid: 109, name: "sh", cwd: root.path
        )
        #expect(throughParent == .running)
        let afterDashDash = await observe(
            ["sh", "--", "./agent"], pid: 110, name: "sh", cwd: root.path
        )
        #expect(afterDashDash == .running)
        let relativeCmd = await observe(
            ["cmd.exe", "/C", "./agent"], pid: 111, name: "cmd.exe", cwd: root.path
        )
        #expect(relativeCmd == .running)
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
