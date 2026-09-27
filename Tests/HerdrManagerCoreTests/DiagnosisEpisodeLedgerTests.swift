import Foundation
import Testing
@testable import HerdrManagerCore

private func session(_ value: String) -> HerdrSnapshot.AgentSession {
    HerdrSnapshot.AgentSession(source: "agent", agent: "claude", kind: "session", value: value)
}

private func info(
    pane: String,
    status: String,
    seq: UInt64,
    session: HerdrSnapshot.AgentSession? = nil,
    agent: String? = "claude"
) -> HerdrAgentInfo {
    HerdrAgentInfo(
        paneId: pane,
        workspaceId: "wA",
        tabId: "wA:t1",
        agent: agent,
        displayAgent: agent,
        name: nil,
        title: "Claude",
        terminalTitleStripped: nil,
        agentStatus: status,
        agentSession: session,
        focused: false,
        stateChangeSeq: seq,
        cwd: nil,
        foregroundCwd: nil,
        revision: nil,
        tokens: [:],
        stateLabels: [:],
        interactiveReady: true,
        launchPending: false
    )
}

@Suite("MCP diagnosis keeps the episode it already saw")
struct DiagnosisEpisodeLedgerTests {

    @Test("A later read of the same episode keeps the first clock")
    func sameEpisodeKeepsEnteredAt() {
        var ledger = DiagnosisEpisodeLedger()
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_600)
        let agent = info(pane: "wA:p1", status: "blocked", seq: 5, session: session("abc"))
        let opened = ledger.observe([agent], now: first)
        let again = ledger.observe([agent], now: later)
        #expect(opened.moves.isEmpty)
        #expect(again.moves.isEmpty)
        #expect(again.enteredAt[AgentID("wA:p1")] == first)
    }

    @Test("A status change, a seq change, and a different session each start a clock")
    func newEpisodeResets() {
        var ledger = DiagnosisEpisodeLedger()
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_600)
        _ = ledger.observe(
            [info(pane: "wA:p1", status: "blocked", seq: 5, session: session("abc"))],
            now: first
        )
        let status = ledger.observe(
            [info(pane: "wA:p1", status: "working", seq: 5, session: session("abc"))],
            now: later
        )
        #expect(status.enteredAt[AgentID("wA:p1")] == later)

        let seq = ledger.observe(
            [info(pane: "wA:p1", status: "working", seq: 6, session: session("abc"))],
            now: first
        )
        #expect(seq.enteredAt[AgentID("wA:p1")] == first)

        let occupant = ledger.observe(
            [info(pane: "wA:p1", status: "working", seq: 6, session: session("xyz"))],
            now: later
        )
        #expect(occupant.enteredAt[AgentID("wA:p1")] == later)
        #expect(occupant.moves.isEmpty)
    }

    @Test("Learning the session, or a read that omits it, does not open a new episode")
    func sessionAppearanceDoesNotReset() {
        var ledger = DiagnosisEpisodeLedger()
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_600)
        _ = ledger.observe([info(pane: "wA:p1", status: "blocked", seq: 5)], now: first)
        let named = ledger.observe(
            [info(pane: "wA:p1", status: "blocked", seq: 5, session: session("abc"))],
            now: later
        )
        #expect(named.enteredAt[AgentID("wA:p1")] == first)
        let omitted = ledger.observe(
            [info(pane: "wA:p1", status: "blocked", seq: 5)],
            now: later
        )
        #expect(omitted.enteredAt[AgentID("wA:p1")] == first)
        let moved = ledger.observe(
            [info(pane: "wB:p4", status: "blocked", seq: 5, session: session("abc"))],
            now: later
        )
        #expect(moved.moves == [AgentID("wA:p1"): AgentID("wB:p4")])
        #expect(moved.enteredAt[AgentID("wB:p4")] == first)
    }

    @Test("One pane leaving and one pane arriving with that session keeps the clock")
    func uniqueSessionMoveKeepsEnteredAt() {
        var ledger = DiagnosisEpisodeLedger()
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_600)
        _ = ledger.observe(
            [
                info(pane: "wA:p1", status: "blocked", seq: 5, session: session("abc")),
                info(pane: "wA:p2", status: "working", seq: 2, session: session("other")),
            ],
            now: first
        )
        let moved = ledger.observe(
            [
                info(pane: "wB:p4", status: "blocked", seq: 5, session: session("abc")),
                info(pane: "wA:p2", status: "working", seq: 2, session: session("other")),
            ],
            now: later
        )
        #expect(moved.moves == [AgentID("wA:p1"): AgentID("wB:p4")])
        #expect(moved.enteredAt[AgentID("wB:p4")] == first)
        #expect(moved.enteredAt[AgentID("wA:p2")] == first)
        #expect(moved.enteredAt[AgentID("wA:p1")] == nil)
    }

    @Test("A moved session whose seq went backwards starts a new clock and does not retarget")
    func restartedMoveDoesNotContinue() {
        var ledger = DiagnosisEpisodeLedger()
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_600)
        _ = ledger.observe(
            [info(pane: "wA:p1", status: "blocked", seq: 9, session: session("abc"))],
            now: first
        )
        let restarted = ledger.observe(
            [info(pane: "wB:p4", status: "blocked", seq: 1, session: session("abc"))],
            now: later
        )
        #expect(restarted.moves.isEmpty)
        #expect(restarted.enteredAt[AgentID("wB:p4")] == later)
    }

    @Test("Two panes with one session, an empty session, and a longer session value do not continue")
    func ambiguousSessionsDoNotMove() {
        var ledger = DiagnosisEpisodeLedger()
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_600)
        _ = ledger.observe(
            [
                info(pane: "wA:p1", status: "blocked", seq: 5, session: session("abc")),
                info(pane: "wA:p2", status: "blocked", seq: 5, session: session("abc")),
            ],
            now: first
        )
        let split = ledger.observe(
            [info(pane: "wB:p4", status: "blocked", seq: 5, session: session("abc"))],
            now: later
        )
        #expect(split.moves.isEmpty)
        #expect(split.enteredAt[AgentID("wB:p4")] == later)

        _ = ledger.observe(
            [info(pane: "wA:p1", status: "working", seq: 3, session: session(""))],
            now: first
        )
        let empty = ledger.observe(
            [info(pane: "wB:p9", status: "working", seq: 3, session: session(""))],
            now: later
        )
        #expect(empty.moves.isEmpty)
        #expect(empty.enteredAt[AgentID("wB:p9")] == later)

        _ = ledger.observe(
            [info(pane: "wA:p1", status: "working", seq: 4, session: session("abc"))],
            now: first
        )
        let longer = ledger.observe(
            [info(pane: "wB:p4", status: "working", seq: 4, session: session("abc|extra"))],
            now: later
        )
        #expect(longer.moves.isEmpty)
        #expect(longer.enteredAt[AgentID("wB:p4")] == later)
    }

    @Test("A pane that leaves is forgotten, and a shell is not an episode")
    func departureAndShell() {
        var ledger = DiagnosisEpisodeLedger()
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_600)
        _ = ledger.observe(
            [info(pane: "wA:p1", status: "blocked", seq: 5, session: session("abc"))],
            now: first
        )
        let gone = ledger.observe(
            [info(pane: "wA:p2", status: "working", seq: 1, session: session("other"), agent: nil)],
            now: later
        )
        #expect(gone.enteredAt.isEmpty)
        let back = ledger.observe(
            [info(pane: "wA:p1", status: "blocked", seq: 5, session: session("abc"))],
            now: later
        )
        #expect(back.enteredAt[AgentID("wA:p1")] == later)
        #expect(back.moves.isEmpty)
    }

    @Test("Silence is timed from a detection baseline, not from a screen that was never read")
    func outputDateNeedsABaseline() {
        let now = Date(timeIntervalSince1970: 2_000)
        let baseline = Date(timeIntervalSince1970: 1_000)
        #expect(DiagnosisEpisodeLedger.outputDate(for: .working, baseline: baseline, now: now) == baseline)
        #expect(DiagnosisEpisodeLedger.outputDate(for: .working, baseline: nil, now: now) == now)
        #expect(DiagnosisEpisodeLedger.outputDate(for: .blocked, baseline: baseline, now: now) == nil)
        #expect(DiagnosisEpisodeLedger.outputDate(for: .idle, baseline: nil, now: now) == nil)
    }
}
