import Foundation
import Testing
@testable import HerdrManagerCore

// MARK: - Fixtures

private let paneId = "wA:p1"

private func info(
    agent: String? = "claude",
    status: String,
    seq: UInt64
) -> HerdrAgentInfo {
    HerdrAgentInfo(
        paneId: paneId,
        workspaceId: "wA",
        tabId: "wA:t1",
        agent: agent,
        displayAgent: agent,
        name: nil,
        title: "Claude",
        terminalTitleStripped: "Claude",
        agentStatus: status,
        agentSession: nil,
        focused: false,
        stateChangeSeq: seq,
        cwd: "/tmp",
        foregroundCwd: "/tmp",
        revision: 1,
        tokens: [:],
        stateLabels: [:],
        interactiveReady: true,
        launchPending: false
    )
}

private func herd(_ agents: [HerdrAgentInfo]) -> HerdSnapshot {
    HerdSnapshot(
        version: "0.7.5",
        protocol: 17,
        agents: agents,
        workspaceNames: ["wA": "Work"],
        tabNames: ["wA:t1": "Claude"],
        focusedWorkspaceId: nil,
        focusedTabId: nil,
        focusedPaneId: nil
    )
}

/// The row the panel would render after `snapshot`.
@MainActor
private func shownRow(after snapshot: HerdSnapshot) throws -> Agent {
    let store = AgentStore()
    store.applyHerdSnapshot(snapshot)
    return try #require(store.agents[AgentID(paneId)])
}

// MARK: - Tests

@Suite("Panel Approve/Deny re-check the prompt before sending keys")
@MainActor
struct PromptAnswerCheckTests {

    @Test("A prompt still waiting on the same episode may be answered")
    func sameEpisodePasses() throws {
        let snapshot = herd([info(status: "blocked", seq: 5)])
        let shown = try shownRow(after: snapshot)
        #expect(shown.verdict.isAwaitingInput)
        #expect(PromptAnswerCheck.refusal(answering: shown, in: snapshot) == nil)
    }

    @Test("A prompt answered in the terminal refuses, so Esc cannot interrupt the work")
    func answeredElsewhereRefuses() throws {
        let shown = try shownRow(after: herd([info(status: "blocked", seq: 5)]))
        let refusal = PromptAnswerCheck.refusal(
            answering: shown,
            in: herd([info(status: "working", seq: 6)])
        )
        #expect(refusal == .notBlocked(now: .working))
        #expect(refusal?.message.contains("now working") == true)
    }

    @Test("A later prompt refuses, so Enter cannot accept a prompt the row never showed")
    func laterPromptRefuses() throws {
        let shown = try shownRow(after: herd([info(status: "blocked", seq: 5)]))
        let refusal = PromptAnswerCheck.refusal(
            answering: shown,
            in: herd([info(status: "blocked", seq: 7)])
        )
        #expect(refusal == .promptChanged)
    }

    @Test("A herdr restart restarts seq, which refuses")
    func restartedSeqRefuses() throws {
        let shown = try shownRow(after: herd([info(status: "blocked", seq: 5)]))
        let refusal = PromptAnswerCheck.refusal(
            answering: shown,
            in: herd([info(status: "blocked", seq: 1)])
        )
        #expect(refusal == .promptChanged)
    }

    @Test("A closed pane, or one back to a plain shell, refuses")
    func goneAgentRefuses() throws {
        let shown = try shownRow(after: herd([info(status: "blocked", seq: 5)]))
        #expect(PromptAnswerCheck.refusal(answering: shown, in: herd([])) == .agentGone)
        #expect(
            PromptAnswerCheck.refusal(
                answering: shown,
                in: herd([info(agent: nil, status: "blocked", seq: 5)])
            ) == .agentGone
        )
    }

    @Test("A different agent in the same pane refuses")
    func replacedAgentRefuses() throws {
        let shown = try shownRow(after: herd([info(status: "blocked", seq: 5)]))
        let refusal = PromptAnswerCheck.refusal(
            answering: shown,
            in: herd([info(agent: "codex", status: "blocked", seq: 5)])
        )
        #expect(refusal == .agentReplaced)
    }

    @Test("A row blocked by a seq-less status event refuses once, then passes after the fresh snapshot is applied")
    func seqlessEventRefusesUntilApplied() throws {
        let store = AgentStore()
        store.applyHerdSnapshot(herd([info(status: "working", seq: 4)]))
        // herdr's status event carries no seq: the row turns blocked but
        // keeps the working episode's seq.
        _ = store.applyEvent(.agentStatusChanged(paneId: paneId, agentStatus: "blocked", stateChangeSeq: nil))
        let lagging = try #require(store.agents[AgentID(paneId)])
        #expect(lagging.verdict.isAwaitingInput)
        #expect(lagging.stateChangeSeq == 4)

        let fresh = herd([info(status: "blocked", seq: 5)])
        #expect(PromptAnswerCheck.refusal(answering: lagging, in: fresh) == .promptChanged)

        // What the app does on refusal: apply the snapshot it just read.
        store.applyHerdSnapshot(fresh)
        let refreshed = try #require(store.agents[AgentID(paneId)])
        #expect(refreshed.verdict.isAwaitingInput)
        #expect(PromptAnswerCheck.refusal(answering: refreshed, in: fresh) == nil)
    }
}
