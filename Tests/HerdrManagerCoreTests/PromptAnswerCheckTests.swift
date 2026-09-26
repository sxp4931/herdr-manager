import Foundation
import Testing
@testable import HerdrManagerCore

// MARK: - Fixtures

private let paneId = "wA:p1"

private func session(_ value: String, agent: String = "claude") -> HerdrSnapshot.AgentSession {
    HerdrSnapshot.AgentSession(source: "agent", agent: agent, kind: "session", value: value)
}

private func info(
    pane: String = paneId,
    agent: String? = "claude",
    status: String,
    seq: UInt64,
    session: HerdrSnapshot.AgentSession? = nil,
    title: String? = "Claude"
) -> HerdrAgentInfo {
    HerdrAgentInfo(
        paneId: pane,
        workspaceId: "wA",
        tabId: "wA:t1",
        agent: agent,
        displayAgent: agent,
        name: nil,
        title: title,
        terminalTitleStripped: title,
        agentStatus: status,
        agentSession: session,
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

@Suite("agent.answer re-reads the prompt before sending keys")
struct AnswerSendCheckTests {

    @Test("The occupant fingerprint is the pending-action identity")
    func fingerprintFormat() {
        let withSession = info(status: "blocked", seq: 5, session: session("abc"))
        #expect(withSession.occupantFingerprint == "session|agent|claude|session|abc|wA:p1")

        let titled = info(agent: "codex", status: "blocked", seq: 1, title: "Review")
        #expect(titled.occupantFingerprint == "fallback|codex|Review|wA:p1")

        let unnamed = info(agent: nil, status: "blocked", seq: 1, title: nil)
        #expect(unnamed.occupantFingerprint == "fallback|unknown|unknown|wA:p1")
    }

    @Test("A prompt still blocked on the same episode and occupant may be answered")
    func sameEpisodePasses() {
        let observed = info(status: "blocked", seq: 5, session: session("abc"))
        let current = info(status: "blocked", seq: 5, session: session("abc"), title: "Claude — waiting")
        #expect(AnswerSendCheck.refusal(sendingTo: observed, in: herd([current])) == nil)
    }

    @Test("A prompt answered during explain refuses")
    func answeredDuringExplainRefuses() {
        let observed = info(status: "blocked", seq: 5, session: session("abc"))
        let refusal = AnswerSendCheck.refusal(
            sendingTo: observed,
            in: herd([info(status: "working", seq: 6, session: session("abc"))])
        )
        #expect(refusal == .notBlocked(now: "working"))
    }

    @Test("A later prompt, or a herdr restart, refuses")
    func seqChangeRefuses() {
        let observed = info(status: "blocked", seq: 5, session: session("abc"))
        #expect(
            AnswerSendCheck.refusal(
                sendingTo: observed,
                in: herd([info(status: "blocked", seq: 7, session: session("abc"))])
            ) == .promptChanged(currentSeq: 7)
        )
        #expect(
            AnswerSendCheck.refusal(
                sendingTo: observed,
                in: herd([info(status: "blocked", seq: 1, session: session("abc"))])
            ) == .promptChanged(currentSeq: 1)
        )
    }

    @Test("A pane that left the agent list refuses")
    func gonePaneRefuses() {
        let observed = info(status: "blocked", seq: 5, session: session("abc"))
        #expect(AnswerSendCheck.refusal(sendingTo: observed, in: herd([])) == .agentGone)
        #expect(
            AnswerSendCheck.refusal(
                sendingTo: observed,
                in: herd([info(pane: "wA:p9", status: "blocked", seq: 5, session: session("abc"))])
            ) == .agentGone
        )
    }

    @Test("A different session in the same pane refuses, even at the same seq")
    func replacedSessionRefuses() {
        let observed = info(status: "blocked", seq: 5, session: session("abc"))
        let refusal = AnswerSendCheck.refusal(
            sendingTo: observed,
            in: herd([info(status: "blocked", seq: 5, session: session("xyz"))])
        )
        #expect(refusal == .occupantChanged)
    }

    @Test("Without a session id, a different agent kind refuses")
    func replacedKindRefuses() {
        let observed = info(status: "blocked", seq: 5)
        let refusal = AnswerSendCheck.refusal(
            sendingTo: observed,
            in: herd([info(agent: "codex", status: "blocked", seq: 5)])
        )
        #expect(refusal == .occupantChanged)
    }
}
