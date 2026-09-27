import Foundation
import Testing
@testable import HerdrManagerCore

private func makeEventAgentInfo(
    paneId: String,
    workspaceId: String = "wA",
    tabId: String = "wA:t1",
    agent: String? = "claude",
    agentStatus: String = "working",
    stateChangeSeq: UInt64 = 0,
    title: String? = nil,
    terminalTitleStripped: String? = nil,
    cwd: String? = "/tmp",
    foregroundCwd: String? = "/tmp",
    session: HerdrSnapshot.AgentSession? = nil
) -> HerdrAgentInfo {
    HerdrAgentInfo(
        paneId: paneId,
        workspaceId: workspaceId,
        tabId: tabId,
        agent: agent,
        displayAgent: agent,
        name: nil,
        title: title,
        terminalTitleStripped: terminalTitleStripped,
        agentStatus: agentStatus,
        agentSession: session,
        focused: false,
        stateChangeSeq: stateChangeSeq,
        cwd: cwd,
        foregroundCwd: foregroundCwd,
        revision: 1,
        tokens: [:],
        stateLabels: [:],
        interactiveReady: true,
        launchPending: false
    )
}

/// herdmgr's live table.
@Suite("HerdSnapshot.applying(_:to:)")
struct HerdSnapshotEventsTests {
    private let labels = HerdSnapshot(
        version: "0.7.5", protocol: 17,
        agents: [],
        workspaceNames: ["wA": "Cuedora"], tabNames: ["wA:t1": "main"],
        focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
    )
    private let now = Date(timeIntervalSince1970: 5_000)

    @Test("pane_created adds no row")
    func paneCreatedAddsNothing() {
        let rows = labels.applying(.paneCreated(paneId: "wA:p1", workspaceId: "wA", tabId: "wA:t1"), to: [])
        #expect(rows.isEmpty)
    }

    @Test("pane_updated for a pane with no row inserts the agent, labelled from the snapshot")
    func paneUpdatedInsertsAgent() {
        // herdmgr used to update existing rows only, and relied on the
        // pane_created placeholder to have one.
        var rows = labels.applying(.paneCreated(paneId: "wA:p1", workspaceId: "wA", tabId: "wA:t1"), to: [])
        rows = labels.applying(
            .paneUpdated(makeEventAgentInfo(paneId: "wA:p1", agentStatus: "blocked")),
            to: rows, now: now
        )

        #expect(rows.count == 1)
        let agent = rows.first
        #expect(agent?.id == AgentID("wA:p1"))
        #expect(agent?.kind == .custom("claude"))
        #expect(agent?.status == .blocked)
        #expect(agent?.enteredAt == now)
        #expect(agent?.workspaceName == "Cuedora")
        #expect(agent?.tabName == "main")
        #expect(agent.map(AttentionTriage.needsYou) == true)
    }

    @Test("A plain shell never gets a row, and an agent that drops back to a shell loses its row")
    func shellsNeverAppear() {
        var rows = labels.applying(.paneUpdated(makeEventAgentInfo(paneId: "wA:p1", agent: nil)), to: [])
        #expect(rows.isEmpty)

        rows = labels.applying(.paneUpdated(makeEventAgentInfo(paneId: "wA:p1", agent: "codex")), to: rows)
        #expect(rows.count == 1)
        rows = labels.applying(.paneUpdated(makeEventAgentInfo(paneId: "wA:p1", agent: nil)), to: rows)
        #expect(rows.isEmpty)
    }

    @Test("A stale pane_updated is ignored and a seq-less one keeps the agent.list seq")
    func staleAndSeqlessUpdates() {
        let listed = Agent(id: AgentID("wA:p1"), kind: .custom("claude"), status: .blocked, stateChangeSeq: 9)

        let stale = labels.applying(
            .paneUpdated(makeEventAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 8)),
            to: [listed]
        )
        #expect(stale == [listed])

        let seqless = labels.applying(
            .paneUpdated(makeEventAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 0)),
            to: [listed], now: now
        )
        #expect(seqless.first?.status == .working)
        #expect(seqless.first?.stateChangeSeq == 9)
        #expect(seqless.first?.enteredAt == now)
    }

    @Test("A same-status pane_updated refreshes title, kind, directory, and a known tab")
    func paneUpdatedRefreshesPresentation() {
        let entered = Date(timeIntervalSince1970: 1_000)
        let row = Agent(
            id: AgentID("wA:p1"),
            kind: .custom("claude"),
            name: "Review",
            displayName: "Review",
            status: .working,
            stateChangeSeq: 5,
            enteredAt: entered,
            verdict: .processGone(lastLine: "zsh (pid 1)"),
            workspaceName: "Cuedora",
            tabName: "main",
            cwd: "/old"
        )
        let named = HerdSnapshot(
            version: "0.7.5", protocol: 17,
            agents: [],
            workspaceNames: ["wA": "Cuedora"],
            tabNames: ["wA:t1": "main", "wA:t9": "tests"],
            focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
        )
        let session = HerdrSnapshot.AgentSession(
            source: "herdr:codex", agent: "codex", kind: "id", value: "019f"
        )
        let refreshed = named.applying(
            .paneUpdated(makeEventAgentInfo(
                paneId: "wA:p1",
                tabId: "wA:t9",
                agent: "claude",
                agentStatus: "working",
                stateChangeSeq: 0,
                terminalTitleStripped: "Action Required",
                cwd: "/workspace/herdr-manager",
                foregroundCwd: "/workspace/herdr-manager/Sources",
                session: session
            )),
            to: [row],
            now: now
        )
        guard let agent = refreshed.first else {
            Issue.record("Expected the row to stay")
            return
        }
        #expect(agent.name == "Action Required")
        #expect(agent.displayName == "Action Required")
        #expect(agent.kind == .custom("codex"))
        #expect(agent.cwd == "/workspace/herdr-manager/Sources")
        #expect(agent.tabName == "tests")
        #expect(agent.workspaceName == "Cuedora")
        #expect(agent.status == .working)
        #expect(agent.stateChangeSeq == 5)
        #expect(agent.enteredAt == entered)
        #expect(agent.verdict == .processGone(lastLine: "zsh (pid 1)"))

        // Metadata title wins over the stripped terminal title.
        let titled = named.applying(
            .paneUpdated(makeEventAgentInfo(
                paneId: "wA:p1",
                tabId: "wA:t9",
                agentStatus: "working",
                stateChangeSeq: 0,
                title: "Metadata",
                terminalTitleStripped: "Action Required"
            )),
            to: refreshed,
            now: now
        )
        #expect(titled.first?.name == "Metadata")
        #expect(titled.first?.displayName == "Metadata")
        #expect(titled.first?.enteredAt == entered)
        #expect(titled.first?.verdict == .processGone(lastLine: "zsh (pid 1)"))
    }

    @Test("A pane_updated that omits presentation fields, or is stale, leaves them")
    func paneUpdatedDoesNotRollPresentationBackward() {
        let entered = Date(timeIntervalSince1970: 1_000)
        let row = Agent(
            id: AgentID("wA:p1"),
            kind: .custom("codex"),
            name: "Metadata",
            displayName: "Metadata",
            status: .working,
            stateChangeSeq: 5,
            enteredAt: entered,
            verdict: .processGone(lastLine: "zsh (pid 1)"),
            workspaceName: "proj",
            tabName: "scratch",
            cwd: "/workspace/herdr-manager/Sources"
        )
        let kept = labels.applying(
            .paneUpdated(makeEventAgentInfo(
                paneId: "wA:p1",
                workspaceId: "wMissing",
                tabId: "wMissing:t1",
                agent: "claude",
                agentStatus: "working",
                stateChangeSeq: 0,
                title: "",
                terminalTitleStripped: "",
                cwd: "",
                foregroundCwd: nil
            )),
            to: [row],
            now: now
        )
        guard let agent = kept.first else {
            Issue.record("Expected the row to stay")
            return
        }
        // Kind still follows the detected agent. The empty title, empty
        // directory, and unknown container do not wipe the row.
        #expect(agent.kind == .custom("claude"))
        #expect(agent.name == "Metadata")
        #expect(agent.displayName == "Metadata")
        #expect(agent.cwd == "/workspace/herdr-manager/Sources")
        #expect(agent.workspaceName == "proj")
        #expect(agent.tabName == "scratch")
        #expect(agent.enteredAt == entered)
        #expect(agent.verdict == .processGone(lastLine: "zsh (pid 1)"))

        let stale = labels.applying(
            .paneUpdated(makeEventAgentInfo(
                paneId: "wA:p1",
                agentStatus: "blocked",
                stateChangeSeq: 4,
                terminalTitleStripped: "Older"
            )),
            to: kept,
            now: now
        )
        // Behind the stored seq the whole event is ignored, including the
        // title and the status it wanted to apply.
        #expect(stale == kept)
    }

    @Test("A status change still opens an episode and takes the new title")
    func paneUpdatedStatusChangeTakesTitle() {
        let entered = Date(timeIntervalSince1970: 1_000)
        let row = Agent(
            id: AgentID("wA:p1"),
            kind: .custom("claude"),
            name: "Review",
            displayName: "Review",
            status: .working,
            stateChangeSeq: 5,
            enteredAt: entered,
            verdict: .processGone(lastLine: "zsh (pid 1)"),
            workspaceName: "Cuedora",
            tabName: "main"
        )
        let changed = labels.applying(
            .paneUpdated(makeEventAgentInfo(
                paneId: "wA:p1",
                agentStatus: "blocked",
                stateChangeSeq: 6,
                terminalTitleStripped: "Needs you"
            )),
            to: [row],
            now: now
        )
        guard let agent = changed.first else {
            Issue.record("Expected the row to stay")
            return
        }
        #expect(agent.name == "Needs you")
        #expect(agent.displayName == "Needs you")
        #expect(agent.status == .blocked)
        #expect(agent.stateChangeSeq == 6)
        #expect(agent.enteredAt == now)
        #expect(agent.verdict.isProcessGone == false)
        #expect(agent.verdict.isAwaitingInput)
    }

    @Test("A same-status update keeps a crash, and a status change clears it")
    func processGoneSurvivesSameStatusUpdate() {
        let entered = Date(timeIntervalSince1970: 1_000)
        let crashed = Agent(
            id: AgentID("wA:p1"),
            kind: .custom("claude"),
            status: .working,
            stateChangeSeq: 5,
            enteredAt: entered,
            verdict: .processGone(lastLine: "zsh (pid 1)")
        )

        let sameStatus = labels.applying(
            .paneUpdated(makeEventAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 9)),
            to: [crashed],
            now: now
        )
        #expect(sameStatus.first?.status == .working)
        #expect(sameStatus.first?.stateChangeSeq == 9)
        #expect(sameStatus.first?.enteredAt == entered)
        #expect(sameStatus.first?.verdict == .processGone(lastLine: "zsh (pid 1)"))

        let statusChanged = labels.applying(
            .paneUpdated(makeEventAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 10)),
            to: [crashed],
            now: now
        )
        #expect(statusChanged.first?.status == .blocked)
        #expect(statusChanged.first?.verdict.isProcessGone == false)
        #expect(statusChanged.first?.verdict.isAwaitingInput == true)

        let statusEvent = labels.applying(
            .agentStatusChanged(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 6),
            to: [crashed],
            now: now
        )
        #expect(statusEvent.first?.verdict == .processGone(lastLine: "zsh (pid 1)"))
        #expect(statusEvent.first?.stateChangeSeq == 6)
    }

    @Test("pane_moved re-keys a cross-workspace move and keeps the dwell")
    func paneMovedRekeys() {
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        let output = Date(timeIntervalSince1970: 1_700_000_050)
        let moved = Agent(
            id: AgentID("wA:p1"),
            kind: .custom("claude"),
            name: "Claude",
            displayName: "Claude",
            status: .blocked,
            stateChangeSeq: 5,
            enteredAt: entered,
            lastOutputAt: output,
            verdict: .healthy,
            workspaceName: "Cuedora",
            tabName: "main"
        )
        let other = Agent(id: AgentID("wA:p2"), status: .idle, workspaceName: "Cuedora", tabName: "main")
        let rows = labels.applying(
            .paneMoved(
                previousPaneId: "wA:p1",
                pane: makeEventAgentInfo(
                    paneId: "wB:p4",
                    workspaceId: "wB",
                    tabId: "wB:t1",
                    agentStatus: "blocked",
                    stateChangeSeq: 5
                ),
                createdWorkspaceLabel: "proj",
                createdTabLabel: "scratch"
            ),
            to: [moved, other],
            now: now
        )

        #expect(rows.map(\.id.raw) == ["wB:p4", "wA:p2"])
        guard rows.count == 2 else { return }
        #expect(rows[0].status == .blocked)
        #expect(rows[0].enteredAt == entered)
        #expect(rows[0].lastOutputAt == output)
        #expect(rows[0].verdict.isHealthy)
        #expect(rows[0].stateChangeSeq == 5)
        #expect(rows[0].name == "Claude")
        #expect(rows[0].workspaceName == "proj")
        #expect(rows[0].tabName == "scratch")

        // Later status events name the new id. The old id is gone, so a
        // table that did not re-key would ignore this and stay blocked.
        let later = Date(timeIntervalSince1970: 1_700_000_200)
        let updated = labels.applying(
            .paneUpdated(makeEventAgentInfo(paneId: "wB:p4", agentStatus: "working", stateChangeSeq: 0)),
            to: rows,
            now: later
        )
        #expect(updated.first?.status == .working)
        #expect(updated.first?.enteredAt == later)
        #expect(updated.map(\.id.raw) == ["wB:p4", "wA:p2"])
    }

    @Test("A same-workspace move keeps the id and uses the snapshot's tab label")
    func paneMovedSameIdUsesLabel() {
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        let row = Agent(
            id: AgentID("wA:p1"),
            kind: .custom("claude"),
            status: .working,
            stateChangeSeq: 4,
            enteredAt: entered,
            workspaceName: "Cuedora",
            tabName: "main"
        )
        let named = HerdSnapshot(
            version: "0.7.5", protocol: 17,
            agents: [],
            workspaceNames: ["wA": "Cuedora"],
            tabNames: ["wA:t1": "main", "wA:t9": "tests"],
            focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
        )
        let rows = named.applying(
            .paneMoved(
                previousPaneId: "wA:p1",
                pane: makeEventAgentInfo(
                    paneId: "wA:p1", tabId: "wA:t9",
                    agentStatus: "working", stateChangeSeq: 4
                ),
                createdWorkspaceLabel: nil,
                createdTabLabel: nil
            ),
            to: [row],
            now: now
        )
        #expect(rows.map(\.id.raw) == ["wA:p1"])
        guard rows.count == 1 else { return }
        #expect(rows[0].tabName == "tests")
        #expect(rows[0].workspaceName == "Cuedora")
        #expect(rows[0].enteredAt == entered)
    }

    @Test("A seq-less pane_moved re-keys and keeps status when the payload disagrees")
    func seqlessMoveKeepsStatus() {
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        let row = Agent(
            id: AgentID("wA:p1"),
            kind: .custom("claude"),
            name: "Claude",
            displayName: "Claude",
            status: .blocked,
            stateChangeSeq: 9,
            enteredAt: entered,
            verdict: .healthy,
            workspaceName: "Cuedora",
            tabName: "main"
        )
        let rows = labels.applying(
            .paneMoved(
                previousPaneId: "wA:p1",
                pane: makeEventAgentInfo(
                    paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t1",
                    agentStatus: "working", stateChangeSeq: 0
                ),
                createdWorkspaceLabel: "proj",
                createdTabLabel: "scratch"
            ),
            to: [row],
            now: now
        )
        #expect(rows.map(\.id.raw) == ["wB:p4"])
        guard let moved = rows.first else { return }
        #expect(moved.status == .blocked)
        #expect(moved.stateChangeSeq == 9)
        #expect(moved.enteredAt == entered)
        #expect(moved.workspaceName == "proj")
        #expect(moved.tabName == "scratch")
    }

    @Test("A seq-less pane_moved for an unknown pane adds no row")
    func seqlessMoveUnknownAddsNothing() {
        let other = Agent(id: AgentID("wA:p2"), status: .idle)
        let rows = labels.applying(
            .paneMoved(
                previousPaneId: "wA:p1",
                pane: makeEventAgentInfo(paneId: "wB:p4", agentStatus: "blocked"),
                createdWorkspaceLabel: nil,
                createdTabLabel: nil
            ),
            to: [other],
            now: now
        )
        #expect(rows.map(\.id.raw) == ["wA:p2"])
    }

    @Test("pane_moved to a shell drops the row")
    func paneMovedToShellDrops() {
        let row = Agent(id: AgentID("wA:p1"), status: .working)
        let rows = labels.applying(
            .paneMoved(
                previousPaneId: "wA:p1",
                pane: makeEventAgentInfo(paneId: "wB:p4", agent: nil),
                createdWorkspaceLabel: nil,
                createdTabLabel: nil
            ),
            to: [row]
        )
        #expect(rows.isEmpty)
    }

    @Test("pane_closed and pane_exited remove the row")
    func closeAndExitRemove() {
        let rows = [
            Agent(id: AgentID("wA:p1"), status: .working),
            Agent(id: AgentID("wA:p2"), status: .working),
        ]
        let afterClose = labels.applying(.paneClosed(paneId: "wA:p1"), to: rows)
        #expect(afterClose.map(\.id.raw) == ["wA:p2"])
        #expect(labels.applying(.paneExited(paneId: "wA:p2"), to: afterClose).isEmpty)
    }
}
