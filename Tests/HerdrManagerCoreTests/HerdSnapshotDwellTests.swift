import Foundation
import Testing
@testable import HerdrManagerCore

private func makeDwellAgentInfo(
    paneId: String,
    agentStatus: String = "working",
    stateChangeSeq: UInt64 = 1
) -> HerdrAgentInfo {
    HerdrAgentInfo(
        paneId: paneId,
        workspaceId: "wA",
        tabId: "wA:t1",
        agent: "claude",
        displayAgent: "claude",
        name: nil,
        title: "Claude",
        terminalTitleStripped: "Claude",
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
}
