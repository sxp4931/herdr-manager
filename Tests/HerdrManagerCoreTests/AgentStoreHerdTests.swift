import Foundation
import Testing
@testable import HerdrManagerCore

// MARK: - Fixtures

private func makeAgentInfo(
    paneId: String,
    workspaceId: String = "wA",
    tabId: String = "wA:t1",
    agent: String? = "claude",
    agentStatus: String = "working",
    stateChangeSeq: UInt64 = 1,
    title: String? = "Claude"
) -> HerdrAgentInfo {
    HerdrAgentInfo(
        paneId: paneId,
        workspaceId: workspaceId,
        tabId: tabId,
        agent: agent,
        displayAgent: agent,
        name: nil,
        title: title,
        terminalTitleStripped: title,
        agentStatus: agentStatus,
        agentSession: nil,
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

// MARK: - applyHerdSnapshot

@Suite("AgentStore.applyHerdSnapshot")
struct ApplyHerdSnapshotTests {

    @Test("Builds agents from HerdrAgentInfo with real stateChangeSeq and labels")
    @MainActor
    func buildsAgentsWithLabels() {
        let store = AgentStore()
        let snapshot = HerdSnapshot(
            version: "0.7.5",
            protocol: 17,
            agents: [makeAgentInfo(paneId: "wA:p1", stateChangeSeq: 42)],
            workspaceNames: ["wA": "Cuedora"],
            tabNames: ["wA:t1": "Claude"],
            focusedWorkspaceId: "wA",
            focusedTabId: "wA:t1",
            focusedPaneId: "wA:p1"
        )
        store.applyHerdSnapshot(snapshot)
        let agent = store.agents[AgentID("wA:p1")]
        #expect(agent != nil)
        #expect(agent?.stateChangeSeq == 42)
        #expect(agent?.workspaceName == "Cuedora")
        #expect(agent?.tabName == "Claude")
        #expect(agent?.status == .working)
    }

    @Test("displayAgents drops shells and empty pane ids and keeps seq")
    func displayAgentsDropsShellsAndEmptyIds() {
        let snapshot = HerdSnapshot(
            version: "0.7.5",
            protocol: 17,
            agents: [
                makeAgentInfo(paneId: "wA:p1", stateChangeSeq: 42),
                makeAgentInfo(paneId: "wA:p2", agent: nil),
                makeAgentInfo(paneId: "", stateChangeSeq: 9)
            ],
            workspaceNames: ["wA": "Cuedora"],
            tabNames: ["wA:t1": "Claude"],
            focusedWorkspaceId: "wA",
            focusedTabId: "wA:t1",
            focusedPaneId: "wA:p1"
        )
        let agents = snapshot.displayAgents()
        #expect(agents.count == 1)
        #expect(agents[0].id.raw == "wA:p1")
        #expect(agents[0].stateChangeSeq == 42)
        #expect(agents[0].workspaceName == "Cuedora")
        #expect(agents[0].tabName == "Claude")
        #expect(agents[0].status == .working)
    }

    @Test("applySnapshot does not trap on duplicate workspace or tab ids")
    @MainActor
    func applySnapshotDedupesLabelIds() {
        let store = AgentStore()
        let snapshot = HerdrSnapshot(
            version: "0.1.0",
            protocol: 17,
            workspaces: [
                .init(workspaceId: "w1", name: "first"),
                .init(workspaceId: "w1", name: "second"),
                .init(workspaceId: "", name: "ghost")
            ],
            tabs: [
                .init(tabId: "t1", workspaceId: "w1", name: "tab-first"),
                .init(tabId: "t1", workspaceId: "w1", name: "tab-second")
            ],
            panes: [
                .init(
                    paneId: "w1:p1",
                    workspaceId: "w1",
                    tabId: "t1",
                    agent: "claude",
                    agentStatus: "working",
                    agentSession: nil,
                    terminalTitleStripped: "Claude",
                    stateChangeSeq: 1,
                    cwd: "/tmp",
                    foregroundCwd: "/tmp",
                    revision: 1
                ),
                .init(
                    paneId: "",
                    workspaceId: "w1",
                    tabId: "t1",
                    agent: "claude",
                    agentStatus: "blocked",
                    agentSession: nil,
                    terminalTitleStripped: "Ghost",
                    stateChangeSeq: 1,
                    cwd: "/tmp",
                    foregroundCwd: "/tmp",
                    revision: 1
                )
            ],
            focusedWorkspaceId: "w1",
            focusedTabId: "t1",
            focusedPaneId: "w1:p1"
        )
        store.applySnapshot(snapshot)
        #expect(store.agents.count == 1)
        #expect(store.agents[AgentID("w1:p1")]?.workspaceName == "second")
        #expect(store.agents[AgentID("w1:p1")]?.tabName == "tab-second")
        #expect(store.agents[AgentID("")] == nil)
    }

    @Test("Never inserts an entry with no agent (plain shell)")
    @MainActor
    func excludesShells() {
        let store = AgentStore()
        let snapshot = HerdSnapshot(
            version: "0.7.5",
            protocol: 17,
            agents: [makeAgentInfo(paneId: "wA:p2", agent: nil)],
            workspaceNames: [:],
            tabNames: [:],
            focusedWorkspaceId: nil,
            focusedTabId: nil,
            focusedPaneId: nil
        )
        store.applyHerdSnapshot(snapshot)
        #expect(store.agents[AgentID("wA:p2")] == nil)
        #expect(store.agents.isEmpty)
    }

    @Test("Preserves enteredAt when stateChangeSeq is unchanged across snapshots")
    @MainActor
    func preservesEnteredAtWhenSeqUnchanged() async {
        let store = AgentStore()
        let first = HerdSnapshot(
            version: "0.7.5", protocol: 17,
            agents: [makeAgentInfo(paneId: "wA:p1", stateChangeSeq: 5)],
            workspaceNames: [:], tabNames: [:],
            focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
        )
        store.applyHerdSnapshot(first)
        let firstEnteredAt = store.agents[AgentID("wA:p1")]?.enteredAt

        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms, enough to distinguish Dates

        let second = HerdSnapshot(
            version: "0.7.5", protocol: 17,
            agents: [makeAgentInfo(paneId: "wA:p1", stateChangeSeq: 5)], // same seq
            workspaceNames: [:], tabNames: [:],
            focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
        )
        store.applyHerdSnapshot(second)
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == firstEnteredAt)
    }

    @Test("Resets enteredAt when status changes even if seq is unchanged")
    @MainActor
    func statusChangeResetsDwellWhenSeqStays() async {
        let store = AgentStore()
        let first = HerdSnapshot(
            version: "0.7.5", protocol: 17,
            agents: [makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 5)],
            workspaceNames: [:], tabNames: [:],
            focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
        )
        store.applyHerdSnapshot(first)
        let firstEnteredAt = store.agents[AgentID("wA:p1")]?.enteredAt

        try? await Task.sleep(nanoseconds: 20_000_000)

        let second = HerdSnapshot(
            version: "0.7.5", protocol: 17,
            agents: [makeAgentInfo(paneId: "wA:p1", agentStatus: "done", stateChangeSeq: 5)],
            workspaceNames: [:], tabNames: [:],
            focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
        )
        store.applyHerdSnapshot(second)
        #expect(store.agents[AgentID("wA:p1")]?.status == .done)
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt != firstEnteredAt)
        #expect(store.agents[AgentID("wA:p1")]?.verdict.isHealthy == true)
    }

    @Test("Resets enteredAt when stateChangeSeq bumps")
    @MainActor
    func resetsEnteredAtWhenSeqBumps() async {
        let store = AgentStore()
        let first = HerdSnapshot(
            version: "0.7.5", protocol: 17,
            agents: [makeAgentInfo(paneId: "wA:p1", stateChangeSeq: 5)],
            workspaceNames: [:], tabNames: [:],
            focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
        )
        store.applyHerdSnapshot(first)
        let firstEnteredAt = store.agents[AgentID("wA:p1")]?.enteredAt

        try? await Task.sleep(nanoseconds: 20_000_000)

        let second = HerdSnapshot(
            version: "0.7.5", protocol: 17,
            agents: [makeAgentInfo(paneId: "wA:p1", stateChangeSeq: 6)], // bumped
            workspaceNames: [:], tabNames: [:],
            focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
        )
        store.applyHerdSnapshot(second)
        let secondEnteredAt = store.agents[AgentID("wA:p1")]?.enteredAt
        #expect(secondEnteredAt != nil)
        #expect(secondEnteredAt != firstEnteredAt)
        if let firstEnteredAt, let secondEnteredAt {
            #expect(secondEnteredAt > firstEnteredAt)
        }
    }
}

// MARK: - applyEvent(.paneUpdated)

@Suite("AgentStore.applyEvent(.paneUpdated)")
struct ApplyEventPaneUpdatedTests {

    @Test("Upserts a brand-new agent in place")
    @MainActor
    func upsertsNewAgent() {
        let store = AgentStore()
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked")))
        let agent = store.agents[AgentID("wA:p1")]
        #expect(agent != nil)
        #expect(agent?.status == .blocked)
    }

    @Test("Never inserts an entry whose agent is nil/empty")
    @MainActor
    func neverInsertsShell() {
        let store = AgentStore()
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agent: nil)))
        #expect(store.agents.isEmpty)
    }

    @Test("Removes a tracked agent whose pane_updated now reports no agent (dropped back to shell)")
    @MainActor
    func removesWhenAgentDisappears() {
        let store = AgentStore()
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agent: "claude")))
        #expect(store.agents[AgentID("wA:p1")] != nil)
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agent: nil)))
        #expect(store.agents[AgentID("wA:p1")] == nil)
    }

    @Test("A status change resets enteredAt")
    @MainActor
    func statusChangeResetsEnteredAt() async {
        let store = AgentStore()
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 0)))
        let firstEnteredAt = store.agents[AgentID("wA:p1")]?.enteredAt

        try? await Task.sleep(nanoseconds: 20_000_000)

        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))
        let secondEnteredAt = store.agents[AgentID("wA:p1")]?.enteredAt
        #expect(store.agents[AgentID("wA:p1")]?.status == .blocked)
        #expect(secondEnteredAt != firstEnteredAt)
    }

    @Test("Same status and no seq information does not reset enteredAt")
    @MainActor
    func unchangedStatusPreservesEnteredAt() async {
        let store = AgentStore()
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 0)))
        let firstEnteredAt = store.agents[AgentID("wA:p1")]?.enteredAt

        try? await Task.sleep(nanoseconds: 20_000_000)

        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 0)))
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == firstEnteredAt)
    }
}

// MARK: - applyEvent ordering and accepted transitions

@Suite("AgentStore.applyEvent stale events and transitions")
struct ApplyEventStaleAndTransitionTests {

    @Test("A pane_updated with an older seq does not move status backward")
    @MainActor
    func staleSeqIsIgnored() {
        let store = AgentStore()
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)))
        let before = store.agents[AgentID("wA:p1")]

        let transition = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)))

        #expect(transition == nil)
        #expect(store.agents[AgentID("wA:p1")] == before)
        #expect(store.agents[AgentID("wA:p1")]?.status == .blocked)
        #expect(store.agents[AgentID("wA:p1")]?.stateChangeSeq == 5)
    }

    @Test("A pane_updated older than the last agent.list resync is ignored")
    @MainActor
    func staleAgainstHerdSnapshot() {
        let store = AgentStore()
        store.applyHerdSnapshot(HerdSnapshot(
            version: "0.7.5",
            protocol: 17,
            agents: [makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 9)],
            workspaceNames: ["wA": "Alpha"],
            tabNames: ["wA:t1": "main"],
            focusedWorkspaceId: nil,
            focusedTabId: nil,
            focusedPaneId: nil
        ))
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 8)))
        #expect(store.agents[AgentID("wA:p1")]?.status == .blocked)
    }

    @Test("A stale pane_updated that reports no agent does not drop a live agent")
    @MainActor
    func staleShellEventDoesNotRemove() {
        let store = AgentStore()
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", stateChangeSeq: 5)))
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agent: nil, stateChangeSeq: 3)))
        #expect(store.agents[AgentID("wA:p1")] != nil)
    }

    @Test("A pane_updated with no seq still applies and keeps the stored seq")
    @MainActor
    func seqlessEventApplies() {
        let store = AgentStore()
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)))

        let transition = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 0)))

        #expect(transition?.from == .blocked)
        #expect(transition?.to == .working)
        #expect(store.agents[AgentID("wA:p1")]?.status == .working)
        #expect(store.agents[AgentID("wA:p1")]?.stateChangeSeq == 5)
    }

    @Test("Only an accepted status change is reported as a transition")
    @MainActor
    func transitionOnlyOnStatusChange() {
        let store = AgentStore()
        let first = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 2)))
        #expect(first?.from == nil)
        #expect(first?.to == .blocked)
        #expect(first?.agentId == AgentID("wA:p1"))

        let repeated = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 2)))
        #expect(repeated == nil)

        #expect(store.applyEvent(.paneFocused(paneId: "wA:p1", workspaceId: "wA")) == nil)
        #expect(store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p2", agent: nil))) == nil)
    }

    @Test("agentStatusChanged reports nothing for a stale seq or an untracked pane")
    @MainActor
    func agentStatusChangedIgnoredCases() {
        let store = AgentStore()
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 7)))

        let stale = store.applyEvent(.agentStatusChanged(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 6))
        #expect(stale == nil)
        #expect(store.agents[AgentID("wA:p1")]?.status == .working)

        let untracked = store.applyEvent(.agentStatusChanged(paneId: "wA:p9", agentStatus: "blocked", stateChangeSeq: 1))
        #expect(untracked == nil)
        #expect(store.agents[AgentID("wA:p9")] == nil)

        let accepted = store.applyEvent(.agentStatusChanged(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 8))
        #expect(accepted?.from == .working)
        #expect(accepted?.to == .blocked)
        #expect(accepted?.stateChangeSeq == 8)
    }

    @Test("Two blocked episodes between resyncs get distinct episode keys")
    @MainActor
    func blockedEpisodesHaveDistinctKeys() async {
        // pane_updated carries no seq, so the stored seq stays put across
        // episodes. A key built from seq alone made the second blocked
        // episode look like a duplicate and swallowed its notification.
        let store = AgentStore()
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 3)))

        let firstBlocked = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))
        try? await Task.sleep(nanoseconds: 5_000_000)
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 0)))
        try? await Task.sleep(nanoseconds: 5_000_000)
        let secondBlocked = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))

        #expect(firstBlocked?.stateChangeSeq == secondBlocked?.stateChangeSeq)
        #expect(firstBlocked != nil && secondBlocked != nil)
        #expect(firstBlocked?.episodeKey != secondBlocked?.episodeKey)
    }
}

// MARK: - applyEvent(.paneExited) / .workspacesChanged / .paneFocused

@Suite("AgentStore.applyEvent (misc new cases)")
struct ApplyEventMiscTests {

    @Test("paneExited removes the tracked agent")
    @MainActor
    func paneExitedRemoves() {
        let store = AgentStore()
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1")))
        #expect(store.agents[AgentID("wA:p1")] != nil)
        store.applyEvent(.paneExited(paneId: "wA:p1"))
        #expect(store.agents[AgentID("wA:p1")] == nil)
    }

    @Test("workspacesChanged is a no-op that does not throw or crash")
    @MainActor
    func workspacesChangedIsNoOp() {
        let store = AgentStore()
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1")))
        store.applyEvent(.workspacesChanged)
        #expect(store.agents[AgentID("wA:p1")] != nil)
    }

    @Test("paneFocused is a no-op that does not throw or crash")
    @MainActor
    func paneFocusedIsNoOp() {
        let store = AgentStore()
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1")))
        store.applyEvent(.paneFocused(paneId: "wA:p1", workspaceId: "wA"))
        #expect(store.agents[AgentID("wA:p1")] != nil)
    }
}

@Suite("AttentionTriage")
struct AttentionTriageTests {
    @Test("Needs-you is blocked, gone, or silent — not done or idle")
    func needsYouSet() {
        let blocked = Agent(id: AgentID("a"), status: .blocked)
        let gone = Agent(
            id: AgentID("b"),
            status: .working,
            verdict: .processGone(lastLine: "zsh")
        )
        let silent = Agent(
            id: AgentID("c"),
            status: .working,
            verdict: .silent(since: Date(), cpu: nil)
        )
        let done = Agent(id: AgentID("d"), status: .done, verdict: .healthy)
        let idle = Agent(id: AgentID("e"), status: .idle, verdict: .healthy)
        let working = Agent(id: AgentID("f"), status: .working, verdict: .healthy)

        #expect(AttentionTriage.needsYou(blocked))
        #expect(AttentionTriage.needsYou(gone))
        #expect(AttentionTriage.needsYou(silent))
        #expect(!AttentionTriage.needsYou(done))
        #expect(!AttentionTriage.needsYou(idle))
        #expect(!AttentionTriage.needsYou(working))
        #expect(AttentionTriage.attentionWorthy(done))
        #expect(!AttentionTriage.attentionWorthy(idle))
    }

    @Test("Blocked outranks a stale silent verdict")
    func blockedBeatsSilent() {
        let agent = Agent(
            id: AgentID("a"),
            status: .blocked,
            verdict: .silent(since: Date(), cpu: nil)
        )
        #expect(AttentionTriage.needsYou(agent))
        #expect(AttentionTriage.priority(agent) == 0)
    }

    @Test("Stale silent verdict on blocked, gone, done, or idle is not counted as silence")
    func staleSilentIsNotActionableSilence() {
        let blockedSilent = Agent(
            id: AgentID("a"),
            status: .blocked,
            verdict: .silent(since: Date(), cpu: nil)
        )
        let goneSilent = Agent(
            id: AgentID("b"),
            status: .working,
            verdict: .processGone(lastLine: "zsh")
        )
        let doneSilent = Agent(
            id: AgentID("c"),
            status: .done,
            verdict: .silent(since: Date(), cpu: nil)
        )
        let idleSilent = Agent(
            id: AgentID("d"),
            status: .idle,
            verdict: .silent(since: Date(), cpu: nil)
        )
        let workingSilent = Agent(
            id: AgentID("e"),
            status: .working,
            verdict: .silent(since: Date(), cpu: nil)
        )

        #expect(!AttentionTriage.isActionablySilent(blockedSilent))
        #expect(!AttentionTriage.isActionablySilent(goneSilent))
        #expect(!AttentionTriage.isActionablySilent(doneSilent))
        #expect(!AttentionTriage.isActionablySilent(idleSilent))
        #expect(AttentionTriage.isActionablySilent(workingSilent))
        #expect(AttentionTriage.isActionablyBlocked(blockedSilent))
        #expect(!AttentionTriage.isActionablyBlocked(goneSilent))
        #expect(!AttentionTriage.isActionablyBlocked(Agent(
            id: AgentID("gone-blocked"),
            status: .blocked,
            verdict: .processGone(lastLine: "zsh")
        )))
        #expect(!AttentionTriage.needsYou(doneSilent))
        #expect(!AttentionTriage.needsYou(idleSilent))
        #expect(AttentionTriage.priority(doneSilent) == 2)
        #expect(AttentionTriage.priority(idleSilent) == 3)
        #expect(AttentionTriage.priority(workingSilent) == 1)
        #expect(AttentionTriage.priority(blockedSilent) == 0)

        let counts = AttentionTriage.counts([
            blockedSilent, goneSilent, doneSilent, idleSilent, workingSilent
        ])
        #expect(counts.blocked == 1)
        #expect(counts.gone == 1)
        #expect(counts.silent == 1)
        #expect(counts.done == 1)
        #expect(counts.working == 0)
        #expect(counts.total == 4)
        #expect(counts.urgent == 2)
    }

    @Test("Worst-first order is gone/blocked, silent, done")
    func worstFirstOrder() {
        #expect(AttentionTriage.priority(Agent(
            id: AgentID("g"),
            status: .working,
            verdict: .processGone(lastLine: nil)
        )) == 0)
        #expect(AttentionTriage.priority(Agent(
            id: AgentID("s"),
            status: .working,
            verdict: .silent(since: Date(), cpu: nil)
        )) == 1)
        #expect(AttentionTriage.priority(Agent(
            id: AgentID("d"),
            status: .done,
            verdict: .healthy
        )) == 2)
    }

    @Test("Equal priority and dwell fall back to pane id, whatever the input order")
    func tieBreaksOnPaneId() {
        let now = Date()
        let agents = ["w2:p1", "w1:p3", "w1:p1", "w1:p2"].map {
            Agent(id: AgentID($0), status: .blocked, enteredAt: now)
        }
        let expected = ["w1:p1", "w1:p2", "w1:p3", "w2:p1"]
        #expect(agents.sorted(by: AttentionTriage.ranksBefore).map(\.id.raw) == expected)
        #expect(agents.reversed().sorted(by: AttentionTriage.ranksBefore).map(\.id.raw) == expected)
    }

    @Test("Priority outranks dwell, and dwell outranks pane id")
    func priorityThenDwellThenId() {
        let now = Date()
        let longBlocked = Agent(id: AgentID("w9:p9"), status: .blocked, enteredAt: now.addingTimeInterval(-600))
        let newBlocked = Agent(id: AgentID("w1:p1"), status: .blocked, enteredAt: now)
        let oldDone = Agent(id: AgentID("w0:p0"), status: .done, enteredAt: now.addingTimeInterval(-3600))
        let sorted = [oldDone, newBlocked, longBlocked].sorted(by: AttentionTriage.ranksBefore)
        #expect(sorted.map(\.id.raw) == ["w9:p9", "w1:p1", "w0:p0"])
    }
}

@Suite("AgentStore.attentionAgents")
struct AttentionAgentsTests {
    @Test("Equal-priority agents with the same dwell keep a stable pane-id order")
    @MainActor
    func stableOrderForTies() {
        let store = AgentStore()
        let now = Date()
        for raw in ["w3:p1", "w1:p2", "w2:p7", "w1:p1"] {
            store.agents[AgentID(raw)] = Agent(id: AgentID(raw), status: .blocked, enteredAt: now)
        }
        let first = store.attentionAgents.map(\.id.raw)
        #expect(first == ["w1:p1", "w1:p2", "w2:p7", "w3:p1"])

        // Mutating the dictionary (a new pane joins, one leaves) must not
        // reshuffle the rows that were already tied.
        store.agents[AgentID("w0:p1")] = Agent(id: AgentID("w0:p1"), status: .working, enteredAt: now)
        store.agents.removeValue(forKey: AgentID("w2:p7"))
        #expect(store.attentionAgents.map(\.id.raw) == ["w1:p1", "w1:p2", "w3:p1"])
    }

    @Test("Ranks process-gone before silent and includes done in the glance list")
    @MainActor
    func ranksWorstFirst() {
        let store = AgentStore()
        let early = Date().addingTimeInterval(-60)
        store.agents = [
            AgentID("w1:p1"): Agent(
                id: AgentID("w1:p1"),
                status: .working,
                enteredAt: early,
                verdict: .silent(since: early, cpu: nil)
            ),
            AgentID("w1:p2"): Agent(
                id: AgentID("w1:p2"),
                status: .working,
                enteredAt: Date(),
                verdict: .processGone(lastLine: "zsh")
            ),
            AgentID("w1:p3"): Agent(
                id: AgentID("w1:p3"),
                status: .done,
                enteredAt: early,
                verdict: .healthy
            ),
            AgentID("w1:p4"): Agent(
                id: AgentID("w1:p4"),
                status: .working,
                enteredAt: early,
                verdict: .healthy
            ),
        ]
        let ids = store.attentionAgents.map(\.id.raw)
        #expect(ids == ["w1:p2", "w1:p1", "w1:p3"])
        #expect(store.silentCount == 1)
        #expect(store.blockedCount == 0)
    }

    @Test("Stale silent on done ranks with done, not with silence")
    @MainActor
    func staleSilentOnDoneRanksAsDone() {
        let store = AgentStore()
        store.agents = [
            AgentID("done-silent"): Agent(
                id: AgentID("done-silent"),
                status: .done,
                enteredAt: Date().addingTimeInterval(-10),
                verdict: .silent(since: Date(), cpu: nil)
            ),
            AgentID("working-silent"): Agent(
                id: AgentID("working-silent"),
                status: .working,
                enteredAt: Date(),
                verdict: .silent(since: Date(), cpu: nil)
            ),
        ]
        #expect(store.attentionAgents.map(\.id.raw) == ["working-silent", "done-silent"])
        #expect(store.silentCount == 1)
        #expect(store.doneCount == 1)
    }

    @Test("blockedCount ignores a gone pane and silentCount ignores a stale silent-on-blocked verdict")
    @MainActor
    func countsAreMutuallyExclusive() {
        let store = AgentStore()
        store.agents = [
            AgentID("gone"): Agent(
                id: AgentID("gone"),
                status: .blocked,
                verdict: .processGone(lastLine: "zsh")
            ),
            AgentID("blocked"): Agent(
                id: AgentID("blocked"),
                status: .blocked,
                verdict: .silent(since: Date(), cpu: nil)
            ),
            AgentID("silent"): Agent(
                id: AgentID("silent"),
                status: .working,
                verdict: .silent(since: Date(), cpu: nil)
            ),
        ]
        #expect(store.blockedCount == 1)
        #expect(store.silentCount == 1)
    }
}

// MARK: - diagnoseAll race

private final class DiagnoseRaceAdapter: HerdrAdapter, @unchecked Sendable {
    let store: AgentStore
    let agentId: AgentID
    var connectionState: HerdrConnectionState = .connected

    init(store: AgentStore, agentId: AgentID) {
        self.store = store
        self.agentId = agentId
    }

    func snapshot() async throws -> HerdrSnapshot {
        throw NSError(domain: "Mock", code: 1)
    }

    func read(paneId: String, source: PaneReadSource, lines: Int?) async throws -> PaneReadResult {
        throw NSError(domain: "Mock", code: 1)
    }

    func explain(paneId: String) async throws -> AgentExplainResult {
        throw NSError(domain: "Mock", code: 1)
    }

    func processInfo(paneId: String) async throws -> ProcessInfoResult {
        await MainActor.run {
            guard var agent = store.agents[agentId] else { return }
            agent.status = .done
            agent.stateChangeSeq += 1
            store.agents[agentId] = agent
        }
        return ProcessInfoResult(
            shellPid: 1,
            foregroundProcesses: [
                ForegroundProcess(pid: 456, name: "node", argv0: nil, cmdline: nil, cwd: nil)
            ]
        )
    }

    func focus(paneId: String) async throws {}
    func events() -> AsyncStream<HerdrEvent> { AsyncStream { $0.finish() } }
    func sendKeys(paneId: String, keys: [String]) async throws {}
    func prompt(paneId: String, text: String) async throws {}
    func closePane(paneId: String) async throws {}
    func createWorkspace(cwd: String, label: String?) async throws -> WorkspaceCreation {
        throw NSError(domain: "Mock", code: 1)
    }
    func startAgent(paneId: String, kind: String, name: String) async throws {}
    func waitStatus(paneId: String, until: [String], timeoutMs: Int) async throws -> Bool { true }
    func reportMetadata(paneId: String, source: String, tokens: [String: String], ttlMs: Int) async throws {}
}

@Suite("AgentStore.diagnoseAll")
struct DiagnoseAllRaceTests {
    @Test("Does not stamp a silent verdict onto a pane that finished during diagnose")
    @MainActor
    func dropsStaleVerdictAfterStatusChange() async {
        let store = AgentStore()
        let id = AgentID("w1:p1")
        store.agents = [
            id: Agent(
                id: id,
                status: .working,
                stateChangeSeq: 3,
                enteredAt: Date().addingTimeInterval(-30 * 60),
                lastOutputAt: Date().addingTimeInterval(-20 * 60),
                verdict: .healthy
            )
        ]
        let adapter = DiagnoseRaceAdapter(store: store, agentId: id)
        await store.diagnoseAll(adapter: adapter, diagnoser: Diagnoser())
        let agent = store.agents[id]
        #expect(agent?.status == .done)
        #expect(agent?.verdict.isSilent == false)
        #expect(agent?.verdict.isHealthy == true)
    }
}

@Suite("AgentStore.applyRestoredDwell")
struct ApplyRestoredDwellTests {
    @Test("Applies an earlier enteredAt and never moves dwell forward")
    @MainActor
    func dwellNeverMovesForward() {
        let store = AgentStore()
        let later = Date()
        let earlier = later.addingTimeInterval(-120)
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1")))
        var agent = store.agents[AgentID("wA:p1")]!
        agent.enteredAt = later
        agent.lastOutputAt = earlier
        store.agents[AgentID("wA:p1")] = agent

        store.applyRestoredDwell([
            AgentID("wA:p1"): DwellEntry(
                status: .working,
                enteredAt: earlier,
                lastOutputAt: later,
                occupantFingerprint: "claude",
                stateChangeSeq: 1
            )
        ])
        let restored = store.agents[AgentID("wA:p1")]
        #expect(restored?.enteredAt == earlier)
        #expect(restored?.lastOutputAt == later)
    }
}

// MARK: - pane_created

/// Answers every diagnosis call and records which panes were asked about.
/// `processInfo` reports a bare shell, which the diagnoser reads as
/// process-gone for any working/blocked/unknown agent.
private final class RecordingAdapter: HerdrAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var _processInfoPanes: [String] = []
    var connectionState: HerdrConnectionState = .connected

    var processInfoPanes: [String] {
        lock.withLock { _processInfoPanes }
    }

    func snapshot() async throws -> HerdrSnapshot {
        throw NSError(domain: "Mock", code: 1)
    }

    func read(paneId: String, source: PaneReadSource, lines: Int?) async throws -> PaneReadResult {
        throw NSError(domain: "Mock", code: 1)
    }

    func explain(paneId: String) async throws -> AgentExplainResult {
        AgentExplainResult(agent: nil, state: nil, matchedRuleId: nil, screenDetectionSkipped: false)
    }

    func processInfo(paneId: String) async throws -> ProcessInfoResult {
        lock.withLock { _processInfoPanes.append(paneId) }
        return ProcessInfoResult(
            shellPid: 1,
            foregroundProcesses: [ForegroundProcess(pid: 1, name: "zsh", argv0: nil, cmdline: nil, cwd: nil)]
        )
    }

    func focus(paneId: String) async throws {}
    func events() -> AsyncStream<HerdrEvent> { AsyncStream { $0.finish() } }
    func sendKeys(paneId: String, keys: [String]) async throws {}
    func prompt(paneId: String, text: String) async throws {}
    func closePane(paneId: String) async throws {}
    func createWorkspace(cwd: String, label: String?) async throws -> WorkspaceCreation {
        throw NSError(domain: "Mock", code: 1)
    }
    func startAgent(paneId: String, kind: String, name: String) async throws {}
    func waitStatus(paneId: String, until: [String], timeoutMs: Int) async throws -> Bool { true }
    func reportMetadata(paneId: String, source: String, tokens: [String: String], ttlMs: Int) async throws {}
}

@Suite("AgentStore.applyEvent(.paneCreated)")
struct ApplyEventPaneCreatedTests {
    @Test("pane_created alone adds no agent, no attention row, and nothing to diagnose")
    @MainActor
    func paneCreatedAddsNothing() async {
        // The old `.unknown` placeholder was diagnosed like an agent; its
        // bare shell read as process-gone and flashed a red "gone".
        let store = AgentStore()
        let transition = store.applyEvent(.paneCreated(paneId: "wA:p1", workspaceId: "wA", tabId: "wA:t1"))
        #expect(transition == nil)
        #expect(store.agents.isEmpty)
        #expect(store.attentionAgents.isEmpty)

        let adapter = RecordingAdapter()
        await store.diagnoseAll(adapter: adapter, diagnoser: Diagnoser())
        #expect(adapter.processInfoPanes.isEmpty)
        #expect(store.agents.isEmpty)
    }

    @Test("pane_updated after pane_created inserts the real agent")
    @MainActor
    func paneUpdatedInsertsAgent() {
        let store = AgentStore()
        store.applyEvent(.paneCreated(paneId: "wA:p1", workspaceId: "wA", tabId: "wA:t1"))
        let transition = store.applyEvent(.paneUpdated(
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)
        ))

        #expect(transition?.from == nil)
        #expect(transition?.to == .blocked)
        let agent = store.agents[AgentID("wA:p1")]
        #expect(agent?.kind == .custom("claude"))
        #expect(agent?.status == .blocked)
        #expect(store.blockedCount == 1)
    }

    @Test("A pane that stays a plain shell never appears")
    @MainActor
    func shellPaneNeverAppears() async {
        let store = AgentStore()
        store.applyEvent(.paneCreated(paneId: "wA:p1", workspaceId: "wA", tabId: "wA:t1"))
        #expect(store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agent: nil))) == nil)
        #expect(store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agent: ""))) == nil)
        #expect(store.agents.isEmpty)
        #expect(store.attentionAgents.isEmpty)

        let adapter = RecordingAdapter()
        await store.diagnoseAll(adapter: adapter, diagnoser: Diagnoser())
        #expect(adapter.processInfoPanes.isEmpty)
    }
}

@Suite("AgentStore.diagnoseAll ordering")
struct DiagnoseAllOrderingTests {
    @Test("Agents passed as first are diagnosed before the rest")
    @MainActor
    func diagnosesFirstAgentsFirst() async {
        let store = AgentStore()
        for index in 1...6 {
            let id = AgentID("wA:p\(index)")
            store.agents[id] = Agent(id: id, kind: .claude, status: .working, verdict: .healthy)
        }
        store.agents[AgentID("wA:idle")] = Agent(id: AgentID("wA:idle"), kind: .claude, status: .idle)

        let adapter = RecordingAdapter()
        await store.diagnoseAll(
            adapter: adapter,
            diagnoser: Diagnoser(),
            first: [AgentID("wA:p5"), AgentID("wA:p2")]
        )

        let order = adapter.processInfoPanes
        #expect(order.count == 6)
        #expect(Set(order.prefix(2)) == ["wA:p5", "wA:p2"])
        #expect(!order.contains("wA:idle"))
    }
}

// MARK: - applyHerdSnapshot transitions

private func herd(_ infos: [HerdrAgentInfo]) -> HerdSnapshot {
    HerdSnapshot(
        version: "0.7.5", protocol: 17,
        agents: infos,
        workspaceNames: ["wA": "Alpha"], tabNames: ["wA:t1": "main"],
        focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
    )
}

/// The blocked episodes Shepherd would alert for: it notifies on each
/// accepted transition to blocked, keyed by `episodeKey`.
private func blockedAlerts(_ transitions: [AgentStatusTransition?]) -> Set<String> {
    Set(transitions.compactMap { $0 }.filter { $0.to == .blocked }.map(\.episodeKey))
}

@Suite("AgentStore.applyHerdSnapshot transitions")
struct ApplyHerdSnapshotTransitionTests {
    @Test("Reports each accepted status change and each new pane, and nothing for the first snapshot")
    @MainActor
    func reportsAcceptedChanges() {
        let store = AgentStore()
        let first = store.applyHerdSnapshot(herd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4),
            makeAgentInfo(paneId: "wA:p2", agentStatus: "blocked", stateChangeSeq: 2),
        ]))
        // The herd as it was at launch is not news.
        #expect(first.isEmpty)

        let second = store.applyHerdSnapshot(herd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5),
            makeAgentInfo(paneId: "wA:p2", agentStatus: "blocked", stateChangeSeq: 2),
            makeAgentInfo(paneId: "wA:p3", agentStatus: "working", stateChangeSeq: 1),
        ]))
        let byPane = Dictionary(uniqueKeysWithValues: second.map { ($0.agentId.raw, $0) })
        #expect(byPane.count == 2)
        #expect(byPane["wA:p1"]?.from == .working)
        #expect(byPane["wA:p1"]?.to == .blocked)
        #expect(byPane["wA:p1"]?.stateChangeSeq == 5)
        #expect(byPane["wA:p1"]?.enteredAt == store.agents[AgentID("wA:p1")]?.enteredAt)
        #expect(byPane["wA:p3"]?.from == nil)
        #expect(byPane["wA:p3"]?.to == .working)
    }

    @Test("Blocked seen by the poll first and then by its event alerts once")
    @MainActor
    func pollThenEventAlertsOnce() {
        // The poll used to report nothing, and the event then found the
        // status unchanged: the blocked alert was lost.
        let store = AgentStore()
        store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]))

        let poll = store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)]))
        let event = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))

        #expect(poll.map(\.to) == [.blocked])
        #expect(event == nil)
        #expect(blockedAlerts(poll + [event]).count == 1)
    }

    @Test("Blocked seen by the event first and then the poll alerts once and keeps the episode start")
    @MainActor
    func eventThenPollAlertsOnce() {
        let store = AgentStore()
        store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]))

        let event = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))
        let startedAt = store.agents[AgentID("wA:p1")]?.enteredAt
        let poll = store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)]))

        #expect(event?.to == .blocked)
        #expect(poll.isEmpty)
        #expect(blockedAlerts([event] + poll).count == 1)
        // The seq catching up is not a new episode.
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == startedAt)
        #expect(store.agents[AgentID("wA:p1")]?.stateChangeSeq == 5)
    }

    @Test("A poll answered before the blocked event does not roll it back or alert again")
    @MainActor
    func stalePollDoesNotRollBack() {
        // Otherwise: blocked (event) -> working (stale poll) -> blocked
        // (next poll), a second alert for one prompt.
        let store = AgentStore()
        store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]))

        let event = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))
        let stale = store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]))
        #expect(stale.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.status == .blocked)

        let fresh = store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)]))
        #expect(fresh.isEmpty)
        #expect(blockedAlerts([event] + stale + fresh).count == 1)
    }

    @Test("Only one snapshot is taken as stale, so a wrong event is corrected by the next poll")
    @MainActor
    func staleGuardLastsOneSnapshot() {
        // herdr without seqs, or restarted with seqs back at 0, must not
        // leave a pane stuck on an event's status.
        let store = AgentStore()
        store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 0)]))
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))

        #expect(store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 0)])).isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.status == .blocked)

        let next = store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 0)]))
        #expect(next.map(\.to) == [.working])
        #expect(store.agents[AgentID("wA:p1")]?.status == .working)
    }

    @Test("A poll answered before a pane exited does not bring it back blocked")
    @MainActor
    func stalePollDoesNotResurrectExitedPane() {
        let store = AgentStore()
        store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]))
        store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)]))
        store.applyEvent(.paneExited(paneId: "wA:p1"))

        let stale = store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)]))
        #expect(stale.isEmpty)
        #expect(store.agents[AgentID("wA:p1")] == nil)

        #expect(store.applyHerdSnapshot(herd([])).isEmpty)
        #expect(store.agents.isEmpty)
    }

    @Test("A poll answered before a new agent's first event does not drop it or alert twice")
    @MainActor
    func stalePollKeepsEventInsertedPane() {
        let store = AgentStore()
        store.applyHerdSnapshot(herd([]))

        let event = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))
        let startedAt = store.agents[AgentID("wA:p1")]?.enteredAt
        let stale = store.applyHerdSnapshot(herd([]))
        #expect(store.agents[AgentID("wA:p1")]?.status == .blocked)

        let fresh = store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 1)]))
        #expect(fresh.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == startedAt)
        #expect(blockedAlerts([event] + stale + fresh).count == 1)
    }

    @Test("A new blocked agent the poll finds before its event alerts once")
    @MainActor
    func newBlockedAgentFromPoll() {
        let store = AgentStore()
        store.applyHerdSnapshot(herd([]))
        let poll = store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 1)]))
        let event = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))

        #expect(poll.first?.from == nil)
        #expect(event == nil)
        #expect(blockedAlerts(poll + [event]).count == 1)
    }
}

@Suite("AgentStore.applyHerdSnapshot stale guard bounds")
struct ApplyHerdSnapshotStaleBoundTests {
    @Test("A pane an event added that agent.list never lists is dropped after one poll")
    @MainActor
    func unlistedPaneDroppedAfterOnePoll() {
        let store = AgentStore()
        store.applyHerdSnapshot(herd([]))
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 0)))

        store.applyHerdSnapshot(herd([]))
        #expect(store.agents[AgentID("wA:p1")] != nil)
        store.applyHerdSnapshot(herd([]))
        #expect(store.agents[AgentID("wA:p1")] == nil)
    }
}
