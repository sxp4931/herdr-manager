import Foundation
import Testing
@testable import HerdrManagerCore

@Suite("agent.say wait_for is checked before the prompt")
struct SayWaitTests {

    @Test("A missing wait does not look at timeout_ms")
    func missingWaitIgnoresTimeout() {
        #expect(SayWait.decide(status: nil, timeoutMs: nil) == .none)
        #expect(SayWait.decide(status: nil, timeoutMs: -1) == .none)
        #expect(SayWait.decide(status: nil, timeoutMs: 0) == .none)
        #expect(SayWait.decide(status: nil, timeoutMs: 30_000) == .none)
        #expect(SayWait.decide(status: nil, timeoutMs: 99_000) == .none)
        #expect(SayWait.rejection(.none) == nil)
    }

    @Test("Settled statuses are accepted after trim and case-folding")
    func acceptedStatuses() {
        #expect(SayWait.statusWords == "idle, done, blocked")
        #expect(SayWait.acceptedStatuses == ["idle", "done", "blocked"])
        #expect(!SayWait.acceptedStatuses.contains("working"))
        #expect(!SayWait.acceptedStatuses.contains("unknown"))

        #expect(SayWait.decide(status: "idle", timeoutMs: nil) == .wait(status: "idle", timeoutMs: SayWait.defaultTimeoutMs))
        #expect(SayWait.decide(status: " Idle ", timeoutMs: 1) == .wait(status: "idle", timeoutMs: 1))
        #expect(SayWait.decide(status: "DONE", timeoutMs: SayWait.maxTimeoutMs) == .wait(status: "done", timeoutMs: SayWait.maxTimeoutMs))
        #expect(SayWait.decide(status: "\n blocked \n", timeoutMs: nil) == .wait(status: "blocked", timeoutMs: SayWait.defaultTimeoutMs))
        #expect(SayWait.rejection(.wait(status: "idle", timeoutMs: 1)) == nil)
    }

    @Test("Blank, working, unknown, and any other word are refused")
    func refusedStatuses() {
        #expect(SayWait.decide(status: "", timeoutMs: 1) == .blankStatus)
        #expect(SayWait.decide(status: "   ", timeoutMs: 1) == .blankStatus)
        #expect(SayWait.decide(status: "\n", timeoutMs: 1) == .blankStatus)
        #expect(SayWait.decide(status: "working", timeoutMs: 1) == .unrecognizedStatus("working"))
        #expect(SayWait.decide(status: " Working ", timeoutMs: 99_000) == .unrecognizedStatus("Working"))
        #expect(SayWait.decide(status: "unknown", timeoutMs: 1) == .unrecognizedStatus("unknown"))
        #expect(SayWait.decide(status: "ready", timeoutMs: 1) == .unrecognizedStatus("ready"))
        #expect(SayWait.decide(status: "idle\"", timeoutMs: 1) == .unrecognizedStatus("idle\""))

        #expect(
            SayWait.rejection(.blankStatus)
                == "Invalid wait_for ''. Must be one of: idle, done, blocked. No input sent."
        )
        #expect(
            SayWait.rejection(.unrecognizedStatus("Working"))
                == "Invalid wait_for 'Working'. Must be one of: idle, done, blocked. No input sent."
        )
        let quoted = SayWait.rejection(.unrecognizedStatus("idle\""))
        #expect(quoted == "Invalid wait_for 'idle\"'. Must be one of: idle, done, blocked. No input sent.")
    }

    @Test("A timeout the request socket cannot outlast is refused")
    func timeoutBudget() {
        #expect(NDJSONClient.requestIOTimeoutSeconds == 30)
        #expect(SayWait.socketMarginMs == 5_000)
        #expect(SayWait.maxTimeoutMs == 25_000)
        #expect(SayWait.maxTimeoutMs == NDJSONClient.requestIOTimeoutSeconds * 1_000 - SayWait.socketMarginMs)
        #expect(SayWait.defaultTimeoutMs == SayWait.maxTimeoutMs)
        #expect(SayWait.maxTimeoutMs < NDJSONClient.requestIOTimeoutSeconds * 1_000)

        #expect(SayWait.decide(status: "idle", timeoutMs: 1) == .wait(status: "idle", timeoutMs: 1))
        #expect(SayWait.decide(status: "idle", timeoutMs: 25_000) == .wait(status: "idle", timeoutMs: 25_000))
        #expect(SayWait.decide(status: "idle", timeoutMs: 0) == .timeoutOutOfRange(0))
        #expect(SayWait.decide(status: "idle", timeoutMs: -1) == .timeoutOutOfRange(-1))
        #expect(SayWait.decide(status: "idle", timeoutMs: 25_001) == .timeoutOutOfRange(25_001))
        #expect(SayWait.decide(status: "idle", timeoutMs: 30_000) == .timeoutOutOfRange(30_000))
        #expect(SayWait.decide(status: "DONE", timeoutMs: Int.max) == .timeoutOutOfRange(Int.max))

        #expect(
            SayWait.rejection(.timeoutOutOfRange(30_000))
                == "Invalid timeout_ms 30000. Must be from 1 to 25000. No input sent."
        )
        #expect(
            SayWait.rejection(.timeoutOutOfRange(0))
                == "Invalid timeout_ms 0. Must be from 1 to 25000. No input sent."
        )
    }

    @Test("A bad status is reported ahead of a bad timeout")
    func statusWinsOverTimeout() {
        #expect(SayWait.decide(status: "working", timeoutMs: 30_000) == .unrecognizedStatus("working"))
        #expect(SayWait.decide(status: "", timeoutMs: -5) == .blankStatus)
    }

    @Test("A wait that throws after the send does not look unsent")
    func waitFailedStaysSent() {
        #expect(SayWait.outcomeToken(settled: true) == "settled")
        #expect(SayWait.outcomeToken(settled: false) == "timeout")
        #expect(SayWait.outcomeSuffix(for: SayWait.sentToken) == "\"outcome\":\"sent\"")
        #expect(SayWait.outcomeSuffix(for: SayWait.settledToken) == "\"outcome\":\"settled\"")
        #expect(SayWait.outcomeSuffix(for: SayWait.timeoutToken) == "\"outcome\":\"timeout\"")
        #expect(
            SayWait.outcomeSuffix(for: SayWait.waitFailedToken)
                == "\"outcome\":\"wait_failed\",\"waitNote\":\"prompt already sent; read the agent before sending it again\""
        )
        #expect(!SayWait.waitFailedNote.contains("\""))
        #expect(SayWait.outcomeSuffix(for: SayWait.settledToken).contains("waitNote") == false)
    }
}
