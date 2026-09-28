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
    title: String? = "Claude",
    displayAgent: String? = nil,
    name: String? = nil,
    terminalTitleStripped: String? = nil,
    session: HerdrSnapshot.AgentSession? = nil,
    cwd: String? = "/tmp",
    foregroundCwd: String? = "/tmp",
    paneLabel: String? = nil
) -> HerdrAgentInfo {
    HerdrAgentInfo(
        paneId: paneId,
        workspaceId: workspaceId,
        tabId: tabId,
        agent: agent,
        displayAgent: displayAgent,
        name: name,
        title: title,
        terminalTitleStripped: terminalTitleStripped ?? title,
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
        launchPending: false,
        paneLabel: paneLabel
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
        #expect(AttentionTriage.kind(for: blockedSilent) == .blocked)
        #expect(AttentionTriage.kind(for: goneSilent) == .gone)
        #expect(AttentionTriage.kind(for: doneSilent) == .done)
        #expect(AttentionTriage.kind(for: idleSilent) == .idle)
        #expect(AttentionTriage.kind(for: workingSilent) == .silent)
    }

    @Test("A crashed pane is not drawn or counted as blocked")
    func goneMarkAndFooterAreNotBlocked() {
        let crashedWhileBlocked = Agent(
            id: AgentID("crash-blocked"),
            status: .blocked,
            verdict: .processGone(lastLine: "zsh")
        )
        let crashedWhileWorking = Agent(
            id: AgentID("crash-working"),
            status: .working,
            verdict: .processGone(lastLine: "zsh")
        )
        let crashedUnknown = Agent(
            id: AgentID("crash-unknown"),
            status: .unknown,
            verdict: .processGone(lastLine: "zsh")
        )
        let blocked = Agent(id: AgentID("blocked"), status: .blocked)
        let silent = Agent(
            id: AgentID("silent"),
            status: .working,
            verdict: .silent(since: Date(), cpu: nil)
        )
        let done = Agent(id: AgentID("done"), status: .done, verdict: .healthy)
        let working = Agent(id: AgentID("working"), status: .working, verdict: .healthy)
        let idle = Agent(id: AgentID("idle"), status: .idle, verdict: .healthy)
        let unknown = Agent(id: AgentID("unknown"), status: .unknown)

        #expect(AttentionTriage.kind(for: crashedWhileBlocked) == .gone)
        #expect(AttentionTriage.kind(for: crashedWhileWorking) == .gone)
        #expect(AttentionTriage.kind(for: crashedUnknown) == .gone)
        #expect(AttentionTriage.kind(for: blocked) == .blocked)
        #expect(AttentionTriage.kind(for: silent) == .silent)
        #expect(AttentionTriage.kind(for: done) == .done)
        #expect(AttentionTriage.kind(for: working) == .working)
        #expect(AttentionTriage.kind(for: idle) == .idle)
        #expect(AttentionTriage.kind(for: unknown) == .unknown)
        #expect(AttentionTriage.kind(for: crashedWhileBlocked).rawValue == "gone")

        #expect(AttentionTriage.statusMark(for: crashedWhileBlocked) == "GONE")
        #expect(AttentionTriage.statusMark(for: crashedWhileWorking) == "GONE")
        #expect(AttentionTriage.statusMark(for: blocked) == "🔴")
        #expect(AttentionTriage.statusMark(for: silent) == "🟠")
        #expect(AttentionTriage.statusMark(for: done) == "🔵")
        #expect(AttentionTriage.statusMark(for: working) == "🟢")
        #expect(AttentionTriage.statusMark(for: working, working: "🟡") == "🟡")
        #expect(AttentionTriage.statusMark(for: idle) == "🟢")
        #expect(AttentionTriage.statusMark(for: unknown) == "⚪")
        #expect(
            AttentionTriage.statusMark(for: crashedWhileBlocked)
                != AttentionTriage.statusMark(for: blocked)
        )
        // The working override does not recolor a crash or an idle pane.
        #expect(AttentionTriage.statusMark(for: crashedWhileWorking, working: "🟡") == "GONE")
        #expect(AttentionTriage.statusMark(for: idle, working: "🟡") == "🟢")

        let counts = AttentionTriage.counts([
            crashedWhileBlocked, crashedWhileWorking, blocked, silent, done, working, idle, unknown,
        ])
        #expect(counts.gone == 2)
        #expect(counts.blocked == 1)
        #expect(counts.silent == 1)
        #expect(counts.done == 1)
        #expect(counts.working == 1)
        #expect(AttentionTriage.statusFooter(agentCount: 8, counts: counts)
            == "8 agents | 1 blocked | 2 gone | 1 silent | 1 done")
        // A herd whose only attention is a crash used to read as nothing.
        let onlyGone = AttentionTriage.counts([crashedWhileBlocked])
        #expect(AttentionTriage.statusFooter(agentCount: 1, counts: onlyGone)
            == "1 agents | 0 blocked | 1 gone | 0 silent | 0 done")
    }

    @Test("A crash is not running or finished, and a quiet worker still is")
    func runningExcludesProcessGone() {
        let crashedWorking = Agent(
            id: AgentID("crash-working"),
            status: .working,
            verdict: .processGone(lastLine: "zsh")
        )
        let crashedDone = Agent(
            id: AgentID("crash-done"),
            status: .done,
            verdict: .processGone(lastLine: "zsh")
        )
        let quiet = Agent(
            id: AgentID("quiet"),
            status: .working,
            verdict: .silent(since: Date(), cpu: nil)
        )
        let working = Agent(id: AgentID("working"), status: .working, verdict: .healthy)
        let finished = Agent(id: AgentID("done"), status: .done, verdict: .healthy)
        let blocked = Agent(id: AgentID("blocked"), status: .blocked, verdict: .healthy)
        let crashedBlocked = Agent(
            id: AgentID("crash-blocked"),
            status: .blocked,
            verdict: .processGone(lastLine: "zsh")
        )

        #expect(!AttentionTriage.isRunning(crashedWorking))
        #expect(!AttentionTriage.isRunning(crashedDone))
        #expect(!AttentionTriage.isRunning(finished))
        #expect(!AttentionTriage.isRunning(blocked))
        #expect(!AttentionTriage.isRunning(crashedBlocked))
        #expect(AttentionTriage.isRunning(quiet))
        #expect(AttentionTriage.isRunning(working))

        #expect(!AttentionTriage.isFinished(crashedDone))
        #expect(!AttentionTriage.isFinished(crashedWorking))
        #expect(!AttentionTriage.isFinished(quiet))
        #expect(AttentionTriage.isFinished(finished))

        // The header used to count the crash twice: needs-you and running,
        // or needs-you and done. The running list is the same predicate.
        #expect(AttentionTriage.needsYou(crashedWorking))
        #expect(AttentionTriage.needsYou(crashedDone))
        #expect(AttentionTriage.needsYou(quiet))
        #expect(!AttentionTriage.needsYou(working))
        #expect(!AttentionTriage.needsYou(finished))
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

/// `processInfo` replaces the pane's session with `replacement` before the
/// verdict is applied. The read itself still describes the occupant the
/// pass started with.
private final class SessionSwapAdapter: HerdrAdapter, @unchecked Sendable {
    let store: AgentStore
    let replacement: HerdSnapshot
    let foreground: ProcessInfoResult
    var connectionState: HerdrConnectionState = .connected

    init(store: AgentStore, replacement: HerdSnapshot, foreground: ProcessInfoResult) {
        self.store = store
        self.replacement = replacement
        self.foreground = foreground
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
            let stamp = store.captureHerdRequest()
            _ = store.applyHerdSnapshot(
                replacement,
                requestedAtEpoch: stamp.epoch,
                requestedAtSerial: stamp.serial
            )
        }
        return foreground
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

@Suite("AgentStore.diagnoseAll session occupant")
struct DiagnoseAllSessionTests {
    @Test("A process-gone read is not stamped onto the session that replaced the pane")
    @MainActor
    func processGoneDoesNotLandOnTheNewSession() async throws {
        let store = AgentStore()
        let id = AgentID("wA:p1")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(
            labeledHerd([
                makeAgentInfo(
                    paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4,
                    session: session("abc")
                )
            ]),
            requestedAtEpoch: seed.epoch,
            requestedAtSerial: seed.serial
        )
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        try pinEpisode(
            store, id: id,
            enteredAt: entered, lastOutputAt: entered,
            verdict: .healthy
        )
        let adapter = SessionSwapAdapter(
            store: store,
            replacement: labeledHerd([
                makeAgentInfo(
                    paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4,
                    session: session("other")
                )
            ]),
            foreground: diagnosisBareShell
        )
        await store.diagnoseAll(adapter: adapter, diagnoser: Diagnoser())
        let agent = try #require(store.agents[id])
        #expect(agent.enteredAt != entered)
        #expect(agent.verdict.isProcessGone == false)
        #expect(agent.verdict.isHealthy == true)
        #expect(store.sessionIdentity(for: id) == "agent|claude|session|other")
    }

    @Test("Learning the session during the read still applies that read")
    @MainActor
    func firstSessionStillTakesTheVerdict() async throws {
        let store = AgentStore()
        let id = AgentID("wA:p1")
        let output = Date().addingTimeInterval(-20 * 60)
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(
            labeledHerd([
                makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)
            ]),
            requestedAtEpoch: seed.epoch,
            requestedAtSerial: seed.serial
        )
        try pinEpisode(
            store, id: id,
            enteredAt: output.addingTimeInterval(-10 * 60), lastOutputAt: output,
            verdict: .healthy
        )
        let adapter = SessionSwapAdapter(
            store: store,
            replacement: labeledHerd([
                makeAgentInfo(
                    paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4,
                    session: session("abc")
                )
            ]),
            foreground: nodeRuntime
        )
        await store.diagnoseAll(adapter: adapter, diagnoser: Diagnoser())
        let agent = try #require(store.agents[id])
        #expect(agent.enteredAt == output.addingTimeInterval(-10 * 60))
        guard case .silent(let since, _) = agent.verdict else {
            Issue.record("Expected the read to land as silent, got \(agent.verdict)")
            return
        }
        #expect(since == output)
        #expect(store.sessionIdentity(for: id) == "agent|claude|session|abc")
    }
}

// MARK: - silence vs output observed during the pass

private let nodeRuntime = ProcessInfoResult(
    shellPid: 1,
    foregroundProcesses: [
        ForegroundProcess(pid: 456, name: "node", argv0: nil, cmdline: nil, cwd: nil)
    ]
)

private let diagnosisBareShell = ProcessInfoResult(
    shellPid: 1,
    foregroundProcesses: [
        ForegroundProcess(pid: 1, name: "zsh", argv0: nil, cmdline: nil, cwd: nil)
    ]
)

/// `processInfo` for `triggerPaneId` writes `outputAt` onto `target`.
/// Diagnosis reads the agent copy from the start of the pass, so this is
/// the heartbeat landing while that pass is still in flight.
private final class OutputClockAdapter: HerdrAdapter, @unchecked Sendable {
    let store: AgentStore
    let foreground: ProcessInfoResult
    let triggerPaneId: String?
    let target: AgentID?
    let outputAt: Date?
    var connectionState: HerdrConnectionState = .connected

    init(
        store: AgentStore,
        foreground: ProcessInfoResult,
        triggerPaneId: String? = nil,
        target: AgentID? = nil,
        outputAt: Date? = nil
    ) {
        self.store = store
        self.foreground = foreground
        self.triggerPaneId = triggerPaneId
        self.target = target
        self.outputAt = outputAt
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
        if paneId == triggerPaneId, let target, let outputAt {
            await MainActor.run {
                guard var agent = store.agents[target] else { return }
                agent.lastOutputAt = outputAt
                store.agents[target] = agent
            }
        }
        return foreground
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

private func quietWorkingAgent(
    id: AgentID,
    lastOutputAt: Date,
    verdict: Verdict = .healthy
) -> Agent {
    Agent(
        id: id,
        kind: .claude,
        status: .working,
        stateChangeSeq: 4,
        enteredAt: lastOutputAt.addingTimeInterval(-10 * 60),
        lastOutputAt: lastOutputAt,
        verdict: verdict
    )
}

@Suite("AgentStore silence and a moved output clock")
struct SilenceOutputClockTests {
    @Test("Output during this pane's read does not stamp the silence that read measured")
    @MainActor
    func outputDuringReadClearsSilence() async {
        let store = AgentStore()
        let id = AgentID("w1:p1")
        let staleOutput = Date().addingTimeInterval(-20 * 60)
        let freshOutput = Date()
        store.agents = [
            id: quietWorkingAgent(
                id: id,
                lastOutputAt: staleOutput,
                verdict: .silent(since: staleOutput, cpu: nil)
            )
        ]
        let adapter = OutputClockAdapter(
            store: store,
            foreground: nodeRuntime,
            triggerPaneId: id.raw,
            target: id,
            outputAt: freshOutput
        )
        await store.diagnoseAll(adapter: adapter, diagnoser: Diagnoser())
        let agent = store.agents[id]
        #expect(agent?.lastOutputAt == freshOutput)
        #expect(agent?.verdict.isHealthy == true)
        #expect(agent?.verdict.isSilent == false)
    }

    @Test("Output during an earlier pane's read is not a silence on the later pane")
    @MainActor
    func outputDuringEarlierReadClearsLaterPane() async {
        let store = AgentStore()
        let earlier = AgentID("w1:p1")
        let later = AgentID("w1:p2")
        let staleOutput = Date().addingTimeInterval(-20 * 60)
        let freshOutput = Date()
        store.agents = [
            earlier: quietWorkingAgent(id: earlier, lastOutputAt: staleOutput),
            later: quietWorkingAgent(
                id: later,
                lastOutputAt: staleOutput,
                verdict: .silent(since: staleOutput, cpu: .deadlocked)
            )
        ]
        let adapter = OutputClockAdapter(
            store: store,
            foreground: nodeRuntime,
            triggerPaneId: earlier.raw,
            target: later,
            outputAt: freshOutput
        )
        await store.diagnoseAll(
            adapter: adapter,
            diagnoser: Diagnoser(),
            first: [earlier]
        )
        let kept = store.agents[earlier]
        guard case .silent(let since, _) = kept?.verdict else {
            Issue.record("Expected the untouched pane to stay silent, got \(String(describing: kept?.verdict))")
            return
        }
        #expect(since == staleOutput)
        let moved = store.agents[later]
        #expect(moved?.lastOutputAt == freshOutput)
        #expect(moved?.verdict.isHealthy == true)
        #expect(moved?.verdict.isSilent == false)
    }

    @Test("A clock that moved and is still past the threshold names the new output")
    @MainActor
    func stillQuietClockUsesTheNewOutput() async {
        let store = AgentStore()
        let id = AgentID("w1:p1")
        let staleOutput = Date().addingTimeInterval(-20 * 60)
        let stillQuiet = Date().addingTimeInterval(-10 * 60)
        store.agents = [
            id: quietWorkingAgent(id: id, lastOutputAt: staleOutput)
        ]
        let adapter = OutputClockAdapter(
            store: store,
            foreground: nodeRuntime,
            triggerPaneId: id.raw,
            target: id,
            outputAt: stillQuiet
        )
        await store.diagnoseAll(adapter: adapter, diagnoser: Diagnoser())
        let agent = store.agents[id]
        guard case .silent(let since, _) = agent?.verdict else {
            Issue.record("Expected silent from the new clock, got \(String(describing: agent?.verdict))")
            return
        }
        #expect(since == stillQuiet)
        #expect(agent?.lastOutputAt == stillQuiet)
    }

    @Test("A quiet pane whose clock did not move is silent from that output")
    @MainActor
    func unchangedClockStaysSilent() async {
        let store = AgentStore()
        let id = AgentID("w1:p1")
        let output = Date().addingTimeInterval(-20 * 60)
        store.agents = [
            id: quietWorkingAgent(id: id, lastOutputAt: output)
        ]
        let adapter = OutputClockAdapter(store: store, foreground: nodeRuntime)
        await store.diagnoseAll(adapter: adapter, diagnoser: Diagnoser())
        let agent = store.agents[id]
        guard case .silent(let since, _) = agent?.verdict else {
            Issue.record("Expected silent, got \(String(describing: agent?.verdict))")
            return
        }
        #expect(since == output)
    }

    @Test("Process-gone still lands when output moved during the read")
    @MainActor
    func processGoneSurvivesAMovedClock() async {
        let store = AgentStore()
        let id = AgentID("w1:p1")
        let staleOutput = Date().addingTimeInterval(-20 * 60)
        let freshOutput = Date()
        store.agents = [
            id: quietWorkingAgent(id: id, lastOutputAt: staleOutput)
        ]
        let adapter = OutputClockAdapter(
            store: store,
            foreground: diagnosisBareShell,
            triggerPaneId: id.raw,
            target: id,
            outputAt: freshOutput
        )
        await store.diagnoseAll(adapter: adapter, diagnoser: Diagnoser())
        let agent = store.agents[id]
        #expect(agent?.verdict.isProcessGone == true)
        #expect(agent?.verdict.isSilent == false)
        #expect(agent?.lastOutputAt == freshOutput)
    }
}

@Suite("AgentStore.applyObservedOutput")
struct ApplyObservedOutputTests {
    @Test("Newer output ends the silence the row is showing")
    @MainActor
    func newerOutputClearsSilence() {
        let store = AgentStore()
        let id = AgentID("w1:p1")
        let old = Date().addingTimeInterval(-20 * 60)
        let now = Date()
        store.agents = [
            id: quietWorkingAgent(
                id: id,
                lastOutputAt: old,
                verdict: .silent(since: old, cpu: nil)
            )
        ]
        store.applyObservedOutput([id: now])
        let agent = store.agents[id]
        #expect(agent?.lastOutputAt == now)
        #expect(agent?.verdict.isHealthy == true)
    }

    @Test("An older time does not move the clock or clear the silence")
    @MainActor
    func olderOutputIsIgnored() {
        let store = AgentStore()
        let id = AgentID("w1:p1")
        let current = Date().addingTimeInterval(-10 * 60)
        store.agents = [
            id: quietWorkingAgent(
                id: id,
                lastOutputAt: current,
                verdict: .silent(since: current, cpu: nil)
            )
        ]
        store.applyObservedOutput([id: current.addingTimeInterval(-60)])
        let agent = store.agents[id]
        #expect(agent?.lastOutputAt == current)
        #expect(agent?.verdict.isSilent == true)
    }

    @Test("Output from before the episode does not end a silence measured from its start")
    @MainActor
    func outputBeforeTheEpisodeKeepsSilence() {
        let store = AgentStore()
        let id = AgentID("w1:p1")
        let entered = Date().addingTimeInterval(-10 * 60)
        var agent = quietWorkingAgent(
            id: id,
            lastOutputAt: entered.addingTimeInterval(-30 * 60),
            verdict: .silent(since: entered, cpu: nil)
        )
        agent.enteredAt = entered
        store.agents = [id: agent]
        let stillBefore = entered.addingTimeInterval(-60)
        store.applyObservedOutput([id: stillBefore])
        let updated = store.agents[id]
        #expect(updated?.lastOutputAt == stillBefore)
        guard case .silent(let since, _) = updated?.verdict else {
            Issue.record("Expected the episode silence to stay, got \(String(describing: updated?.verdict))")
            return
        }
        #expect(since == entered)
    }

    @Test("Output does not clear a process-gone verdict")
    @MainActor
    func outputLeavesProcessGone() {
        let store = AgentStore()
        let id = AgentID("w1:p1")
        var agent = quietWorkingAgent(id: id, lastOutputAt: Date().addingTimeInterval(-20 * 60))
        agent.verdict = .processGone(lastLine: "zsh (pid 1)")
        store.agents = [id: agent]
        let now = Date()
        store.applyObservedOutput([id: now])
        let updated = store.agents[id]
        #expect(updated?.lastOutputAt == now)
        #expect(updated?.verdict.isProcessGone == true)
    }

    @Test("An unknown pane is ignored")
    @MainActor
    func unknownPaneIsIgnored() {
        let store = AgentStore()
        store.applyObservedOutput([AgentID("w1:missing"): Date()])
        #expect(store.agents.isEmpty)
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

    @Test("A restored session is the occupant the next list replaces")
    @MainActor
    func restoredSessionOpensTheNextEpisode() throws {
        let store = AgentStore()
        let id = AgentID("wA:p1")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        store.applyRestoredDwell([
            id: DwellEntry(
                status: .blocked,
                enteredAt: earlier,
                lastOutputAt: nil,
                occupantFingerprint: "custom:claude",
                stateChangeSeq: 5,
                sessionIdentity: "agent|claude|session|abc"
            )
        ])
        let seeded = try #require(store.agents[id])
        #expect(seeded.enteredAt == earlier)
        #expect(seeded.sessionIdentity == "agent|claude|session|abc")
        #expect(store.sessionIdentity(for: id) == "agent|claude|session|abc")

        let same = store.captureHerdRequest()
        let kept = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: session("abc")),
        ]), requestedAtEpoch: same.epoch, requestedAtSerial: same.serial)
        #expect(kept.isEmpty)
        #expect(store.agents[id]?.enteredAt == earlier)
        #expect(store.agents[id]?.sessionIdentity == "agent|claude|session|abc")

        let next = store.captureHerdRequest()
        let replaced = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: session("other")),
        ]), requestedAtEpoch: next.epoch, requestedAtSerial: next.serial)
        #expect(replaced.count == 1)
        let row = try #require(store.agents[id])
        #expect(row.enteredAt != earlier)
        #expect(row.sessionIdentity == "agent|claude|session|other")
        #expect(store.sessionIdentity(for: id) == "agent|claude|session|other")
    }

    @Test("A dwell saved for another session does not move a row that already named one")
    @MainActor
    func restoredSessionDoesNotReplaceALiveOne() throws {
        let store = AgentStore()
        let id = AgentID("wA:p1")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: session("other")),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let live = try #require(store.agents[id])
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        store.applyRestoredDwell([
            id: DwellEntry(
                status: .blocked,
                enteredAt: earlier,
                lastOutputAt: nil,
                occupantFingerprint: "custom:claude",
                stateChangeSeq: 5,
                sessionIdentity: "agent|claude|session|abc"
            )
        ])
        let row = try #require(store.agents[id])
        #expect(row.enteredAt == live.enteredAt)
        #expect(row.sessionIdentity == "agent|claude|session|other")
        #expect(store.sessionIdentity(for: id) == "agent|claude|session|other")
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

/// One optional transition as a list, so it concatenates with the arrays
/// `applyHerdSnapshot` returns.
private func present(_ transition: AgentStatusTransition?) -> [AgentStatusTransition] {
    guard let transition else { return [] }
    return [transition]
}

/// The blocked episodes Shepherd would alert for: it notifies on each
/// accepted transition to blocked, keyed by `episodeKey`.
private func blockedAlerts(_ transitions: [AgentStatusTransition]) -> Set<String> {
    Set(transitions.filter { $0.to == .blocked }.map(\.episodeKey))
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
        #expect(blockedAlerts(poll + present(event)).count == 1)
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
        #expect(blockedAlerts(present(event) + poll).count == 1)
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
        #expect(blockedAlerts(present(event) + stale + fresh).count == 1)
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
        #expect(blockedAlerts(present(event) + stale + fresh).count == 1)
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
        #expect(blockedAlerts(poll + present(event)).count == 1)
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

    @Test("Two snapshots requested before a blocked event do not roll it back or alert again")
    @MainActor
    func twoInFlightSnapshotsDoNotRollBack() {
        // The 3s poll and a resync (or an Approve/Deny re-read) can both
        // have been sent before the event. Ignoring only the first one
        // turned blocked back into working, and the next poll alerted again.
        let store = AgentStore()
        let before = store.currentHerdEpoch
        store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]),
            requestedAtEpoch: before
        )

        let event = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))
        let after = store.currentHerdEpoch
        let startedAt = store.agents[AgentID("wA:p1")]?.enteredAt
        #expect(after > before)

        let first = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]),
            requestedAtEpoch: before
        )
        let second = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]),
            requestedAtEpoch: before
        )
        #expect(first.isEmpty)
        #expect(second.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.status == .blocked)
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == startedAt)

        let fresh = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)]),
            requestedAtEpoch: after
        )
        #expect(fresh.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == startedAt)
        #expect(store.agents[AgentID("wA:p1")]?.stateChangeSeq == 5)
        #expect(blockedAlerts(present(event) + fresh).count == 1)

        // The poll that was in flight before the event can return last.
        let late = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]),
            requestedAtEpoch: before
        )
        #expect(late.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.status == .blocked)
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == startedAt)
        #expect(blockedAlerts(present(event) + fresh + late).count == 1)
    }

    @Test("A slow pre-event snapshot does not replace a newer seq already applied")
    @MainActor
    func lateSnapshotDoesNotReplaceNewerSeq() {
        // The poll that started after the block can move on to working
        // (seq 6) before the poll that was in flight before the block
        // returns the intermediate blocked row (seq 5). That late row
        // must not alert a second time.
        let store = AgentStore()
        let before = store.currentHerdEpoch
        store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]),
            requestedAtEpoch: before
        )
        let event = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))
        let after = store.currentHerdEpoch

        let movedOn = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 6)]),
            requestedAtEpoch: after
        )
        #expect(movedOn.map(\.to) == [.working])

        let late = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)]),
            requestedAtEpoch: before
        )
        #expect(late.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.status == .working)
        #expect(store.agents[AgentID("wA:p1")]?.stateChangeSeq == 6)
        #expect(blockedAlerts(present(event) + movedOn + late).count == 1)
    }

    @Test("A snapshot requested after the event corrects a seq-less wrong status")
    @MainActor
    func postEventSnapshotCorrectsWrongEvent() {
        // herdr without seqs, or restarted back at 0, must not leave the
        // pane stuck on the event. The poll that started after the event
        // is the one that counts; an earlier in-flight poll does not.
        let store = AgentStore()
        let before = store.currentHerdEpoch
        store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 0)]),
            requestedAtEpoch: before
        )
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))
        let after = store.currentHerdEpoch

        #expect(store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 0)]),
            requestedAtEpoch: before
        ).isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.status == .blocked)

        let corrected = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 0)]),
            requestedAtEpoch: after
        )
        #expect(corrected.map(\.to) == [.working])
        #expect(store.agents[AgentID("wA:p1")]?.status == .working)
    }

    @Test("Two snapshots requested before a pane exit do not bring it back")
    @MainActor
    func twoInFlightSnapshotsDoNotResurrect() {
        let store = AgentStore()
        let before = store.currentHerdEpoch
        store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]),
            requestedAtEpoch: before
        )
        store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)]),
            requestedAtEpoch: before
        )
        store.applyEvent(.paneExited(paneId: "wA:p1"))
        let after = store.currentHerdEpoch

        let first = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)]),
            requestedAtEpoch: before
        )
        let second = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)]),
            requestedAtEpoch: before
        )
        #expect(first.isEmpty)
        #expect(second.isEmpty)
        #expect(store.agents[AgentID("wA:p1")] == nil)

        #expect(store.applyHerdSnapshot(herd([]), requestedAtEpoch: after).isEmpty)
        let late = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)]),
            requestedAtEpoch: before
        )
        #expect(late.isEmpty)
        #expect(store.agents[AgentID("wA:p1")] == nil)
    }

    @Test("Snapshots requested before an insert keep the agent; one requested after can drop it")
    @MainActor
    func inFlightEmptySnapshotsKeepInsertedAgent() {
        let store = AgentStore()
        let before = store.currentHerdEpoch
        store.applyHerdSnapshot(herd([]), requestedAtEpoch: before)
        let event = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))
        let after = store.currentHerdEpoch
        let startedAt = store.agents[AgentID("wA:p1")]?.enteredAt

        #expect(store.applyHerdSnapshot(herd([]), requestedAtEpoch: before).isEmpty)
        #expect(store.applyHerdSnapshot(herd([]), requestedAtEpoch: before).isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.status == .blocked)
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == startedAt)

        let fresh = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 1)]),
            requestedAtEpoch: after
        )
        #expect(fresh.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == startedAt)
        #expect(blockedAlerts(present(event) + fresh).count == 1)

        // A later poll that started after the insert and still does not
        // list the pane drops it. The pre-insert list, returning last,
        // does not put it back.
        #expect(store.applyHerdSnapshot(herd([]), requestedAtEpoch: after).isEmpty)
        #expect(store.agents[AgentID("wA:p1")] == nil)
        let late = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)]),
            requestedAtEpoch: before
        )
        #expect(late.isEmpty)
        #expect(store.agents[AgentID("wA:p1")] == nil)
    }

    @Test("An event on one pane does not freeze another pane's snapshot row")
    @MainActor
    func eventOnOnePaneDoesNotFreezeAnother() {
        let store = AgentStore()
        let before = store.currentHerdEpoch
        store.applyHerdSnapshot(herd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4),
            makeAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 2),
        ]), requestedAtEpoch: before)
        store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))

        let transitions = store.applyHerdSnapshot(herd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4),
            makeAgentInfo(paneId: "wA:p2", agentStatus: "blocked", stateChangeSeq: 3),
        ]), requestedAtEpoch: before)

        #expect(store.agents[AgentID("wA:p1")]?.status == .blocked)
        #expect(store.agents[AgentID("wA:p2")]?.status == .blocked)
        #expect(transitions.map(\.agentId.raw) == ["wA:p2"])
        #expect(transitions.first?.from == .working)
    }

    @Test("Once the event's snapshot has landed, a later seq bump starts a new dwell without a second alert")
    @MainActor
    func seqBumpAfterCatchUpStartsNewDwell() throws {
        let store = AgentStore()
        let before = store.currentHerdEpoch
        store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]),
            requestedAtEpoch: before
        )
        let event = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))
        let startedAt = store.agents[AgentID("wA:p1")]?.enteredAt
        let after = store.currentHerdEpoch

        let catchUp = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)]),
            requestedAtEpoch: after
        )
        #expect(catchUp.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == startedAt)

        var agent = try #require(store.agents[AgentID("wA:p1")])
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        agent.enteredAt = pinned
        store.agents[AgentID("wA:p1")] = agent

        let bumped = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 6)]),
            requestedAtEpoch: after
        )
        #expect(bumped.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.stateChangeSeq == 6)
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt != pinned)
        #expect(blockedAlerts(present(event) + catchUp + bumped).count == 1)
    }

    @Test("Request serials do not retire the event guard when the reads finish in order")
    @MainActor
    func serialsKeepTheEventGuard() {
        // Production passes a serial on every read. The epoch guard has to
        // keep working for those, not only for callers that omit it.
        let store = AgentStore()
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]),
            requestedAtEpoch: seed.epoch,
            requestedAtSerial: seed.serial
        )
        let inFlight = store.captureHerdRequest()
        let event = store.applyEvent(.paneUpdated(makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0)))
        let startedAt = store.agents[AgentID("wA:p1")]?.enteredAt
        let after = store.captureHerdRequest()
        #expect(inFlight.epoch < after.epoch)
        #expect(inFlight.serial < after.serial)

        let stale = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]),
            requestedAtEpoch: inFlight.epoch,
            requestedAtSerial: inFlight.serial
        )
        #expect(stale.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.status == .blocked)
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == startedAt)

        let fresh = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)]),
            requestedAtEpoch: after.epoch,
            requestedAtSerial: after.serial
        )
        #expect(fresh.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.stateChangeSeq == 5)
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == startedAt)
        #expect(blockedAlerts(present(event) + fresh).count == 1)
    }

    @Test("Two reads that share an epoch apply in capture order, not return order")
    @MainActor
    func sameEpochSnapshotAppliesInCaptureOrder() {
        // No event lands between the captures, so the epoch cannot order
        // them. The read that started second has the higher seq and can
        // return first; the slower one must not turn blocked back into
        // working, or the next poll alerts again.
        let store = AgentStore()
        store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4, title: "Before")]))
        let epochBefore = store.currentHerdEpoch
        let first = store.captureHerdRequest()
        let second = store.captureHerdRequest()
        #expect(first.epoch == epochBefore)
        #expect(second.epoch == first.epoch)
        #expect(second.serial == first.serial + 1)

        let newer = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, title: "After")]),
            requestedAtEpoch: second.epoch,
            requestedAtSerial: second.serial
        )
        let startedAt = store.agents[AgentID("wA:p1")]?.enteredAt
        #expect(newer.map(\.to) == [.blocked])

        let older = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4, title: "Before")]),
            requestedAtEpoch: first.epoch,
            requestedAtSerial: first.serial
        )
        #expect(older.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.status == .blocked)
        #expect(store.agents[AgentID("wA:p1")]?.stateChangeSeq == 5)
        #expect(store.agents[AgentID("wA:p1")]?.name == "After")
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == startedAt)
        #expect(store.lastAppliedHerdRequestSerial == second.serial)
        #expect(blockedAlerts(newer + older).count == 1)
    }

    @Test("A later read with a lower seq still wins when it returns last")
    @MainActor
    func laterReadAppliesRestartedSeq() {
        // A herdr restart resets state_change_seq. Ordering reads by seq
        // would keep the dead process's row. Capture order lets the later
        // read through.
        let store = AgentStore()
        store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 8)]))
        let beforeRestart = store.captureHerdRequest()
        let afterRestart = store.captureHerdRequest()

        let older = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 9)]),
            requestedAtEpoch: beforeRestart.epoch,
            requestedAtSerial: beforeRestart.serial
        )
        #expect(older.map(\.to) == [.working])

        let restarted = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "idle", stateChangeSeq: 1)]),
            requestedAtEpoch: afterRestart.epoch,
            requestedAtSerial: afterRestart.serial
        )
        #expect(restarted.map(\.to) == [.idle])
        #expect(store.agents[AgentID("wA:p1")]?.stateChangeSeq == 1)
        #expect(store.lastAppliedHerdRequestSerial == afterRestart.serial)
    }

    @Test("A pre-restart read that returns last cannot restore the old seq")
    @MainActor
    func earlyReadCannotRestoreSeqAfterRestart() {
        let store = AgentStore()
        store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 10)]))
        let beforeRestart = store.captureHerdRequest()
        let afterRestart = store.captureHerdRequest()

        let restarted = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "idle", stateChangeSeq: 1)]),
            requestedAtEpoch: afterRestart.epoch,
            requestedAtSerial: afterRestart.serial
        )
        #expect(restarted.map(\.to) == [.idle])
        let startedAt = store.agents[AgentID("wA:p1")]?.enteredAt

        let late = store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 10)]),
            requestedAtEpoch: beforeRestart.epoch,
            requestedAtSerial: beforeRestart.serial
        )
        #expect(late.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.status == .idle)
        #expect(store.agents[AgentID("wA:p1")]?.stateChangeSeq == 1)
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == startedAt)
        #expect(store.lastAppliedHerdRequestSerial == afterRestart.serial)
    }

    @Test("An earlier read cannot resurrect a pane a later read dropped")
    @MainActor
    func earlyReadCannotResurrectDroppedPane() {
        let store = AgentStore()
        store.applyHerdSnapshot(herd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4),
            makeAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 2),
        ]))
        let first = store.captureHerdRequest()
        let second = store.captureHerdRequest()

        store.applyHerdSnapshot(
            herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)]),
            requestedAtEpoch: second.epoch,
            requestedAtSerial: second.serial
        )
        #expect(store.agents[AgentID("wA:p2")] == nil)

        let late = store.applyHerdSnapshot(
            herd([
                makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4),
                makeAgentInfo(paneId: "wA:p2", agentStatus: "blocked", stateChangeSeq: 3),
            ]),
            requestedAtEpoch: first.epoch,
            requestedAtSerial: first.serial
        )
        #expect(late.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.status == .working)
        #expect(store.agents[AgentID("wA:p2")] == nil)
    }

    @Test("A snapshot with no request serial can still apply a lower seq")
    @MainActor
    func nilSerialStillAppliesLowerSeq() {
        // Callers that do not opt in keep completion order, including a
        // restart whose seq reset arrives as the next snapshot.
        let store = AgentStore()
        store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 10)]))
        let restarted = store.applyHerdSnapshot(herd([makeAgentInfo(paneId: "wA:p1", agentStatus: "idle", stateChangeSeq: 1)]))
        #expect(restarted.map(\.to) == [.idle])
        #expect(store.agents[AgentID("wA:p1")]?.stateChangeSeq == 1)
        #expect(store.lastAppliedHerdRequestSerial == 0)
    }
}

private func labeledHerd(_ infos: [HerdrAgentInfo]) -> HerdSnapshot {
    HerdSnapshot(
        version: "0.7.5", protocol: 17,
        agents: infos,
        workspaceNames: ["wA": "Alpha", "wB": "Beta"],
        tabNames: ["wA:t1": "main", "wA:t9": "tests", "wB:t2": "logs"],
        focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
    )
}

@Suite("AgentStore pane moves")
struct AgentStorePaneMoveTests {

    @Test("A cross-workspace move re-keys the blocked row and a pre-move list cannot alert again")
    @MainActor
    func crossWorkspaceMoveKeepsEpisode() throws {
        let store = AgentStore()
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4),
            makeAgentInfo(paneId: "wA:p2", agentStatus: "idle", stateChangeSeq: 1),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)

        let blocked = store.applyEvent(.paneUpdated(makeAgentInfo(
            paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0
        )))
        let startedAt = try #require(store.agents[AgentID("wA:p1")]?.enteredAt)
        var pinned = try #require(store.agents[AgentID("wA:p1")])
        let output = Date(timeIntervalSince1970: 1_700_000_100)
        pinned.lastOutputAt = output
        pinned.verdict = .silent(since: startedAt, cpu: .deadlocked)
        store.agents[AgentID("wA:p1")] = pinned

        let first = store.captureHerdRequest()
        let second = store.captureHerdRequest()
        let move = store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wB:p4",
                workspaceId: "wB",
                tabId: "wB:t2",
                agentStatus: "blocked",
                stateChangeSeq: 5,
                title: "Still Claude"
            ),
            createdWorkspaceLabel: nil,
            createdTabLabel: nil
        ))
        let after = store.captureHerdRequest()

        #expect(move == nil)
        #expect(store.agents[AgentID("wA:p1")] == nil)
        let moved = try #require(store.agents[AgentID("wB:p4")])
        #expect(moved.status == .blocked)
        #expect(moved.enteredAt == startedAt)
        #expect(moved.lastOutputAt == output)
        #expect(moved.verdict.isSilent)
        #expect(moved.workspaceName == "Beta")
        #expect(moved.tabName == "logs")
        #expect(moved.stateChangeSeq == 5)
        #expect(moved.name == "Still Claude")
        #expect(store.agents[AgentID("wA:p2")]?.status == .idle)

        let preMove = labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4),
            makeAgentInfo(paneId: "wA:p2", agentStatus: "idle", stateChangeSeq: 1),
        ])
        let stale = store.applyHerdSnapshot(
            preMove, requestedAtEpoch: first.epoch, requestedAtSerial: first.serial
        )
        let staleAgain = store.applyHerdSnapshot(
            preMove, requestedAtEpoch: second.epoch, requestedAtSerial: second.serial
        )
        #expect(stale.isEmpty)
        #expect(staleAgain.isEmpty)
        #expect(store.agents[AgentID("wA:p1")] == nil)
        #expect(store.agents[AgentID("wB:p4")]?.status == .blocked)
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt == startedAt)

        let fresh = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 5, title: "Still Claude"
            ),
            makeAgentInfo(paneId: "wA:p2", agentStatus: "idle", stateChangeSeq: 1),
        ]), requestedAtEpoch: after.epoch, requestedAtSerial: after.serial)
        #expect(fresh.isEmpty)
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt == startedAt)
        #expect(store.agents[AgentID("wB:p4")]?.workspaceName == "Beta")
        #expect(store.agents[AgentID("wA:p1")] == nil)
        #expect(store.agents.count == 2)
        #expect(blockedAlerts(present(blocked) + present(move) + stale + staleAgain + fresh).count == 1)
    }

    @Test("A same-id move uses the cached tab label and keeps the episode")
    @MainActor
    func sameWorkspaceMoveUsesLabel() throws {
        let store = AgentStore()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)
        ]))
        var agent = try #require(store.agents[AgentID("wA:p1")])
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        agent.enteredAt = entered
        store.agents[AgentID("wA:p1")] = agent

        let move = store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wA:p1", tabId: "wA:t9",
                agentStatus: "blocked", stateChangeSeq: 5
            ),
            createdWorkspaceLabel: nil,
            createdTabLabel: nil
        ))
        #expect(move == nil)
        #expect(store.agents[AgentID("wA:p1")]?.tabName == "tests")
        #expect(store.agents[AgentID("wA:p1")]?.workspaceName == "Alpha")
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == entered)
        #expect(store.agents.count == 1)
    }

    @Test("A move into a new workspace uses the label the event created")
    @MainActor
    func createdWorkspaceLabel() throws {
        let store = AgentStore()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 2)
        ]))
        let move = store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wC:p1", workspaceId: "wC", tabId: "wC:t1",
                agentStatus: "working", stateChangeSeq: 2, title: "Claude"
            ),
            createdWorkspaceLabel: "proj",
            createdTabLabel: "scratch"
        ))
        #expect(move == nil)
        let moved = try #require(store.agents[AgentID("wC:p1")])
        #expect(moved.workspaceName == "proj")
        #expect(moved.tabName == "scratch")

        // The label stays available for a later pane_updated of the same pane.
        store.applyEvent(.paneUpdated(makeAgentInfo(
            paneId: "wC:p1", workspaceId: "wC", tabId: "wC:t1",
            agentStatus: "working", stateChangeSeq: 0, title: "Renamed"
        )))
        #expect(store.agents[AgentID("wC:p1")]?.workspaceName == "proj")
        #expect(store.agents[AgentID("wC:p1")]?.tabName == "scratch")
        #expect(store.agents[AgentID("wC:p1")]?.name == "Renamed")
        #expect(store.agents[AgentID("wA:p1")] == nil)
    }

    @Test("A stale seq on the moved pane does not roll the status back")
    @MainActor
    func staleSeqDoesNotRollStatusBack() throws {
        let store = AgentStore()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 9)
        ]))
        let entered = try #require(store.agents[AgentID("wA:p1")]?.enteredAt)
        let move = store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "working", stateChangeSeq: 4
            ),
            createdWorkspaceLabel: nil,
            createdTabLabel: nil
        ))
        #expect(move == nil)
        let moved = try #require(store.agents[AgentID("wB:p4")])
        #expect(moved.status == .blocked)
        #expect(moved.stateChangeSeq == 9)
        #expect(moved.enteredAt == entered)
        #expect(moved.workspaceName == "Beta")
        #expect(store.agents[AgentID("wA:p1")] == nil)
    }

    @Test("A move that changes status reports that transition")
    @MainActor
    func statusChangeOnMoveReports() throws {
        let store = AgentStore()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)
        ]))
        var agent = try #require(store.agents[AgentID("wA:p1")])
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        agent.enteredAt = pinned
        store.agents[AgentID("wA:p1")] = agent
        let move = store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 5
            ),
            createdWorkspaceLabel: nil,
            createdTabLabel: nil
        ))
        #expect(move?.from == .working)
        #expect(move?.to == .blocked)
        #expect(move?.agentId == AgentID("wB:p4"))
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt == move?.enteredAt)
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt != pinned)
        #expect(store.agents[AgentID("wA:p1")] == nil)
    }

    @Test("A move back to a shell drops the row and a pre-move list cannot restore it")
    @MainActor
    func moveToShellDrops() {
        let store = AgentStore()
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let inFlight = store.captureHerdRequest()
        let move = store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agent: nil, agentStatus: "unknown", stateChangeSeq: 5
            ),
            createdWorkspaceLabel: nil,
            createdTabLabel: nil
        ))
        #expect(move == nil)
        #expect(store.agents.isEmpty)

        let stale = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)
        ]), requestedAtEpoch: inFlight.epoch, requestedAtSerial: inFlight.serial)
        #expect(stale.isEmpty)
        #expect(store.agents.isEmpty)
        #expect(store.agents[AgentID("wB:p4")] == nil)
    }

    @Test("A seq-less move re-keys, keeps the episode, and does not replace a known label")
    @MainActor
    func seqlessMoveKeepsEpisode() throws {
        // PaneInfo carries no state_change_seq. The payload status is whatever
        // the pane showed when the event was built, including a replay from
        // herdr's buffer, so it must not open a new dwell.
        let store = AgentStore()
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 9)
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        var agent = try #require(store.agents[AgentID("wA:p1")])
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        agent.enteredAt = entered
        store.agents[AgentID("wA:p1")] = agent

        let inFlight = store.captureHerdRequest()
        let move = store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "working", stateChangeSeq: 0, title: "Still Claude"
            ),
            createdWorkspaceLabel: "stale",
            createdTabLabel: "stale-tab"
        ))
        #expect(move == nil)
        #expect(store.agents[AgentID("wA:p1")] == nil)
        let moved = try #require(store.agents[AgentID("wB:p4")])
        #expect(moved.status == .blocked)
        #expect(moved.stateChangeSeq == 9)
        #expect(moved.enteredAt == entered)
        #expect(moved.name == "Still Claude")
        #expect(moved.workspaceName == "Beta")
        #expect(moved.tabName == "logs")
        let after = store.captureHerdRequest()

        let stale = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4)
        ]), requestedAtEpoch: inFlight.epoch, requestedAtSerial: inFlight.serial)
        #expect(stale.isEmpty)
        #expect(store.agents[AgentID("wA:p1")] == nil)
        #expect(store.agents[AgentID("wB:p4")]?.status == .blocked)
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt == entered)

        let catchUp = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 9, title: "Still Claude"
            )
        ]), requestedAtEpoch: after.epoch, requestedAtSerial: after.serial)
        #expect(catchUp.isEmpty)
        #expect(store.agents[AgentID("wB:p4")]?.status == .blocked)
        #expect(store.agents[AgentID("wB:p4")]?.stateChangeSeq == 9)
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt == entered)
        #expect(store.agents[AgentID("wA:p1")] == nil)
    }

    @Test("A seq-less move onto the id already shown does not reopen the episode")
    @MainActor
    func seqlessMoveOntoCurrentIdKeepsEpisode() throws {
        let store = AgentStore()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2", agentStatus: "blocked", stateChangeSeq: 9)
        ]))
        var agent = try #require(store.agents[AgentID("wB:p4")])
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        agent.enteredAt = entered
        store.agents[AgentID("wB:p4")] = agent

        let move = store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "working", stateChangeSeq: 0
            ),
            createdWorkspaceLabel: "stale",
            createdTabLabel: "stale-tab"
        ))
        #expect(move == nil)
        let kept = try #require(store.agents[AgentID("wB:p4")])
        #expect(kept.status == .blocked)
        #expect(kept.stateChangeSeq == 9)
        #expect(kept.enteredAt == entered)
        #expect(kept.workspaceName == "Beta")
        #expect(kept.tabName == "logs")
        #expect(store.agents.count == 1)
    }

    @Test("A seq-less move for an untracked pane does not insert it or its label")
    @MainActor
    func seqlessMoveDoesNotInsert() {
        let store = AgentStore()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p2", agentStatus: "idle", stateChangeSeq: 1)
        ]))
        let move = store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 0
            ),
            createdWorkspaceLabel: "ghost",
            createdTabLabel: "ghost-tab"
        ))
        #expect(move == nil)
        #expect(store.agents[AgentID("wB:p4")] == nil)
        #expect(store.agents.count == 1)

        store.applyEvent(.paneUpdated(makeAgentInfo(
            paneId: "wB:p9", workspaceId: "wB", tabId: "wB:t2",
            agentStatus: "working", stateChangeSeq: 0
        )))
        #expect(store.agents[AgentID("wB:p9")]?.workspaceName == "Beta")
        #expect(store.agents[AgentID("wB:p9")]?.tabName == "logs")
    }

    @Test("A seq-less move to a shell still drops the tracked row")
    @MainActor
    func seqlessMoveToShellDrops() {
        let store = AgentStore()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5)
        ]))
        let move = store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agent: nil, agentStatus: "unknown", stateChangeSeq: 0
            ),
            createdWorkspaceLabel: nil,
            createdTabLabel: nil
        ))
        #expect(move == nil)
        #expect(store.agents.isEmpty)
    }

    @Test("A seq-less move into a workspace the cache does not know uses the created label")
    @MainActor
    func seqlessMoveUsesCreatedLabelWhenCacheIsEmpty() throws {
        let store = AgentStore()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 2)
        ]))
        let move = store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wC:p1", workspaceId: "wC", tabId: "wC:t1",
                agentStatus: "blocked", stateChangeSeq: 0, title: "Claude"
            ),
            createdWorkspaceLabel: "proj",
            createdTabLabel: "scratch"
        ))
        #expect(move == nil)
        let moved = try #require(store.agents[AgentID("wC:p1")])
        #expect(moved.status == .working)
        #expect(moved.stateChangeSeq == 2)
        #expect(moved.workspaceName == "proj")
        #expect(moved.tabName == "scratch")
        #expect(store.agents[AgentID("wA:p1")] == nil)
    }
}

// MARK: - poll adopts a move before pane.moved

private func session(_ value: String, agent: String = "claude") -> HerdrSnapshot.AgentSession {
    HerdrSnapshot.AgentSession(source: "agent", agent: agent, kind: "session", value: value)
}

@MainActor
private func pinEpisode(
    _ store: AgentStore,
    id: AgentID,
    enteredAt: Date,
    lastOutputAt: Date,
    verdict: Verdict
) throws {
    var agent = try #require(store.agents[id])
    agent.enteredAt = enteredAt
    agent.lastOutputAt = lastOutputAt
    agent.verdict = verdict
    store.agents[id] = agent
}

@Suite("A poll that lands before pane.moved")
struct PollBeforeMoveTests {

    @Test("The same session keeps the episode and does not alert again")
    @MainActor
    func sameSessionKeepsEpisode() throws {
        let store = AgentStore()
        let occupant = session("abc")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: occupant),
            makeAgentInfo(paneId: "wA:p2", agentStatus: "idle", stateChangeSeq: 1),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        let output = Date(timeIntervalSince1970: 1_700_000_050)
        try pinEpisode(
            store, id: AgentID("wA:p1"),
            enteredAt: entered, lastOutputAt: output,
            verdict: .silent(since: entered, cpu: .deadlocked)
        )
        let otherEntered = try #require(store.agents[AgentID("wA:p2")]?.enteredAt)

        let early = store.captureHerdRequest()
        let poll = store.captureHerdRequest()
        let transitions = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 5, title: "Still Claude",
                session: occupant
            ),
            makeAgentInfo(paneId: "wA:p2", agentStatus: "idle", stateChangeSeq: 1),
        ]), requestedAtEpoch: poll.epoch, requestedAtSerial: poll.serial)

        #expect(transitions.isEmpty)
        #expect(store.sessionMoves == [AgentID("wA:p1"): AgentID("wB:p4")])
        #expect(store.agents[AgentID("wA:p1")] == nil)
        let moved = try #require(store.agents[AgentID("wB:p4")])
        #expect(moved.status == .blocked)
        #expect(moved.stateChangeSeq == 5)
        #expect(moved.enteredAt == entered)
        #expect(moved.lastOutputAt == output)
        #expect(moved.verdict.isSilent)
        #expect(moved.name == "Still Claude")
        #expect(moved.workspaceName == "Beta")
        #expect(moved.tabName == "logs")
        #expect(moved.sessionIdentity == "agent|claude|session|abc")
        #expect(store.agents[AgentID("wA:p2")]?.enteredAt == otherEntered)
        #expect(store.agents.count == 2)

        // The move event is seq-less on the wire. It must not reopen the dwell.
        let move = store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "working", stateChangeSeq: 0, title: "Still Claude"
            ),
            createdWorkspaceLabel: "stale",
            createdTabLabel: "stale-tab"
        ))
        #expect(move == nil)
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt == entered)
        #expect(store.agents[AgentID("wB:p4")]?.status == .blocked)
        #expect(store.agents[AgentID("wB:p4")]?.stateChangeSeq == 5)
        #expect(store.agents[AgentID("wB:p4")]?.verdict.isSilent)
        #expect(store.agents[AgentID("wB:p4")]?.workspaceName == "Beta")
        #expect(store.agents[AgentID("wB:p4")]?.sessionIdentity == "agent|claude|session|abc")

        let stale = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: occupant),
        ]), requestedAtEpoch: early.epoch, requestedAtSerial: early.serial)
        #expect(stale.isEmpty)
        #expect(store.agents[AgentID("wA:p1")] == nil)
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt == entered)

        let bumped = store.captureHerdRequest()
        let next = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 6, session: occupant
            ),
        ]), requestedAtEpoch: bumped.epoch, requestedAtSerial: bumped.serial)
        #expect(next.isEmpty)
        #expect(store.agents[AgentID("wB:p4")]?.stateChangeSeq == 6)
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt != entered)
        #expect(store.sessionMoves.isEmpty)
    }

    @Test("A status change on the moved pane alerts once, from the old status")
    @MainActor
    func statusChangeAlertsFromTheOldStatus() throws {
        let store = AgentStore()
        let occupant = session("abc")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 4, session: occupant),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        try pinEpisode(
            store, id: AgentID("wA:p1"),
            enteredAt: entered, lastOutputAt: entered,
            verdict: .healthy
        )

        let poll = store.captureHerdRequest()
        let transitions = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 5, session: occupant
            ),
        ]), requestedAtEpoch: poll.epoch, requestedAtSerial: poll.serial)

        #expect(transitions.count == 1)
        #expect(transitions.first?.from == .working)
        #expect(transitions.first?.to == .blocked)
        #expect(transitions.first?.agentId == AgentID("wB:p4"))
        #expect(store.sessionMoves == [AgentID("wA:p1"): AgentID("wB:p4")])
        let moved = try #require(store.agents[AgentID("wB:p4")])
        #expect(moved.enteredAt != entered)
        #expect(moved.status == .blocked)
        #expect(store.agents[AgentID("wA:p1")] == nil)
        #expect(blockedAlerts(transitions).count == 1)
    }

    @Test("Two sessions moved by one poll each keep their own episode")
    @MainActor
    func twoSessionsBothContinue() throws {
        let store = AgentStore()
        let first = session("one")
        let second = session("two")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: first),
            makeAgentInfo(paneId: "wA:p2", agentStatus: "working", stateChangeSeq: 3, session: second),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let enteredA = Date(timeIntervalSince1970: 1_700_000_000)
        let enteredB = Date(timeIntervalSince1970: 1_700_000_100)
        try pinEpisode(
            store, id: AgentID("wA:p1"),
            enteredAt: enteredA, lastOutputAt: enteredA,
            verdict: .silent(since: enteredA, cpu: nil)
        )
        try pinEpisode(
            store, id: AgentID("wA:p2"),
            enteredAt: enteredB, lastOutputAt: enteredB,
            verdict: .healthy
        )

        let poll = store.captureHerdRequest()
        let transitions = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 5, session: first
            ),
            makeAgentInfo(
                paneId: "wB:p5", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "working", stateChangeSeq: 3, session: second
            ),
        ]), requestedAtEpoch: poll.epoch, requestedAtSerial: poll.serial)

        #expect(transitions.isEmpty)
        #expect(store.sessionMoves == [
            AgentID("wA:p1"): AgentID("wB:p4"),
            AgentID("wA:p2"): AgentID("wB:p5"),
        ])
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt == enteredA)
        #expect(store.agents[AgentID("wB:p4")]?.verdict.isSilent == true)
        #expect(store.agents[AgentID("wB:p5")]?.enteredAt == enteredB)
        #expect(store.agents[AgentID("wA:p1")] == nil)
        #expect(store.agents[AgentID("wA:p2")] == nil)
        #expect(store.agents.count == 2)
    }

    @Test("A different session is a new pane and alerts")
    @MainActor
    func differentSessionDoesNotContinue() throws {
        let store = AgentStore()
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: session("abc")),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        try pinEpisode(
            store, id: AgentID("wA:p1"),
            enteredAt: entered, lastOutputAt: entered,
            verdict: .silent(since: entered, cpu: nil)
        )

        let poll = store.captureHerdRequest()
        let transitions = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 5, session: session("other")
            ),
        ]), requestedAtEpoch: poll.epoch, requestedAtSerial: poll.serial)

        #expect(transitions.count == 1)
        #expect(transitions.first?.from == nil)
        #expect(transitions.first?.to == .blocked)
        #expect(transitions.first?.agentId == AgentID("wB:p4"))
        #expect(store.sessionMoves.isEmpty)
        #expect(store.agents[AgentID("wA:p1")] == nil)
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt != entered)
        #expect(store.agents[AgentID("wB:p4")]?.verdict.isSilent == false)
    }

    @Test("No session value still starts a new episode")
    @MainActor
    func missingSessionDoesNotContinue() throws {
        let store = AgentStore()
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        try pinEpisode(
            store, id: AgentID("wA:p1"),
            enteredAt: entered, lastOutputAt: entered,
            verdict: .healthy
        )

        let poll = store.captureHerdRequest()
        let transitions = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 5
            ),
        ]), requestedAtEpoch: poll.epoch, requestedAtSerial: poll.serial)

        #expect(transitions.first?.from == nil)
        #expect(store.sessionMoves.isEmpty)
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt != entered)
    }

    @Test("An empty session value does not glue unrelated panes together")
    @MainActor
    func emptySessionValueDoesNotContinue() throws {
        let store = AgentStore()
        let empty = session("")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: empty),
            makeAgentInfo(paneId: "wA:p2", agentStatus: "blocked", stateChangeSeq: 2, session: empty),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        try pinEpisode(
            store, id: AgentID("wA:p1"),
            enteredAt: entered, lastOutputAt: entered,
            verdict: .healthy
        )

        let poll = store.captureHerdRequest()
        let transitions = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 5, session: empty
            ),
            makeAgentInfo(
                paneId: "wB:p5", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 2, session: empty
            ),
        ]), requestedAtEpoch: poll.epoch, requestedAtSerial: poll.serial)

        #expect(store.sessionMoves.isEmpty)
        #expect(transitions.count == 2)
        #expect(transitions.allSatisfy { $0.from == nil && $0.to == .blocked })
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt != entered)
        #expect(store.agents[AgentID("wB:p5")]?.enteredAt != entered)
    }

    @Test("A session that is still listed is not carried onto a new pane")
    @MainActor
    func listedSessionIsNotReused() throws {
        let store = AgentStore()
        let occupant = session("abc")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: occupant),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        try pinEpisode(
            store, id: AgentID("wA:p1"),
            enteredAt: entered, lastOutputAt: entered,
            verdict: .silent(since: entered, cpu: nil)
        )

        let poll = store.captureHerdRequest()
        let transitions = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: occupant),
            makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 5, session: occupant
            ),
        ]), requestedAtEpoch: poll.epoch, requestedAtSerial: poll.serial)

        #expect(store.sessionMoves.isEmpty)
        #expect(store.agents[AgentID("wA:p1")]?.enteredAt == entered)
        #expect(store.agents[AgentID("wA:p1")]?.verdict.isSilent == true)
        #expect(transitions.count == 1)
        #expect(transitions.first?.agentId == AgentID("wB:p4"))
        #expect(transitions.first?.from == nil)
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt != entered)
    }

    @Test("The same seq after a restart-shaped id change does not keep the old dwell")
    @MainActor
    func seqResetStartsANewDwellWithoutAlertingBlockedAgain() throws {
        let store = AgentStore()
        let occupant = session("abc")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 9, session: occupant),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        let output = Date(timeIntervalSince1970: 1_700_000_050)
        try pinEpisode(
            store, id: AgentID("wA:p1"),
            enteredAt: entered, lastOutputAt: output,
            verdict: .silent(since: entered, cpu: nil)
        )

        let poll = store.captureHerdRequest()
        let transitions = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 1, session: occupant
            ),
        ]), requestedAtEpoch: poll.epoch, requestedAtSerial: poll.serial)

        #expect(transitions.isEmpty)
        #expect(store.sessionMoves == [AgentID("wA:p1"): AgentID("wB:p4")])
        let restarted = try #require(store.agents[AgentID("wB:p4")])
        #expect(restarted.stateChangeSeq == 1)
        #expect(restarted.enteredAt != entered)
        #expect(restarted.lastOutputAt == output)
        #expect(restarted.verdict.isSilent == false)
        #expect(store.agents[AgentID("wA:p1")] == nil)
    }

    @Test("A move event keeps the session, so the next poll can carry the episode again")
    @MainActor
    func eventThenLaterPollCarriesAgain() throws {
        let store = AgentStore()
        let occupant = session("abc")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: occupant),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        try pinEpisode(
            store, id: AgentID("wA:p1"),
            enteredAt: entered, lastOutputAt: entered,
            verdict: .silent(since: entered, cpu: .deadlocked)
        )

        let move = store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "working", stateChangeSeq: 0
            ),
            createdWorkspaceLabel: nil,
            createdTabLabel: nil
        ))
        #expect(move == nil)
        #expect(store.agents[AgentID("wB:p4")]?.enteredAt == entered)

        let poll = store.captureHerdRequest()
        let transitions = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(
                paneId: "wC:p8", workspaceId: "wC", tabId: "wC:t1",
                agentStatus: "blocked", stateChangeSeq: 5, session: occupant
            ),
        ]), requestedAtEpoch: poll.epoch, requestedAtSerial: poll.serial)

        #expect(transitions.isEmpty)
        #expect(store.sessionMoves == [AgentID("wB:p4"): AgentID("wC:p8")])
        #expect(store.agents[AgentID("wB:p4")] == nil)
        #expect(store.agents[AgentID("wC:p8")]?.enteredAt == entered)
        #expect(store.agents[AgentID("wC:p8")]?.status == .blocked)
        #expect(store.agents[AgentID("wC:p8")]?.verdict.isSilent == true)
        #expect(store.agents[AgentID("wC:p8")]?.workspaceName == "wC")
    }
}

@Suite("A new session in the same pane")
struct SamePaneSessionTests {
    private func identity(_ value: String) -> String {
        "agent|claude|session|\(value)"
    }

    @Test("Same status and seq with a different session opens a new blocked episode")
    @MainActor
    func differentSessionAlertsAndDropsTheOldDwell() throws {
        let store = AgentStore()
        let id = AgentID("wA:p1")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: session("abc")),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        try pinEpisode(
            store, id: id,
            enteredAt: entered, lastOutputAt: entered,
            verdict: .silent(since: entered, cpu: nil)
        )

        let poll = store.captureHerdRequest()
        let transitions = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: session("other")),
        ]), requestedAtEpoch: poll.epoch, requestedAtSerial: poll.serial)

        #expect(transitions.count == 1)
        #expect(transitions.first?.from == .blocked)
        #expect(transitions.first?.to == .blocked)
        #expect(blockedAlerts(transitions).count == 1)
        let row = try #require(store.agents[id])
        #expect(row.enteredAt != entered)
        #expect(row.verdict.isSilent == false)
        #expect(row.stateChangeSeq == 5)
        #expect(store.sessionIdentity(for: id) == identity("other"))
    }

    @Test("A session value that only continues another is a different occupant")
    @MainActor
    func prefixedSessionDoesNotContinue() throws {
        let store = AgentStore()
        let id = AgentID("wA:p1")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: session("abc")),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        try pinEpisode(
            store, id: id,
            enteredAt: entered, lastOutputAt: entered,
            verdict: .healthy
        )
        let poll = store.captureHerdRequest()
        let transitions = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(
                paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5,
                session: session("abc|extra")
            ),
        ]), requestedAtEpoch: poll.epoch, requestedAtSerial: poll.serial)
        #expect(transitions.count == 1)
        #expect(store.agents[id]?.enteredAt != entered)
        #expect(store.sessionIdentity(for: id) == identity("abc|extra"))
    }

    @Test("The first session value, and a list that omits one, keep the episode, and the next occupant still opens one")
    @MainActor
    func firstOrMissingSessionKeepsTheEpisode() throws {
        let store = AgentStore()
        let id = AgentID("wA:p1")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        try pinEpisode(
            store, id: id,
            enteredAt: entered, lastOutputAt: entered,
            verdict: .silent(since: entered, cpu: nil)
        )

        let named = store.captureHerdRequest()
        let learned = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: session("abc")),
        ]), requestedAtEpoch: named.epoch, requestedAtSerial: named.serial)
        #expect(learned.isEmpty)
        #expect(store.agents[id]?.enteredAt == entered)
        #expect(store.agents[id]?.verdict.isSilent == true)
        #expect(store.sessionIdentity(for: id) == identity("abc"))

        let again = store.captureHerdRequest()
        let omitted = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5),
        ]), requestedAtEpoch: again.epoch, requestedAtSerial: again.serial)
        #expect(omitted.isEmpty)
        #expect(store.agents[id]?.enteredAt == entered)
        #expect(store.agents[id]?.verdict.isSilent == true)
        // The omitting list must not clear the occupant. If it does, the
        // next session is the first one this pane has named, and the
        // silence stays on that person.
        #expect(store.sessionIdentity(for: id) == identity("abc"))

        let followed = store.captureHerdRequest()
        let replaced = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: session("other")),
        ]), requestedAtEpoch: followed.epoch, requestedAtSerial: followed.serial)
        #expect(replaced.count == 1)
        #expect(replaced.first?.from == .blocked)
        #expect(replaced.first?.to == .blocked)
        let row = try #require(store.agents[id])
        #expect(row.enteredAt != entered)
        #expect(row.verdict.isSilent == false)
        #expect(row.stateChangeSeq == 5)
        #expect(store.sessionIdentity(for: id) == identity("other"))
    }

    @Test("pane_updated naming a new session opens the episode, and the earlier list cannot put it back")
    @MainActor
    func eventSessionSurvivesThePollThatStartedBeforeIt() throws {
        let store = AgentStore()
        let id = AgentID("wA:p1")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: session("abc")),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        try pinEpisode(
            store, id: id,
            enteredAt: entered, lastOutputAt: entered,
            verdict: .silent(since: entered, cpu: .deadlocked)
        )
        let early = store.captureHerdRequest()
        let event = store.applyEvent(.paneUpdated(
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0, session: session("other"))
        ))
        #expect(event?.from == .blocked)
        #expect(event?.to == .blocked)
        let opened = try #require(store.agents[id])
        #expect(opened.enteredAt != entered)
        #expect(opened.verdict.isSilent == false)
        #expect(store.sessionIdentity(for: id) == identity("other"))

        let stale = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: session("abc")),
        ]), requestedAtEpoch: early.epoch, requestedAtSerial: early.serial)
        #expect(stale.isEmpty)
        #expect(store.agents[id]?.enteredAt == opened.enteredAt)
        #expect(store.agents[id]?.verdict.isSilent == false)
        #expect(store.sessionIdentity(for: id) == identity("other"))
    }

    @Test("A seq-less pane_updated that omits the session keeps the episode")
    @MainActor
    func seqlessUpdateWithoutSessionKeepsTheEpisode() throws {
        let store = AgentStore()
        let id = AgentID("wA:p1")
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: session("abc")),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        try pinEpisode(
            store, id: id,
            enteredAt: entered, lastOutputAt: entered,
            verdict: .silent(since: entered, cpu: nil)
        )
        let event = store.applyEvent(.paneUpdated(
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0, title: "renamed")
        ))
        #expect(event == nil)
        #expect(store.agents[id]?.enteredAt == entered)
        #expect(store.agents[id]?.verdict.isSilent == true)
        #expect(store.agents[id]?.name == "renamed")
        #expect(store.agents[id]?.sessionIdentity == identity("abc"))
        #expect(store.sessionIdentity(for: id) == identity("abc"))
    }

    @Test("A move whose payload names a different session does not keep the dwell")
    @MainActor
    func moveToADifferentSessionOpensAnEpisode() throws {
        let store = AgentStore()
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5, session: session("abc")),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        try pinEpisode(
            store, id: AgentID("wA:p1"),
            enteredAt: entered, lastOutputAt: entered,
            verdict: .silent(since: entered, cpu: nil)
        )
        let move = store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 0, session: session("other")
            ),
            createdWorkspaceLabel: nil,
            createdTabLabel: nil
        ))
        #expect(move?.from == .blocked)
        #expect(move?.to == .blocked)
        #expect(move?.agentId == AgentID("wB:p4"))
        let landed = try #require(store.agents[AgentID("wB:p4")])
        #expect(landed.enteredAt != entered)
        #expect(landed.verdict.isSilent == false)
        #expect(landed.status == .blocked)
        #expect(store.agents[AgentID("wA:p1")] == nil)
        #expect(store.sessionIdentity(for: AgentID("wB:p4")) == identity("other"))
        #expect(store.sessionIdentity(for: AgentID("wA:p1")) == nil)
    }
}

@Suite("Container renames")
struct ContainerRenameTests {

    @MainActor
    private func seed(_ store: AgentStore) -> HerdRequestStamp {
        let seed = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5),
            makeAgentInfo(paneId: "wA:p2", tabId: "wA:t9", agentStatus: "working", stateChangeSeq: 3),
            makeAgentInfo(paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2", agentStatus: "idle", stateChangeSeq: 1),
        ]), requestedAtEpoch: seed.epoch, requestedAtSerial: seed.serial)
        return seed
    }

    @Test("A rename sticks, and a poll captured before it cannot put the old label back")
    @MainActor
    func renameSurvivesThePollThatStartedBeforeIt() throws {
        let store = AgentStore()
        _ = seed(store)
        let id = AgentID("wA:p1")
        let entered = Date(timeIntervalSince1970: 1_700_000_000)
        try pinEpisode(
            store, id: id,
            enteredAt: entered, lastOutputAt: entered,
            verdict: .processGone(lastLine: "zsh (pid 4)")
        )
        let early = store.captureHerdRequest()
        #expect(store.applyEvent(.workspaceRenamed(workspaceId: "wA", label: "Renamed")) == nil)
        #expect(store.applyEvent(.tabRenamed(tabId: "wA:t9", label: "suite")) == nil)
        // The same label is not another event. A second bump would pin a
        // poll that had already seen this name.
        let epoch = store.currentHerdEpoch
        #expect(store.applyEvent(.workspaceRenamed(workspaceId: "wA", label: "Renamed")) == nil)
        #expect(store.currentHerdEpoch == epoch)

        #expect(store.agents[id]?.workspaceName == "Renamed")
        #expect(store.agents[id]?.tabName == "main")
        #expect(store.agents[id]?.enteredAt == entered)
        #expect(store.agents[id]?.verdict == .processGone(lastLine: "zsh (pid 4)"))
        #expect(store.agents[AgentID("wA:p2")]?.workspaceName == "Renamed")
        #expect(store.agents[AgentID("wA:p2")]?.tabName == "suite")
        #expect(store.agents[AgentID("wB:p4")]?.workspaceName == "Beta")
        #expect(store.agents[AgentID("wB:p4")]?.tabName == "logs")
        #expect(store.workspaceLabels["wA"] == "Renamed")
        #expect(store.tabLabels["wA:t9"] == "suite")

        let stale = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5),
            makeAgentInfo(paneId: "wA:p2", tabId: "wA:t9", agentStatus: "working", stateChangeSeq: 3),
            makeAgentInfo(paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2", agentStatus: "idle", stateChangeSeq: 1),
        ]), requestedAtEpoch: early.epoch, requestedAtSerial: early.serial)
        #expect(stale.isEmpty)
        #expect(store.agents[id]?.workspaceName == "Renamed")
        #expect(store.agents[id]?.enteredAt == entered)
        #expect(store.agents[id]?.verdict == .processGone(lastLine: "zsh (pid 4)"))
        #expect(store.agents[AgentID("wA:p2")]?.tabName == "suite")
        #expect(store.workspaceLabels["wA"] == "Renamed")
        #expect(store.tabLabels["wA:t9"] == "suite")

        store.applyEvent(.paneUpdated(makeAgentInfo(
            paneId: "wA:p2", tabId: "wA:t9", agentStatus: "working", stateChangeSeq: 0, title: "Claude"
        )))
        #expect(store.agents[AgentID("wA:p2")]?.workspaceName == "Renamed")
        #expect(store.agents[AgentID("wA:p2")]?.tabName == "suite")

        let after = store.captureHerdRequest()
        store.applyHerdSnapshot(HerdSnapshot(
            version: "0.7.5", protocol: 17,
            agents: [
                makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5),
                makeAgentInfo(paneId: "wA:p2", tabId: "wA:t9", agentStatus: "working", stateChangeSeq: 3),
                makeAgentInfo(paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2", agentStatus: "idle", stateChangeSeq: 1),
            ],
            workspaceNames: ["wA": "Later", "wB": "Beta"],
            tabNames: ["wA:t1": "main", "wA:t9": "suite", "wB:t2": "logs"],
            focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
        ), requestedAtEpoch: after.epoch, requestedAtSerial: after.serial)
        #expect(store.agents[id]?.workspaceName == "Later")
        #expect(store.agents[id]?.enteredAt == entered)
        #expect(store.workspaceLabels["wA"] == "Later")
    }

    @Test("A poll with no request epoch still applies the label it read")
    @MainActor
    func nilEpochSnapshotAppliesItsOwnLabel() {
        let store = AgentStore()
        _ = seed(store)
        store.applyEvent(.workspaceRenamed(workspaceId: "wA", label: "Renamed"))
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5),
        ]))
        #expect(store.agents[AgentID("wA:p1")]?.workspaceName == "Alpha")
        #expect(store.workspaceLabels["wA"] == "Alpha")
    }

    @Test("A rename does not undo a status event a poll captured before both")
    @MainActor
    func heldRowKeepsTheRename() throws {
        let store = AgentStore()
        _ = seed(store)
        let id = AgentID("wA:p1")
        let early = store.captureHerdRequest()
        store.applyEvent(.paneUpdated(makeAgentInfo(
            paneId: "wA:p1", agentStatus: "working", stateChangeSeq: 0, title: "Claude"
        )))
        let opened = try #require(store.agents[id])
        store.applyEvent(.workspaceRenamed(workspaceId: "wA", label: "Renamed"))
        let stale = store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5),
            makeAgentInfo(paneId: "wA:p2", tabId: "wA:t9", agentStatus: "working", stateChangeSeq: 3),
            makeAgentInfo(paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2", agentStatus: "idle", stateChangeSeq: 1),
        ]), requestedAtEpoch: early.epoch, requestedAtSerial: early.serial)
        #expect(stale.isEmpty)
        let row = try #require(store.agents[id])
        #expect(row.status == .working)
        #expect(row.enteredAt == opened.enteredAt)
        #expect(row.workspaceName == "Renamed")
    }

    @Test("An empty label is not a rename")
    @MainActor
    func emptyLabelIsIgnored() {
        let store = AgentStore()
        _ = seed(store)
        #expect(store.applyEvent(.workspaceRenamed(workspaceId: "wA", label: "")) == nil)
        #expect(store.applyEvent(.tabRenamed(tabId: "wA:t1", label: "")) == nil)
        #expect(store.agents[AgentID("wA:p1")]?.workspaceName == "Alpha")
        #expect(store.agents[AgentID("wA:p1")]?.tabName == "main")
    }
}

@Suite("Agent rename")
struct AgentRenameTests {
    private func herd(_ infos: [HerdrAgentInfo]) -> HerdSnapshot {
        labeledHerd(infos)
    }

    @Test("A rename outranks the terminal title and follows the pane")
    @MainActor
    func renameSurvivesTerminalTitleAndMoves() throws {
        let store = AgentStore()
        let stamp = store.captureHerdRequest()
        store.applyHerdSnapshot(herd([
            makeAgentInfo(
                paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5,
                title: nil, name: "reviewer", terminalTitleStripped: "Action Required",
                foregroundCwd: "/work"
            )
        ]), requestedAtEpoch: stamp.epoch, requestedAtSerial: stamp.serial)
        let id = AgentID("wA:p1")
        #expect(store.agents[id]?.name == "reviewer")
        #expect(store.agents[id]?.displayName == "reviewer")
        #expect(store.agents[id]?.cwd == "/work")

        let entered = store.agents[id]?.enteredAt
        #expect(store.applyEvent(.paneUpdated(makeAgentInfo(
            paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0,
            title: "", terminalTitleStripped: "Bash",
            cwd: nil, foregroundCwd: nil
        ))) == nil)
        #expect(store.agents[id]?.name == "reviewer")
        #expect(store.agents[id]?.enteredAt == entered)

        // display_agent is on this event only. The rename stays stored,
        // so a later payload that omits display_agent still uses it.
        #expect(store.applyEvent(.paneUpdated(makeAgentInfo(
            paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0,
            title: nil, displayAgent: "Claude: auth", terminalTitleStripped: "Bash",
            cwd: nil, foregroundCwd: nil
        ))) == nil)
        #expect(store.agents[id]?.name == "Claude: auth")

        #expect(store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 0,
                title: nil, terminalTitleStripped: "Action Required",
                cwd: nil, foregroundCwd: nil
            ),
            createdWorkspaceLabel: nil,
            createdTabLabel: nil
        )) == nil)
        #expect(store.agents[id] == nil)
        #expect(store.agents[AgentID("wB:p4")]?.name == "reviewer")
        #expect(store.agents[AgentID("wB:p4")]?.cwd == "/work")

        let cleared = store.captureHerdRequest()
        store.applyHerdSnapshot(herd([
            makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 5,
                title: nil, terminalTitleStripped: "Action Required",
                foregroundCwd: "", cwd: nil
            )
        ]), requestedAtEpoch: cleared.epoch, requestedAtSerial: cleared.serial)
        #expect(store.agents[AgentID("wB:p4")]?.name == "Action Required")
        #expect(store.agents[AgentID("wB:p4")]?.cwd == "/work")
    }

    @Test("A list that names no label keeps the row's name, and a new session does not keep the rename")
    @MainActor
    func omittedNameKeepsTheRowUntilTheSessionChanges() throws {
        let store = AgentStore()
        let stamp = store.captureHerdRequest()
        let same = HerdrSnapshot.AgentSession(
            source: "agent", agent: "claude", kind: "session", value: "abc"
        )
        store.applyHerdSnapshot(herd([
            makeAgentInfo(
                paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5,
                title: nil, name: "reviewer", terminalTitleStripped: nil, session: same
            )
        ]), requestedAtEpoch: stamp.epoch, requestedAtSerial: stamp.serial)
        let id = AgentID("wA:p1")
        #expect(store.agents[id]?.name == "reviewer")

        let quiet = store.captureHerdRequest()
        store.applyHerdSnapshot(herd([
            makeAgentInfo(
                paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 5,
                title: nil, terminalTitleStripped: nil, session: same
            )
        ]), requestedAtEpoch: quiet.epoch, requestedAtSerial: quiet.serial)
        #expect(store.agents[id]?.name == "reviewer")
        #expect(store.agents[id]?.cwd == "/tmp")

        let other = HerdrSnapshot.AgentSession(
            source: "agent", agent: "claude", kind: "session", value: "other"
        )
        let replaced = store.applyEvent(.paneUpdated(makeAgentInfo(
            paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0,
            title: nil, terminalTitleStripped: "New task", session: other
        )))
        #expect(replaced != nil)
        #expect(store.agents[id]?.name == "New task")
    }

    @Test("A pane rename beats the terminal title, follows a move, and stays when the session changes")
    @MainActor
    func paneLabelSurvivesTitleMoveAndSessionChange() throws {
        let store = AgentStore()
        let stamp = store.captureHerdRequest()
        store.applyHerdSnapshot(
            herd(pane: "wA:p1", label: "api", title: nil, terminal: "Action Required"),
            requestedAtEpoch: stamp.epoch, requestedAtSerial: stamp.serial
        )
        let id = AgentID("wA:p1")
        #expect(store.agents[id]?.name == "api")
        let entered = store.agents[id]?.enteredAt

        #expect(store.applyEvent(.paneUpdated(makeAgentInfo(
            paneId: "wA:p1", agentStatus: "blocked", stateChangeSeq: 0,
            title: "", terminalTitleStripped: "Bash",
            cwd: nil, foregroundCwd: nil
        ))) == nil)
        #expect(store.agents[id]?.name == "api")
        #expect(store.agents[id]?.enteredAt == entered)

        #expect(store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agentStatus: "blocked", stateChangeSeq: 0,
                title: nil, terminalTitleStripped: "Bash",
                cwd: nil, foregroundCwd: nil
            ),
            createdWorkspaceLabel: nil,
            createdTabLabel: nil
        )) == nil)
        #expect(store.agents[id] == nil)
        #expect(store.agents[AgentID("wB:p4")]?.name == "api")

        let same = HerdrSnapshot.AgentSession(
            source: "agent", agent: "claude", kind: "session", value: "abc"
        )
        let learned = store.captureHerdRequest()
        store.applyHerdSnapshot(
            herd(pane: "wB:p4", workspace: "wB", tab: "wB:t2", label: "api", title: nil, terminal: "Bash", session: same),
            requestedAtEpoch: learned.epoch, requestedAtSerial: learned.serial
        )
        let other = HerdrSnapshot.AgentSession(
            source: "agent", agent: "claude", kind: "session", value: "other"
        )
        let replaced = store.applyEvent(.paneUpdated(makeAgentInfo(
            paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
            agentStatus: "blocked", stateChangeSeq: 0,
            title: nil, terminalTitleStripped: "New task", session: other
        )))
        #expect(replaced != nil)
        #expect(store.agents[AgentID("wB:p4")]?.name == "api")
        #expect(replaced?.enteredAt == store.agents[AgentID("wB:p4")]?.enteredAt)

        let cleared = store.captureHerdRequest()
        store.applyHerdSnapshot(
            herd(pane: "wB:p4", workspace: "wB", tab: "wB:t2", label: nil, title: nil, terminal: "Action Required", session: other),
            requestedAtEpoch: cleared.epoch, requestedAtSerial: cleared.serial
        )
        #expect(store.agents[AgentID("wB:p4")]?.name == "Action Required")
    }

    private func herd(
        pane: String,
        workspace: String = "wA",
        tab: String = "wA:t1",
        label: String?,
        title: String?,
        terminal: String?,
        session: HerdrSnapshot.AgentSession? = nil
    ) -> HerdSnapshot {
        var labels: [String: String] = [:]
        if let label { labels[pane] = label }
        return HerdSnapshot(
            version: "0.7.5", protocol: 17,
            agents: [
                makeAgentInfo(
                    paneId: pane, workspaceId: workspace, tabId: tab,
                    agentStatus: "blocked", stateChangeSeq: 5,
                    title: title, terminalTitleStripped: terminal, session: session,
                    foregroundCwd: "/work"
                )
            ],
            workspaceNames: ["wA": "Alpha", "wB": "Beta"],
            tabNames: ["wA:t1": "main", "wB:t2": "logs"],
            focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil,
            paneLabels: labels,
            snapshotPaneIds: [pane]
        )
    }
}

@Suite("An empty session object is not a kind")
struct EmptySessionKindTests {
    @Test("A blank session keeps the detected kind on the list, the update, and the move")
    @MainActor
    func blankSessionKeepsDetectedKind() throws {
        let store = AgentStore()
        let blank = HerdrSnapshot.AgentSession(source: "", agent: "", kind: "", value: "")
        let stamp = store.captureHerdRequest()
        store.applyHerdSnapshot(labeledHerd([
            makeAgentInfo(
                paneId: "wA:p1", agent: "claude", agentStatus: "blocked", stateChangeSeq: 5,
                title: "Review", session: blank
            )
        ]), requestedAtEpoch: stamp.epoch, requestedAtSerial: stamp.serial)
        let id = AgentID("wA:p1")
        let row = try #require(store.agents[id])
        #expect(row.kind == .custom("claude"))
        #expect(row.sessionIdentity == nil)
        #expect(DwellTracker.fingerprint(for: row) == "custom:claude")

        #expect(store.applyEvent(.paneUpdated(makeAgentInfo(
            paneId: "wA:p1", agent: "claude", agentStatus: "blocked", stateChangeSeq: 0,
            title: "Review", session: blank
        ))) == nil)
        #expect(store.agents[id]?.kind == .custom("claude"))
        #expect(store.agents[id]?.enteredAt == row.enteredAt)

        #expect(store.applyEvent(.paneMoved(
            previousPaneId: "wA:p1",
            pane: makeAgentInfo(
                paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
                agent: "claude", agentStatus: "blocked", stateChangeSeq: 0,
                title: "Review", session: blank
            ),
            createdWorkspaceLabel: nil,
            createdTabLabel: nil
        )) == nil)
        let moved = try #require(store.agents[AgentID("wB:p4")])
        #expect(moved.kind == .custom("claude"))
        #expect(DwellTracker.fingerprint(for: moved) == "custom:claude")
        #expect(store.agents[id] == nil)

        let named = HerdrSnapshot.AgentSession(
            source: "herdr:codex", agent: "codex", kind: "id", value: "019f"
        )
        #expect(store.applyEvent(.paneUpdated(makeAgentInfo(
            paneId: "wB:p4", workspaceId: "wB", tabId: "wB:t2",
            agent: "claude", agentStatus: "blocked", stateChangeSeq: 0,
            title: "Review", session: named
        ))) == nil)
        #expect(store.agents[AgentID("wB:p4")]?.kind == .custom("codex"))
        #expect(store.sessionIdentity(for: AgentID("wB:p4")) == "herdr:codex|codex|id|019f")
    }
}
