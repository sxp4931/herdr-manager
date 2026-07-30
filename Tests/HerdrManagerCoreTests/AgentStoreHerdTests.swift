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
