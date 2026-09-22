import Foundation
import Testing
@testable import HerdrManagerCore

@Suite("SilentAlertLedger")
struct SilentAlertLedgerTests {
    private let pane = AgentID("w1:p1")

    @Test("A silence alerts once across diagnosis passes")
    func silenceAlertsOnce() {
        var ledger = SilentAlertLedger()
        let quiet = silent(since: at(100))

        #expect(ledger.newSilences(in: [quiet]).map(\.agent.id) == [pane])
        #expect(ledger.newSilences(in: [quiet]).isEmpty)
        // The CPU reading can change between passes; it is the same silence.
        let rechecked = silent(since: at(100), cpu: .deadlocked)
        #expect(ledger.newSilences(in: [rechecked]).isEmpty)
    }

    @Test("A silence that ended in a status change does not suppress the next one")
    func statusChangeRearms() {
        // The store resets the verdict when the status changes, outside any
        // diagnosis pass. Clearing the alert only when a pass saw the
        // verdict leave silent kept this pane's key set for good.
        var ledger = SilentAlertLedger()
        #expect(ledger.newSilences(in: [silent(since: at(100))]).count == 1)

        let finished = Agent(id: pane, kind: .claude, status: .done, verdict: .healthy)
        #expect(ledger.newSilences(in: [finished]).isEmpty)

        let quietAgain = silent(since: at(900))
        let alerts = ledger.newSilences(in: [quietAgain])
        #expect(alerts.map(\.agent.id) == [pane])
        #expect(alerts.first?.since == at(900))
    }

    @Test("A later silence alerts even when no pass saw the pane in between")
    func laterSilenceAlerts() {
        var ledger = SilentAlertLedger()
        let first = ledger.newSilences(in: [silent(since: at(100))])
        let second = ledger.newSilences(in: [silent(since: at(900))])

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first.first?.episodeKey != second.first?.episodeKey)
    }

    @Test("A silence interrupted by a process-gone reading does not alert twice")
    func goneReadingDoesNotRealert() {
        var ledger = SilentAlertLedger()
        #expect(ledger.newSilences(in: [silent(since: at(100))]).count == 1)

        let gone = Agent(id: pane, kind: .claude, status: .working, verdict: .processGone(lastLine: "zsh"))
        #expect(ledger.newSilences(in: [gone]).isEmpty)
        #expect(ledger.newSilences(in: [silent(since: at(100))]).isEmpty)
    }

    @Test("A stale silent verdict on a finished, idle, or blocked pane does not alert")
    func staleSilentVerdictDoesNotAlert() {
        var ledger = SilentAlertLedger()
        let statuses: [AgentStatus] = [.done, .idle, .blocked]
        let stale = statuses.enumerated().map { index, status in
            Agent(
                id: AgentID("w1:p\(index + 2)"),
                kind: .claude,
                status: status,
                verdict: .silent(since: at(100), cpu: nil)
            )
        }
        #expect(ledger.newSilences(in: stale).isEmpty)
    }

    @Test("A pane that left the herd is forgotten")
    func departedPaneIsForgotten() {
        var ledger = SilentAlertLedger()
        let other = Agent(id: AgentID("w1:p2"), kind: .codex, status: .working, verdict: .healthy)
        #expect(ledger.newSilences(in: [silent(since: at(100)), other]).count == 1)

        #expect(ledger.newSilences(in: [other]).isEmpty)
        #expect(ledger.trackedCount == 0)
    }

    // MARK: - Fixtures

    private func silent(since: Date, cpu: CPUState? = nil) -> Agent {
        Agent(
            id: pane,
            kind: .claude,
            status: .working,
            enteredAt: at(0),
            verdict: .silent(since: since, cpu: cpu)
        )
    }

    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds)
    }
}
