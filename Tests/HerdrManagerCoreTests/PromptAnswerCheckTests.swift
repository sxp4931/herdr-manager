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
    title: String? = "Claude",
    name: String? = nil,
    terminalTitle: String? = nil,
    cwd: String? = "/tmp",
    foregroundCwd: String? = "/tmp"
) -> HerdrAgentInfo {
    HerdrAgentInfo(
        paneId: pane,
        workspaceId: "wA",
        tabId: "wA:t1",
        agent: agent,
        displayAgent: agent,
        name: name,
        title: title,
        terminalTitleStripped: terminalTitle ?? title,
        agentStatus: status,
        agentSession: session,
        focused: false,
        stateChangeSeq: seq,
        cwd: cwd,
        foregroundCwd: foregroundCwd,
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

    @Test("A different session in the same pane refuses, even at the same seq and kind")
    func replacedSessionRefuses() throws {
        let occupant = session("abc")
        let shown = try shownRow(after: herd([info(status: "blocked", seq: 5, session: occupant)]))
        let identity = "agent|claude|session|abc"
        // Same kind, still blocked, same seq. Kind does not name the occupant.
        let replaced = herd([info(status: "blocked", seq: 5, session: session("xyz"), title: "Claude")])
        #expect(
            PromptAnswerCheck.destination(answering: shown, in: replaced, sessionIdentity: identity)
                == .failure(.agentReplaced)
        )
        // The old session is also sitting on another pane. This pane still
        // runs an agent, so the keys stay here and refuse. They do not follow.
        let elsewhere = herd([
            info(status: "blocked", seq: 5, session: session("xyz")),
            info(pane: "wB:p4", status: "blocked", seq: 5, session: occupant),
        ])
        #expect(
            PromptAnswerCheck.destination(answering: shown, in: elsewhere, sessionIdentity: identity)
                == .failure(.agentReplaced)
        )
        // A value that continues with `|` is a different occupant.
        #expect(
            PromptAnswerCheck.destination(
                answering: shown,
                in: herd([info(status: "blocked", seq: 5, session: session("abc|extra"))]),
                sessionIdentity: identity
            ) == .failure(.agentReplaced)
        )
        // A re-read that drops the session is not the captured occupant.
        #expect(
            PromptAnswerCheck.destination(
                answering: shown,
                in: herd([info(status: "blocked", seq: 5)]),
                sessionIdentity: identity
            ) == .failure(.agentReplaced)
        )
    }

    @Test("The same session still in the pane may be answered, including a renamed title")
    func sameSessionPasses() throws {
        let shown = try shownRow(after: herd([
            info(status: "blocked", seq: 5, session: session("abc|extra")),
        ]))
        let identity = "agent|claude|session|abc|extra"
        #expect(
            PromptAnswerCheck.destination(
                answering: shown,
                in: herd([info(status: "blocked", seq: 5, session: session("abc|extra"), title: "Renamed")]),
                sessionIdentity: identity
            ) == .success(paneId)
        )
        // Same occupant, new episode: not "a different agent".
        #expect(
            PromptAnswerCheck.destination(
                answering: shown,
                in: herd([info(status: "working", seq: 6, session: session("abc|extra"))]),
                sessionIdentity: identity
            ) == .failure(.notBlocked(now: .working))
        )
        #expect(
            PromptAnswerCheck.destination(
                answering: shown,
                in: herd([info(status: "blocked", seq: 9, session: session("abc|extra"))]),
                sessionIdentity: identity
            ) == .failure(.promptChanged)
        )
    }

    @Test("Without a captured session, same kind and seq still pass")
    func omittedIdentityKeepsTheKindCheck() throws {
        let shown = try shownRow(after: herd([info(status: "blocked", seq: 5, session: session("abc"))]))
        #expect(
            PromptAnswerCheck.destination(
                answering: shown,
                in: herd([info(status: "blocked", seq: 5, session: session("xyz"))])
            ) == .success(paneId)
        )
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

    @Test("Approve follows the session captured before the re-read")
    func approveFollowsMovedSession() throws {
        let occupant = session("abc")
        let store = AgentStore()
        store.applyHerdSnapshot(herd([info(status: "blocked", seq: 5, session: occupant)]))
        let shown = try #require(store.agents[AgentID(paneId)])
        let captured = store.sessionIdentity(for: shown.id)
        #expect(captured == "agent|claude|session|abc")

        let moved = herd([info(pane: "wB:p4", status: "blocked", seq: 5, session: occupant)])
        #expect(
            PromptAnswerCheck.destination(answering: shown, in: moved, sessionIdentity: captured)
                == .success("wB:p4")
        )
        #expect(PromptAnswerCheck.refusal(answering: shown, in: moved, sessionIdentity: captured) == nil)
        // No captured identity, and an empty one: the new pane is someone else.
        #expect(PromptAnswerCheck.refusal(answering: shown, in: moved) == .agentGone)
        #expect(
            PromptAnswerCheck.destination(answering: shown, in: moved, sessionIdentity: "")
                == .failure(.agentGone)
        )
    }

    @Test("A move drops the old id's session, which is why Approve copies it first")
    func moveClearsSessionOnTheOldId() {
        let occupant = session("abc")
        let store = AgentStore()
        store.applyHerdSnapshot(herd([info(status: "blocked", seq: 5, session: occupant)]))
        let identity = store.sessionIdentity(for: AgentID(paneId))
        _ = store.applyEvent(.paneMoved(
            previousPaneId: paneId,
            pane: info(pane: "wB:p4", status: "blocked", seq: 0, session: occupant),
            createdWorkspaceLabel: nil,
            createdTabLabel: nil
        ))
        #expect(store.sessionIdentity(for: AgentID(paneId)) == nil)
        #expect(store.sessionIdentity(for: AgentID("wB:p4")) == identity)
    }

    @Test("The pane the row named wins when it still runs an agent")
    func samePaneWinsOverAnotherCopyOfTheSession() throws {
        let occupant = session("abc")
        let shown = try shownRow(after: herd([info(status: "blocked", seq: 5, session: occupant)]))
        let both = herd([
            info(status: "blocked", seq: 5, session: occupant),
            info(pane: "wB:p4", status: "blocked", seq: 5, session: occupant),
        ])
        #expect(
            PromptAnswerCheck.destination(
                answering: shown,
                in: both,
                sessionIdentity: "agent|claude|session|abc"
            ) == .success(paneId)
        )
    }

    @Test("Two panes with the captured session do not receive the keys")
    func ambiguousSessionRefuses() throws {
        let shown = try shownRow(after: herd([info(status: "blocked", seq: 5, session: session("abc"))]))
        let both = herd([
            info(pane: "wB:p4", status: "blocked", seq: 5, session: session("abc")),
            info(pane: "wC:p8", status: "blocked", seq: 5, session: session("abc")),
        ])
        #expect(
            PromptAnswerCheck.destination(
                answering: shown,
                in: both,
                sessionIdentity: "agent|claude|session|abc"
            ) == .failure(.agentGone)
        )
    }

    @Test("A moved session that left blocked, or changed seq, still refuses")
    func movedSessionKeepsTheEpisodeCheck() throws {
        let shown = try shownRow(after: herd([info(status: "blocked", seq: 5, session: session("abc"))]))
        let identity = "agent|claude|session|abc"
        #expect(
            PromptAnswerCheck.destination(
                answering: shown,
                in: herd([info(pane: "wB:p4", status: "working", seq: 5, session: session("abc"))]),
                sessionIdentity: identity
            ) == .failure(.notBlocked(now: .working))
        )
        #expect(
            PromptAnswerCheck.destination(
                answering: shown,
                in: herd([info(pane: "wB:p4", status: "blocked", seq: 6, session: session("abc"))]),
                sessionIdentity: identity
            ) == .failure(.promptChanged)
        )
        #expect(
            PromptAnswerCheck.destination(
                answering: shown,
                in: herd([info(pane: "wB:p4", status: "blocked", seq: 1, session: session("abc"))]),
                sessionIdentity: identity
            ) == .failure(.promptChanged)
        )
    }

    @Test("A shell left behind does not hide the moved session")
    func shellAtTheOldIdFollowsTheSession() throws {
        let shown = try shownRow(after: herd([info(status: "blocked", seq: 5, session: session("abc"))]))
        let moved = herd([
            info(agent: nil, status: "unknown", seq: 0),
            info(pane: "wB:p4", status: "blocked", seq: 5, session: session("abc")),
        ])
        #expect(
            PromptAnswerCheck.destination(
                answering: shown,
                in: moved,
                sessionIdentity: "agent|claude|session|abc"
            ) == .success("wB:p4")
        )
    }

    @Test("A followed pane of a different kind refuses")
    func followedKindMismatchRefuses() {
        let shown = Agent(
            id: AgentID(paneId),
            kind: .custom("other"),
            status: .blocked,
            stateChangeSeq: 5
        )
        #expect(
            PromptAnswerCheck.destination(
                answering: shown,
                in: herd([info(pane: "wB:p4", status: "blocked", seq: 5, session: session("abc"))]),
                sessionIdentity: "agent|claude|session|abc"
            ) == .failure(.agentReplaced)
        )
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

    @Test("An empty title is not an occupant, so the rename or terminal title is")
    func emptyTitleIsAbsent() {
        let cleared = info(
            agent: "codex", status: "blocked", seq: 1,
            title: "", name: "reviewer", terminalTitle: "Action Required"
        )
        let named = info(
            agent: "codex", status: "blocked", seq: 1,
            title: nil, name: "reviewer", terminalTitle: "Action Required"
        )
        #expect(cleared.occupantFingerprint == "fallback|codex|reviewer|wA:p1")
        #expect(cleared.occupantFingerprint == named.occupantFingerprint)

        let blankName = info(
            agent: "codex", status: "blocked", seq: 1,
            title: "", name: "", terminalTitle: "Bash"
        )
        let terminal = info(
            agent: "codex", status: "blocked", seq: 1,
            title: nil, name: nil, terminalTitle: "Bash"
        )
        #expect(blankName.occupantFingerprint == "fallback|codex|Bash|wA:p1")
        #expect(blankName.occupantFingerprint == terminal.occupantFingerprint)

        let none = info(
            agent: "codex", status: "blocked", seq: 1,
            title: "", name: "", terminalTitle: ""
        )
        #expect(none.occupantFingerprint == "fallback|codex|codex|wA:p1")

        // A real title still leads, and a session still leads over the title.
        let titled = info(
            agent: "codex", status: "blocked", seq: 1,
            title: "Review", name: "reviewer", terminalTitle: "Bash"
        )
        #expect(titled.occupantFingerprint == "fallback|codex|Review|wA:p1")
        let withSession = info(
            status: "blocked", seq: 5, session: session("abc"),
            title: "", name: "reviewer"
        )
        #expect(withSession.occupantFingerprint == "session|agent|claude|session|abc|wA:p1")
        // display_agent is set to the kind by the fixture and is not the label.
        #expect(cleared.displayAgent == "codex")
    }

    @Test("An empty session value is not an occupant, so the title is")
    func emptySessionValueUsesTheTitle() {
        let cleared = info(
            agent: "codex", status: "blocked", seq: 1,
            session: session(""), title: "Review", name: "reviewer"
        )
        let omitted = info(
            agent: "codex", status: "blocked", seq: 1,
            title: "Review", name: "reviewer"
        )
        #expect(cleared.sessionIdentity == nil)
        #expect(cleared.occupantFingerprint == "fallback|codex|Review|wA:p1")
        #expect(cleared.occupantFingerprint == omitted.occupantFingerprint)
        #expect(AnswerSendCheck.refusal(sendingTo: cleared, in: herd([omitted])) == nil)

        let otherTitle = info(
            agent: "codex", status: "blocked", seq: 1,
            session: session(""), title: "Other"
        )
        #expect(
            AnswerSendCheck.refusal(sendingTo: cleared, in: herd([otherTitle])) == .occupantChanged
        )

        // A present object whose fields were all omitted parses as empty
        // strings. That is the same occupant as no object.
        let blank = HerdrSnapshot.AgentSession(source: "", agent: "", kind: "", value: "")
        let parsed = info(
            agent: "codex", status: "blocked", seq: 1,
            session: blank, title: "Review", name: "reviewer"
        )
        #expect(parsed.occupantFingerprint == omitted.occupantFingerprint)
        #expect(AgentKind.resolved(sessionAgent: blank.agent, detected: "codex") == .custom("codex"))

        // Whitespace is still an id. Trimming it would join two values that
        // were stored as different strings.
        let spaced = info(status: "blocked", seq: 1, session: session(" "), title: "Review")
        #expect(spaced.sessionIdentity == "agent|claude|session| ")
        #expect(spaced.occupantFingerprint == "session|agent|claude|session| |wA:p1")
    }

    @Test("A cleared title still matches the rename on the re-read before the keys")
    func emptyTitleMatchesTheRename() {
        let observed = info(
            agent: "codex", status: "blocked", seq: 1,
            title: "", name: "reviewer", terminalTitle: "Action Required"
        )
        let current = info(
            agent: "codex", status: "blocked", seq: 1,
            title: nil, name: "reviewer", terminalTitle: "Action Required"
        )
        #expect(AnswerSendCheck.refusal(sendingTo: observed, in: herd([current])) == nil)

        let otherScreen = info(
            agent: "codex", status: "blocked", seq: 1,
            title: "", name: "", terminalTitle: "Other"
        )
        #expect(AnswerSendCheck.refusal(sendingTo: observed, in: herd([otherScreen])) == .occupantChanged)
    }

    @Test("An empty foreground directory is not where a new pane starts")
    func emptyForegroundDirectoryFallsThrough() {
        let foreground = info(status: "idle", seq: 1, cwd: "/work", foregroundCwd: "/front")
        #expect(foreground.workingDirectory == "/front")

        let cleared = info(status: "idle", seq: 1, cwd: "/work", foregroundCwd: "")
        #expect(cleared.workingDirectory == "/work")

        let onlyCwd = info(status: "idle", seq: 1, cwd: "/work", foregroundCwd: nil)
        #expect(onlyCwd.workingDirectory == "/work")

        let neither = info(status: "idle", seq: 1, cwd: "", foregroundCwd: "")
        #expect(neither.workingDirectory == nil)

        let missing = info(status: "idle", seq: 1, cwd: nil, foregroundCwd: nil)
        #expect(missing.workingDirectory == nil)
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

    @Test("A pane that left the agent list refuses, including the same session on a new id")
    func gonePaneRefuses() {
        // The answer cap was recorded on this pane id. Confirm-tier writes
        // follow the session; this check does not.
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

@Suite("An approved write follows a moved session")
struct ConfirmedPaneFollowTests {

    private func resolve(
        _ observed: HerdrAgentInfo,
        in agents: [HerdrAgentInfo],
        status: String? = nil,
        seq: UInt64? = nil
    ) -> Result<HerdrAgentInfo, ConfirmedPaneFollow.Refusal> {
        ConfirmedPaneFollow.resolve(
            previousPaneId: observed.paneId,
            occupantFingerprint: observed.occupantFingerprint,
            expectedStatus: status ?? observed.agentStatus,
            expectedSeq: seq ?? observed.stateChangeSeq,
            in: agents
        )
    }

    @Test("Session identity drops the pane id and ignores an empty value")
    func sessionIdentityOmitsThePane() {
        let identified = info(status: "blocked", seq: 1, session: session("abc"))
        #expect(identified.sessionIdentity == "agent|claude|session|abc")
        #expect(info(status: "blocked", seq: 1, session: session("")).sessionIdentity == nil)
        #expect(info(status: "blocked", seq: 1).sessionIdentity == nil)
    }

    @Test("The approved pane still receives the write when it is the same occupant")
    func samePanePasses() {
        let observed = info(status: "working", seq: 4, session: session("abc"))
        let renamed = info(status: "working", seq: 4, session: session("abc"), title: "renamed")
        #expect(resolve(observed, in: [renamed]) == .success(renamed))
    }

    @Test("A different occupant in the approved pane refuses, even if the session sits elsewhere")
    func samePaneDoesNotFollowAway() {
        let observed = info(status: "working", seq: 4, session: session("abc"))
        let replaced = info(status: "working", seq: 4, session: session("xyz"))
        let elsewhere = info(pane: "wB:p4", status: "working", seq: 4, session: session("abc"))
        #expect(
            resolve(observed, in: [replaced, elsewhere])
                == .failure(.occupantChanged(
                    expected: observed.occupantFingerprint,
                    current: replaced.occupantFingerprint
                ))
        )
    }

    @Test("Occupant is checked before seq when both differ")
    func occupantBeforeSeq() {
        let observed = info(status: "working", seq: 4, session: session("abc"))
        let replaced = info(status: "blocked", seq: 9, session: session("xyz"))
        #expect(
            resolve(observed, in: [replaced])
                == .failure(.occupantChanged(
                    expected: observed.occupantFingerprint,
                    current: replaced.occupantFingerprint
                ))
        )
    }

    @Test("A title change without a session still refuses on that pane")
    func fallbackTitleChangeRefuses() {
        let observed = info(agent: "codex", status: "blocked", seq: 1, title: "Review")
        let renamed = info(agent: "codex", status: "blocked", seq: 1, title: "Other")
        #expect(
            resolve(observed, in: [renamed])
                == .failure(.occupantChanged(
                    expected: observed.occupantFingerprint,
                    current: renamed.occupantFingerprint
                ))
        )
    }

    @Test("A unique session successor on the same episode receives the write")
    func followsUniqueSession() {
        let observed = info(status: "working", seq: 4, session: session("abc"))
        let moved = info(pane: "wB:p4", status: "working", seq: 4, session: session("abc"), title: "renamed")
        #expect(resolve(observed, in: [moved]) == .success(moved))
    }

    @Test("A session value that contains the separator still matches only itself")
    func sessionValueMayContainTheSeparator() {
        let occupant = session("abc|def")
        let observed = info(status: "working", seq: 4, session: occupant)
        let moved = info(pane: "wB:p4", status: "working", seq: 4, session: occupant)
        #expect(resolve(observed, in: [moved]) == .success(moved))

        let longer = info(pane: "wB:p4", status: "working", seq: 4, session: session("abc|wA:p1"))
        let plain = info(status: "working", seq: 4, session: session("abc"))
        #expect(resolve(plain, in: [longer]) == .failure(.paneGone))
    }

    @Test("A successor on a different seq or status refuses")
    func successorKeepsTheEpisode() {
        let observed = info(status: "working", seq: 4, session: session("abc"))
        #expect(
            resolve(observed, in: [info(pane: "wB:p4", status: "working", seq: 9, session: session("abc"))])
                == .failure(.seqAdvanced(expected: 4, current: 9))
        )
        #expect(
            resolve(observed, in: [info(pane: "wB:p4", status: "working", seq: 1, session: session("abc"))])
                == .failure(.seqAdvanced(expected: 4, current: 1))
        )
        #expect(
            resolve(observed, in: [info(pane: "wB:p4", status: "blocked", seq: 4, session: session("abc"))])
                == .failure(.statusChanged(expected: "working", current: "blocked"))
        )
    }

    @Test("Two successors, a fallback fingerprint, and an empty session value do not follow")
    func ambiguousOrUnidentifiedRefuses() {
        let observed = info(status: "working", seq: 4, session: session("abc"))
        #expect(
            resolve(observed, in: [
                info(pane: "wB:p4", status: "working", seq: 4, session: session("abc")),
                info(pane: "wC:p8", status: "working", seq: 4, session: session("abc")),
            ]) == .failure(.paneGone)
        )
        #expect(resolve(observed, in: []) == .failure(.paneGone))

        let fallback = info(agent: "codex", status: "working", seq: 2, title: "Review")
        let other = info(pane: "wB:p4", agent: "codex", status: "working", seq: 2, title: "Review")
        #expect(resolve(fallback, in: [other]) == .failure(.paneGone))

        let empty = info(status: "working", seq: 4, session: session(""))
        let emptyMoved = info(pane: "wB:p4", status: "working", seq: 4, session: session(""))
        #expect(resolve(empty, in: [emptyMoved]) == .failure(.paneGone))

        let titled = info(status: "working", seq: 4, session: session(""), title: "Review")
        let omitted = info(status: "working", seq: 4, title: "Review")
        #expect(resolve(titled, in: [omitted]) == .success(omitted))
        let otherTitle = info(status: "working", seq: 4, session: session(""), title: "Other")
        #expect(
            resolve(titled, in: [otherTitle])
                == .failure(.occupantChanged(
                    expected: titled.occupantFingerprint,
                    current: otherTitle.occupantFingerprint
                ))
        )
    }

    @Test("A shell is not a successor, and a shell left at the old id does not block the move")
    func shellIsNotTheOccupant() {
        let observed = info(status: "working", seq: 4, session: session("abc"))
        let shell = info(pane: "wB:p4", agent: "", status: "working", seq: 4, session: session("abc"))
        #expect(resolve(observed, in: [shell]) == .failure(.paneGone))

        let leftBehind = info(agent: "", status: "unknown", seq: 0, session: session("abc"))
        let moved = info(pane: "wB:p4", status: "working", seq: 4, session: session("abc"))
        #expect(resolve(observed, in: [leftBehind, moved]) == .success(moved))
    }

    @Test("An empty fingerprint or a missing seq skips that comparison, and an empty pane id refuses")
    func skippedComparisons() {
        let replaced = info(status: "working", seq: 9, session: session("xyz"))
        #expect(
            ConfirmedPaneFollow.resolve(
                previousPaneId: paneId,
                occupantFingerprint: "",
                expectedStatus: "working",
                expectedSeq: 9,
                in: [replaced]
            ) == .success(replaced)
        )
        #expect(
            ConfirmedPaneFollow.resolve(
                previousPaneId: paneId,
                occupantFingerprint: replaced.occupantFingerprint,
                expectedStatus: "",
                expectedSeq: nil,
                in: [info(status: "blocked", seq: 3, session: session("xyz"))]
            ) == .success(info(status: "blocked", seq: 3, session: session("xyz")))
        )
        #expect(
            ConfirmedPaneFollow.resolve(
                previousPaneId: "",
                occupantFingerprint: replaced.occupantFingerprint,
                expectedStatus: "working",
                expectedSeq: 9,
                in: [replaced]
            ) == .failure(.paneGone)
        )
    }

    @Test("A moved pane is named, and a quote in that id stays inside the JSON string")
    func resolvedAgentFieldStaysJSON() throws {
        #expect(ConfirmedPaneFollow.resolvedAgentField(nil) == "")
        #expect(ConfirmedPaneFollow.resolvedAgentField("") == "")
        #expect(ConfirmedPaneFollow.resolvedAgentField("w2:p4") == ",\"resolvedAgentId\":\"w2:p4\"")

        let quoted = "{\"sent\":true\(ConfirmedPaneFollow.resolvedAgentField("w\"2"))}"
        let quotedObject = try JSONSerialization.jsonObject(with: Data(quoted.utf8)) as? [String: Any]
        #expect(quotedObject?["sent"] as? Bool == true)
        #expect(quotedObject?["resolvedAgentId"] as? String == "w\"2")

        let slashed = "{\"closed\":true\(ConfirmedPaneFollow.resolvedAgentField("a\\b"))}"
        let slashedObject = try JSONSerialization.jsonObject(with: Data(slashed.utf8)) as? [String: Any]
        #expect(slashedObject?["resolvedAgentId"] as? String == "a\\b")

        let broken = "{\"level\":\"escape\"\(ConfirmedPaneFollow.resolvedAgentField("w2\np4\u{0001}"))}"
        let brokenObject = try JSONSerialization.jsonObject(with: Data(broken.utf8)) as? [String: Any]
        #expect(brokenObject?["resolvedAgentId"] as? String == "w2\np4\u{0001}")
        #expect(brokenObject?["level"] as? String == "escape")
    }
}

@Suite("A gated say follows the session and stays idle or done")
struct GatedSayFollowTests {

    private func resolve(
        _ observed: HerdrAgentInfo,
        in agents: [HerdrAgentInfo]
    ) -> Result<HerdrAgentInfo, GatedSayFollow.Refusal> {
        GatedSayFollow.resolve(previous: observed, in: agents)
    }

    @Test("Only idle and done auto-send")
    func autoStatuses() {
        #expect(GatedSayFollow.acceptsAutoSend(status: "idle"))
        #expect(GatedSayFollow.acceptsAutoSend(status: "done"))
        #expect(!GatedSayFollow.acceptsAutoSend(status: "working"))
        #expect(!GatedSayFollow.acceptsAutoSend(status: "blocked"))
        #expect(!GatedSayFollow.acceptsAutoSend(status: "unknown"))
    }

    @Test("The same occupant still idle or done receives the text, including a new seq")
    func sameOccupantStillAuto() {
        let idle = info(status: "idle", seq: 4, session: session("abc"))
        let later = info(status: "idle", seq: 9, session: session("abc"), title: "renamed")
        #expect(resolve(idle, in: [later]) == .success(later))

        let done = info(status: "done", seq: 4, session: session("abc"))
        let finished = info(status: "idle", seq: 4, session: session("abc"))
        #expect(resolve(done, in: [finished]) == .success(finished))
    }

    @Test("A status that left idle or done refuses, and a different occupant refuses first")
    func statusOrOccupantRefuses() {
        let idle = info(status: "idle", seq: 4, session: session("abc"))
        #expect(
            resolve(idle, in: [info(status: "working", seq: 5, session: session("abc"))])
                == .failure(.noLongerAuto(paneId: paneId, status: "working"))
        )
        #expect(
            resolve(idle, in: [info(status: "blocked", seq: 5, session: session("abc"))])
                == .failure(.noLongerAuto(paneId: paneId, status: "blocked"))
        )

        let replaced = info(status: "blocked", seq: 4, session: session("xyz"))
        let elsewhere = info(pane: "wB:p4", status: "idle", seq: 4, session: session("abc"))
        #expect(resolve(idle, in: [replaced, elsewhere]) == .failure(.occupantChanged))
    }

    @Test("A unique session that is still idle receives the text on its new pane")
    func followsIdleSession() {
        let idle = info(status: "idle", seq: 4, session: session("abc"))
        let moved = info(pane: "wB:p4", status: "idle", seq: 8, session: session("abc"), title: "renamed")
        let resolved = resolve(idle, in: [moved])
        #expect(resolved == .success(moved))
        if case .success(let followed) = resolved {
            #expect(followed.sessionIdentity == "agent|claude|session|abc")
            #expect(followed.paneId == "wB:p4")
        }

        let done = info(status: "done", seq: 4, session: session("abc"))
        let movedDone = info(pane: "wB:p4", status: "done", seq: 4, session: session("abc"))
        #expect(resolve(done, in: [movedDone]) == .success(movedDone))
    }

    @Test("A moved session that is working or blocked does not receive Enter")
    func movedOffAutoRefuses() {
        let idle = info(status: "idle", seq: 4, session: session("abc"))
        #expect(
            resolve(idle, in: [info(pane: "wB:p4", status: "blocked", seq: 4, session: session("abc"))])
                == .failure(.noLongerAuto(paneId: "wB:p4", status: "blocked"))
        )
        #expect(
            resolve(idle, in: [info(pane: "wB:p4", status: "working", seq: 4, session: session("abc"))])
                == .failure(.noLongerAuto(paneId: "wB:p4", status: "working"))
        )
    }

    @Test("A shell left at the old id does not hide the idle successor")
    func shellFollows() {
        let idle = info(status: "idle", seq: 4, session: session("abc"))
        let shell = info(agent: "", status: "unknown", seq: 0, session: session("abc"))
        let moved = info(pane: "wB:p4", status: "idle", seq: 4, session: session("abc"))
        #expect(resolve(idle, in: [shell, moved]) == .success(moved))
    }

    @Test("Two successors, a missing session, and a longer session value do not follow")
    func ambiguousDoesNotFollow() {
        let idle = info(status: "idle", seq: 4, session: session("abc"))
        #expect(
            resolve(idle, in: [
                info(pane: "wB:p4", status: "idle", seq: 4, session: session("abc")),
                info(pane: "wC:p8", status: "idle", seq: 4, session: session("abc")),
            ]) == .failure(.agentGone)
        )
        #expect(resolve(idle, in: []) == .failure(.agentGone))

        let fallback = info(agent: "codex", status: "idle", seq: 2, title: "Review")
        let other = info(pane: "wB:p4", agent: "codex", status: "idle", seq: 2, title: "Review")
        #expect(resolve(fallback, in: [other]) == .failure(.agentGone))

        let renamed = info(agent: "codex", status: "idle", seq: 2, title: "Other")
        #expect(resolve(fallback, in: [renamed]) == .failure(.occupantChanged))

        let cleared = info(
            agent: "codex", status: "idle", seq: 2,
            title: "", name: "reviewer", terminalTitle: "Action Required"
        )
        let same = info(
            agent: "codex", status: "idle", seq: 9,
            title: nil, name: "reviewer", terminalTitle: "Action Required"
        )
        #expect(resolve(cleared, in: [same]) == .success(same))

        let empty = info(status: "idle", seq: 4, session: session(""))
        #expect(
            resolve(empty, in: [info(pane: "wB:p4", status: "idle", seq: 4, session: session(""))])
                == .failure(.agentGone)
        )
        let titled = info(status: "idle", seq: 4, session: session(""), title: "Review")
        let omitted = info(status: "idle", seq: 4, title: "Review")
        #expect(resolve(titled, in: [omitted]) == .success(omitted))
        let otherTitle = info(status: "idle", seq: 4, session: session(""), title: "Other")
        #expect(resolve(titled, in: [otherTitle]) == .failure(.occupantChanged))

        let longer = info(pane: "wB:p4", status: "idle", seq: 4, session: session("abc|extra"))
        #expect(resolve(idle, in: [longer]) == .failure(.agentGone))

        let withBar = session("abc|def")
        let observed = info(status: "idle", seq: 4, session: withBar)
        let moved = info(pane: "wB:p4", status: "idle", seq: 4, session: withBar)
        #expect(resolve(observed, in: [moved]) == .success(moved))
    }

    @Test("A re-read that drops the session, and an empty pane id, refuse")
    func omittedSessionAndEmptyPane() {
        let idle = info(status: "idle", seq: 4, session: session("abc"))
        let omitted = info(status: "idle", seq: 4)
        #expect(resolve(idle, in: [omitted]) == .failure(.occupantChanged))
        #expect(
            GatedSayFollow.resolve(previous: info(pane: "", status: "idle", seq: 1), in: [idle])
                == .failure(.agentGone)
        )
    }
}
