import Foundation
import Testing
@testable import HerdrManagerCore

private func makeDwellAgentInfo(
    paneId: String,
    workspaceId: String = "wA",
    tabId: String = "wA:t1",
    agent: String? = "claude",
    agentStatus: String = "working",
    stateChangeSeq: UInt64 = 1,
    session: HerdrSnapshot.AgentSession? = nil
) -> HerdrAgentInfo {
    HerdrAgentInfo(
        paneId: paneId,
        workspaceId: workspaceId,
        tabId: tabId,
        agent: agent,
        displayAgent: "claude",
        name: nil,
        title: "Claude",
        terminalTitleStripped: "Claude",
        agentStatus: agentStatus,
        agentSession: session,
        focused: false,
        stateChangeSeq: stateChangeSeq,
        cwd: "/tmp",
        foregroundCwd: "/tmp",
        revision: 1,
        tokens: [:],
        stateLabels: [:],
        interactiveReady: true,
        launchPending: false
    )
}

@Suite("HerdSnapshot dwell preservation")
struct HerdSnapshotDwellTests {
    @Test("displayAgents(preserving:) keeps dwell across a label-only refetch")
    func displayAgentsPreservesEnteredAtForUnchangedEpisodes() {
        func snapshot(_ infos: [HerdrAgentInfo]) -> HerdSnapshot {
            HerdSnapshot(
                version: "0.7.5", protocol: 17,
                agents: infos,
                workspaceNames: ["wA": "Cuedora"], tabNames: ["wA:t1": "Claude"],
                focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
            )
        }

        let before = snapshot([
            makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 5),
            makeDwellAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 7)
        ]).displayAgents(now: Date(timeIntervalSince1970: 1_000))

        let after = snapshot([
            makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 5),
            makeDwellAgentInfo(paneId: "wA:p2", agentStatus: "done", stateChangeSeq: 8),
            makeDwellAgentInfo(paneId: "wA:p3", agentStatus: "working", stateChangeSeq: 1)
        ]).displayAgents(preserving: before, now: Date(timeIntervalSince1970: 9_000))

        let byId = Dictionary(after.map { ($0.id.raw, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byId["wA:p1"]?.enteredAt == Date(timeIntervalSince1970: 1_000))
        #expect(byId["wA:p2"]?.enteredAt == Date(timeIntervalSince1970: 9_000))
        #expect(byId["wA:p3"]?.enteredAt == Date(timeIntervalSince1970: 9_000))
        #expect(byId["wA:p2"]?.status == .done)
    }

    @Test("A same-episode refetch keeps a crash, and a status change does not")
    func displayAgentsPreservesProcessGoneForUnchangedEpisodes() {
        func snapshot(_ infos: [HerdrAgentInfo]) -> HerdSnapshot {
            HerdSnapshot(
                version: "0.7.5", protocol: 17,
                agents: infos,
                workspaceNames: ["wA": "Cuedora"], tabNames: ["wA:t1": "Claude"],
                focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
            )
        }

        var before = snapshot([
            makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 5),
            makeDwellAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 7)
        ]).displayAgents(now: Date(timeIntervalSince1970: 1_000))
        before[0].verdict = .processGone(lastLine: "zsh (pid 1)")
        before[1].verdict = .processGone(lastLine: "zsh (pid 2)")

        let after = snapshot([
            makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 5),
            makeDwellAgentInfo(paneId: "wA:p2", agentStatus: "done", stateChangeSeq: 8)
        ]).displayAgents(preserving: before, now: Date(timeIntervalSince1970: 9_000))

        let byId = Dictionary(after.map { ($0.id.raw, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byId["wA:p1"]?.verdict == .processGone(lastLine: "zsh (pid 1)"))
        #expect(byId["wA:p2"]?.verdict.isProcessGone == false)
        #expect(byId["wA:p2"]?.status == .done)
    }

    @Test("Without a session map the dwell stays, and a different stored session drops it")
    func differentSessionDoesNotPreserveDwell() {
        func snapshot(_ infos: [HerdrAgentInfo]) -> HerdSnapshot {
            HerdSnapshot(
                version: "0.7.5", protocol: 17,
                agents: infos,
                workspaceNames: ["wA": "Cuedora"], tabNames: ["wA:t1": "Claude"],
                focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
            )
        }
        let started = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 9_000)
        let same = HerdrSnapshot.AgentSession(source: "agent", agent: "claude", kind: "session", value: "abc")
        let other = HerdrSnapshot.AgentSession(source: "agent", agent: "claude", kind: "session", value: "abc|extra")
        let before = snapshot([
            makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: same)
        ]).displayAgents(now: started)
        let next = snapshot([
            makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: other)
        ])
        // A caller that has not tracked sessions still preserves. The map is
        // what makes the two values a replacement.
        let untracked = next.displayAgents(preserving: before, now: later)
        #expect(untracked.first?.enteredAt == started)
        let kept = next.displayAgents(
            preserving: before,
            sessions: ["wA:p1": "agent|claude|session|abc"],
            now: later
        )
        #expect(kept.first?.enteredAt == later)
        #expect(kept.first?.verdict.isProcessGone == false)
    }
}

@Suite("HerdLiveTable layout refetch and pane move")
struct HerdLiveTableDwellTests {
    private let started = Date(timeIntervalSince1970: 1_000)
    private let refreshedAt = Date(timeIntervalSince1970: 9_000)
    private let moveAt = Date(timeIntervalSince1970: 9_500)

    private func snapshot(
        _ infos: [HerdrAgentInfo],
        workspaces: [String: String] = ["wA": "Cuedora"],
        tabs: [String: String] = ["wA:t1": "main"]
    ) -> HerdSnapshot {
        HerdSnapshot(
            version: "0.7.5", protocol: 17,
            agents: infos,
            workspaceNames: workspaces, tabNames: tabs,
            focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
        )
    }

    private func initialTable() -> HerdLiveTable {
        let herd = snapshot([
            makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5),
            makeDwellAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 3)
        ])
        return HerdLiveTable(herd: herd, agents: herd.displayAgents(now: started))
    }

    /// The refetch herdmgr does when herdr emits the layout event that
    /// precedes a cross-workspace move. The new id is already in the list.
    private func refreshAfterMove(on live: inout HerdLiveTable, seq: UInt64 = 5, at now: Date) {
        live.noteLayoutRefresh(
            snapshot(
                [
                    makeDwellAgentInfo(
                        paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t1",
                        agentStatus: "blocked", stateChangeSeq: seq
                    ),
                    makeDwellAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 3)
                ],
                workspaces: ["wA": "Cuedora", "wB": "proj"],
                tabs: ["wA:t1": "main", "wB:t1": "scratch"]
            ),
            now: now
        )
    }

    private func moveEvent(seq: UInt64 = 0, status: String = "working") -> HerdrEvent {
        .paneMoved(
            previousPaneId: "wA:p1",
            pane: makeDwellAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t1",
                agentStatus: status, stateChangeSeq: seq
            ),
            createdWorkspaceLabel: "from-event",
            createdTabLabel: "from-event-tab"
        )
    }

    @Test("A layout refetch adopts the new pane id, and pane.moved puts the dwell back")
    func moveAfterLayoutRefreshKeepsDwell() {
        var live = initialTable()
        refreshAfterMove(on: &live, at: refreshedAt)

        let ids = live.agents.map(\.id.raw)
        #expect(ids == ["wB:p4", "wA:p2"])
        #expect(live.agents.first?.enteredAt == refreshedAt)

        live.apply(moveEvent(), now: moveAt)

        #expect(live.agents.map(\.id.raw) == ["wB:p4", "wA:p2"])
        guard live.agents.count == 2 else { return }
        #expect(live.agents[0].status == .blocked)
        #expect(live.agents[0].stateChangeSeq == 5)
        #expect(live.agents[0].enteredAt == started)
        #expect(live.agents[0].workspaceName == "proj")
        #expect(live.agents[0].tabName == "scratch")
        #expect(live.agents[1].id.raw == "wA:p2")
        #expect(live.agents[1].enteredAt == started)
    }

    @Test("pane.moved puts a pre-refetch crash back on the new id")
    func moveAfterLayoutRefreshKeepsProcessGone() {
        var live = initialTable()
        live.applyProcessGone([
            AgentID("wA:p1"): .gone(lastLine: "zsh (pid 4)")
        ], now: started)
        refreshAfterMove(on: &live, at: refreshedAt)

        // The refetch is already on the new id, which herdr still calls blocked.
        #expect(live.agents.first?.id.raw == "wB:p4")
        #expect(live.agents.first?.verdict.isProcessGone == false)

        live.apply(moveEvent(), now: moveAt)

        #expect(live.agents.first?.id.raw == "wB:p4")
        #expect(live.agents.first?.status == .blocked)
        #expect(live.agents.first?.enteredAt == started)
        #expect(live.agents.first?.verdict == .processGone(lastLine: "zsh (pid 4)"))
        #expect(live.agents.dropFirst().first?.verdict.isProcessGone == false)
    }

    @Test("A second layout refetch in the burst does not replace the remembered dwell")
    func secondRefreshDoesNotReplaceRememberedRows() {
        var live = initialTable()
        refreshAfterMove(on: &live, at: refreshedAt)
        refreshAfterMove(on: &live, at: Date(timeIntervalSince1970: 9_200))
        live.apply(moveEvent(), now: moveAt)

        #expect(live.agents.first?.id.raw == "wB:p4")
        #expect(live.agents.first?.enteredAt == started)
    }

    @Test("Focus between the refetch and the move still restores the dwell")
    func focusDoesNotDropRememberedRows() {
        var live = initialTable()
        refreshAfterMove(on: &live, at: refreshedAt)
        live.apply(.paneFocused(paneId: "wB:p4", workspaceId: "wB"), now: refreshedAt)
        live.apply(moveEvent(), now: moveAt)

        #expect(live.agents.first?.enteredAt == started)
        #expect(live.agents.first?.status == .blocked)
    }

    @Test("A seq-less update that leaves the episode alone still restores")
    func sameStatusUpdateDoesNotDropRememberedRows() {
        var live = initialTable()
        refreshAfterMove(on: &live, at: refreshedAt)
        let updateAt = Date(timeIntervalSince1970: 9_200)
        live.apply(
            .paneUpdated(makeDwellAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t1",
                agentStatus: "blocked", stateChangeSeq: 0
            )),
            now: updateAt
        )
        #expect(live.agents.first?.status == .blocked)
        #expect(live.agents.first?.stateChangeSeq == 5)
        #expect(live.agents.first?.enteredAt == refreshedAt)

        live.apply(moveEvent(), now: moveAt)
        #expect(live.agents.first?.enteredAt == started)
        #expect(live.agents.first?.status == .blocked)
    }

    @Test("A seq-less status change before the move drops the remembered dwell")
    func statusChangeDropsRememberedRows() {
        var live = initialTable()
        refreshAfterMove(on: &live, at: refreshedAt)
        let statusAt = Date(timeIntervalSince1970: 9_300)
        live.apply(
            .paneUpdated(makeDwellAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t1",
                agentStatus: "working", stateChangeSeq: 0
            )),
            now: statusAt
        )
        live.apply(moveEvent(), now: moveAt)

        #expect(live.agents.first?.id.raw == "wB:p4")
        #expect(live.agents.first?.status == .working)
        #expect(live.agents.first?.stateChangeSeq == 5)
        #expect(live.agents.first?.enteredAt == statusAt)
    }

    @Test("A refetch whose seq moved on is a new episode and stays one")
    func seqBumpIsNotRestored() {
        var live = initialTable()
        refreshAfterMove(on: &live, seq: 6, at: refreshedAt)
        live.apply(moveEvent(), now: moveAt)

        #expect(live.agents.first?.stateChangeSeq == 6)
        #expect(live.agents.first?.enteredAt == refreshedAt)
        #expect(live.agents.first?.status == .blocked)
    }

    @Test("A failed layout read does not arm a restore, and the move re-keys the current row")
    func failedRefreshLeavesTheMoveToRekey() {
        var live = initialTable()
        live.noteLayoutRefresh(nil, now: refreshedAt)
        #expect(live.agents.map(\.id.raw) == ["wA:p1", "wA:p2"])

        live.apply(moveEvent(), now: moveAt)

        #expect(live.agents.map(\.id.raw) == ["wB:p4", "wA:p2"])
        #expect(live.agents.first?.enteredAt == started)
        #expect(live.agents.first?.status == .blocked)
        // The failed read never learned the new workspace, so the label is
        // the one the move itself created.
        #expect(live.agents.first?.workspaceName == "from-event")
        #expect(live.agents.first?.tabName == "from-event-tab")
    }

    @Test("Every pane a layout refetch moved gets its dwell back")
    func twoMovesInOneBurstBothRestore() {
        var live = initialTable()
        live.noteLayoutRefresh(
            snapshot(
                [
                    makeDwellAgentInfo(
                        paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t1",
                        agentStatus: "blocked", stateChangeSeq: 5
                    ),
                    makeDwellAgentInfo(
                        paneId: "wB:p8", workspaceId: "wB", tabId: "wB:t1",
                        agentStatus: "working", stateChangeSeq: 3
                    )
                ],
                workspaces: ["wB": "proj"],
                tabs: ["wB:t1": "scratch"]
            ),
            now: refreshedAt
        )
        #expect(live.agents.allSatisfy { $0.enteredAt == refreshedAt })

        live.apply(moveEvent(), now: moveAt)
        live.apply(
            .paneMoved(
                previousPaneId: "wA:p2",
                pane: makeDwellAgentInfo(
                    paneId: "wB:p8", workspaceId: "wB", tabId: "wB:t1",
                    agentStatus: "working", stateChangeSeq: 0
                ),
                createdWorkspaceLabel: nil,
                createdTabLabel: nil
            ),
            now: moveAt
        )

        let byId = Dictionary(live.agents.map { ($0.id.raw, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byId["wB:p4"]?.enteredAt == started)
        #expect(byId["wB:p4"]?.status == .blocked)
        #expect(byId["wB:p8"]?.enteredAt == started)
        #expect(byId["wB:p8"]?.status == .working)
        #expect(byId["wB:p8"]?.stateChangeSeq == 3)
    }

    @Test("A later move restores the dwell from after the previous move, not from the first burst")
    func nextBurstRemembersTheRestoredRows() {
        var live = initialTable()
        refreshAfterMove(on: &live, at: refreshedAt)
        live.apply(moveEvent(), now: moveAt)
        #expect(live.agents.first { $0.id.raw == "wB:p4" }?.enteredAt == started)

        let again = Date(timeIntervalSince1970: 9_800)
        live.noteLayoutRefresh(
            snapshot(
                [
                    makeDwellAgentInfo(
                        paneId: "wC:p1", workspaceId: "wC", tabId: "wC:t1",
                        agentStatus: "blocked", stateChangeSeq: 5
                    ),
                    makeDwellAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 3)
                ],
                workspaces: ["wA": "Cuedora", "wC": "other"],
                tabs: ["wA:t1": "main", "wC:t1": "next"]
            ),
            now: again
        )
        live.apply(
            .paneMoved(
                previousPaneId: "wB:p4",
                pane: makeDwellAgentInfo(
                    paneId: "wC:p1", workspaceId: "wC", tabId: "wC:t1",
                    agentStatus: "blocked", stateChangeSeq: 0
                ),
                createdWorkspaceLabel: nil,
                createdTabLabel: nil
            ),
            now: again
        )

        let moved = live.agents.first { $0.id.raw == "wC:p1" }
        #expect(moved?.enteredAt == started)
        #expect(moved?.status == .blocked)
        #expect(moved?.workspaceName == "other")
        #expect(live.agents.first { $0.id.raw == "wA:p2" }?.enteredAt == started)
    }

    @Test("A move to a shell after the refetch dropped the row stays gone")
    func moveToShellStaysGone() {
        var live = initialTable()
        let emptied = snapshot([
            makeDwellAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 3)
        ])
        live.noteLayoutRefresh(emptied, now: refreshedAt)
        live.apply(
            .paneMoved(
                previousPaneId: "wA:p1",
                pane: makeDwellAgentInfo(
                    paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t1",
                    agent: nil, stateChangeSeq: 0
                ),
                createdWorkspaceLabel: nil,
                createdTabLabel: nil
            ),
            now: moveAt
        )
        #expect(live.agents.map(\.id.raw) == ["wA:p2"])
    }

    @Test("The same session still gets its pre-refetch dwell back")
    func sameSessionMoveStillRestores() {
        let same = HerdrSnapshot.AgentSession(source: "agent", agent: "claude", kind: "session", value: "abc")
        let first = snapshot([
            makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: same),
            makeDwellAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 3)
        ])
        var live = HerdLiveTable(herd: first, agents: first.displayAgents(now: started))
        live.noteLayoutRefresh(
            snapshot(
                [
                    makeDwellAgentInfo(
                        paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t1",
                        agentStatus: "blocked", stateChangeSeq: 5, session: same
                    ),
                    makeDwellAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 3)
                ],
                workspaces: ["wA": "Cuedora", "wB": "proj"],
                tabs: ["wA:t1": "main", "wB:t1": "scratch"]
            ),
            now: refreshedAt
        )
        #expect(live.agents.first { $0.id.raw == "wB:p4" }?.enteredAt == refreshedAt)
        live.apply(
            .paneMoved(
                previousPaneId: "wA:p1",
                pane: makeDwellAgentInfo(
                    paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t1",
                    agentStatus: "working", stateChangeSeq: 0
                ),
                createdWorkspaceLabel: nil,
                createdTabLabel: nil
            ),
            now: moveAt
        )
        let moved = live.agents.first { $0.id.raw == "wB:p4" }
        #expect(moved?.enteredAt == started)
        #expect(moved?.status == .blocked)
        #expect(moved?.stateChangeSeq == 5)
        #expect(live.agents.first { $0.id.raw == "wA:p2" }?.enteredAt == started)
    }

    @Test("A different session on the same pane starts a dwell the move does not put back")
    func differentSessionIsNotRestoredByTheMove() {
        let same = HerdrSnapshot.AgentSession(source: "agent", agent: "claude", kind: "session", value: "abc")
        let other = HerdrSnapshot.AgentSession(source: "agent", agent: "claude", kind: "session", value: "other")
        let first = snapshot([
            makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: same),
            makeDwellAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 3)
        ])
        var rows = first.displayAgents(now: started)
        if let index = rows.firstIndex(where: { $0.id.raw == "wA:p1" }) {
            rows[index].verdict = .processGone(lastLine: "zsh (pid 1)")
        }
        var live = HerdLiveTable(herd: first, agents: rows)
        live.noteLayoutRefresh(
            snapshot([
                makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: other),
                makeDwellAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 3)
            ]),
            now: refreshedAt
        )
        let replaced = live.agents.first { $0.id.raw == "wA:p1" }
        #expect(replaced?.enteredAt == refreshedAt)
        #expect(replaced?.verdict.isProcessGone == false)
        #expect(live.agents.first { $0.id.raw == "wA:p2" }?.enteredAt == started)

        live.apply(
            .paneMoved(
                previousPaneId: "wA:p1",
                pane: makeDwellAgentInfo(
                    paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t1",
                    agentStatus: "blocked", stateChangeSeq: 0, session: other
                ),
                createdWorkspaceLabel: nil,
                createdTabLabel: nil
            ),
            now: moveAt
        )
        let moved = live.agents.first { $0.id.raw == "wB:p4" }
        #expect(moved?.enteredAt == refreshedAt)
        #expect(moved?.verdict.isProcessGone == false)
        #expect(live.agents.first { $0.id.raw == "wA:p2" }?.enteredAt == started)
    }

    @Test("The first session value on a pane keeps the dwell and the crash")
    func firstSessionKeepsTheEpisode() {
        let named = HerdrSnapshot.AgentSession(source: "agent", agent: "claude", kind: "session", value: "abc")
        let first = snapshot([
            makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)
        ])
        var rows = first.displayAgents(now: started)
        rows[0].verdict = .processGone(lastLine: "zsh (pid 1)")
        var live = HerdLiveTable(herd: first, agents: rows)
        live.noteLayoutRefresh(
            snapshot([
                makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: named)
            ]),
            now: refreshedAt
        )
        let row = live.agents.first { $0.id.raw == "wA:p1" }
        #expect(row?.enteredAt == started)
        #expect(row?.verdict == .processGone(lastLine: "zsh (pid 1)"))
    }

    @Test("pane_updated that names a new session opens one dwell, and the next copy does not")
    func paneUpdatedSessionOpensOneEpisode() {
        let same = HerdrSnapshot.AgentSession(source: "agent", agent: "claude", kind: "session", value: "abc")
        let other = HerdrSnapshot.AgentSession(source: "agent", agent: "claude", kind: "session", value: "other")
        let first = snapshot([
            makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: same)
        ])
        var rows = first.displayAgents(now: started)
        rows[0].verdict = .processGone(lastLine: "zsh (pid 1)")
        var live = HerdLiveTable(herd: first, agents: rows)
        live.apply(
            .paneUpdated(makeDwellAgentInfo(
                paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0, session: other
            )),
            now: moveAt
        )
        let opened = live.agents.first { $0.id.raw == "wA:p1" }
        #expect(opened?.enteredAt == moveAt)
        #expect(opened?.verdict.isProcessGone == false)

        let later = Date(timeIntervalSince1970: 9_800)
        live.apply(
            .paneUpdated(makeDwellAgentInfo(
                paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0, session: other
            )),
            now: later
        )
        #expect(live.agents.first { $0.id.raw == "wA:p1" }?.enteredAt == moveAt)

        let omitted = Date(timeIntervalSince1970: 9_900)
        var quiet = HerdLiveTable(herd: first, agents: rows)
        quiet.apply(
            .paneUpdated(makeDwellAgentInfo(
                paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0
            )),
            now: omitted
        )
        let kept = quiet.agents.first { $0.id.raw == "wA:p1" }
        #expect(kept?.enteredAt == started)
        #expect(kept?.verdict == .processGone(lastLine: "zsh (pid 1)"))
    }

    @Test("A refetch that omits the session still opens a dwell for the next occupant")
    func omittedRefreshDoesNotHideTheNextSession() {
        let same = HerdrSnapshot.AgentSession(source: "agent", agent: "claude", kind: "session", value: "abc")
        let other = HerdrSnapshot.AgentSession(source: "agent", agent: "claude", kind: "session", value: "other")
        let first = snapshot([
            makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: same),
            makeDwellAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 3)
        ])
        var rows = first.displayAgents(now: started)
        if let index = rows.firstIndex(where: { $0.id.raw == "wA:p1" }) {
            rows[index].verdict = .processGone(lastLine: "zsh (pid 1)")
        }
        var live = HerdLiveTable(herd: first, agents: rows)
        live.noteLayoutRefresh(
            snapshot([
                makeDwellAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5),
                makeDwellAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 3)
            ]),
            now: refreshedAt
        )
        let held = live.agents.first { $0.id.raw == "wA:p1" }
        #expect(held?.enteredAt == started)
        #expect(held?.verdict == .processGone(lastLine: "zsh (pid 1)"))
        #expect(live.agents.first { $0.id.raw == "wA:p2" }?.enteredAt == started)

        let later = Date(timeIntervalSince1970: 9_800)
        live.apply(
            .paneUpdated(makeDwellAgentInfo(
                paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0, session: other
            )),
            now: later
        )
        let opened = live.agents.first { $0.id.raw == "wA:p1" }
        #expect(opened?.enteredAt == later)
        #expect(opened?.verdict.isProcessGone == false)
        #expect(live.agents.first { $0.id.raw == "wA:p2" }?.enteredAt == started)
    }
}
