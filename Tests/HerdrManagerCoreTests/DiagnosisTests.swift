import Foundation
import Testing
@testable import HerdrManagerCore

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
