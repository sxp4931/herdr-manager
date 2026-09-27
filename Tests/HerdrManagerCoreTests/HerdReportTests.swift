import Foundation
import Testing
@testable import HerdrManagerCore

@Suite("MCP herd text names the id other tools accept")
struct HerdReportTests {
    @Test("Overview and the list print the full pane id, not the shared suffix")
    func fullPaneIdIsTheAgentId() {
        let review = Agent(
            id: AgentID("w1:p1"),
            kind: .custom("claude"),
            name: "Review",
            status: .blocked,
            verdict: .awaitingInput(BlockClassification(
                kind: .bashPermission, since: Date(), summary: "bash permission prompt"
            )),
            workspaceName: "Proj"
        )
        let build = Agent(
            id: AgentID("w2:p1"),
            kind: .custom("codex"),
            name: "Build",
            status: .working,
            verdict: .healthy,
            workspaceName: "Other"
        )
        let crashed = Agent(
            id: AgentID("w100:p1000"),
            kind: .custom("opencode"),
            name: "Crash",
            status: .working,
            verdict: .processGone(lastLine: "zsh"),
            workspaceName: "Long"
        )
        let names = ["w1": "Proj", "w2": "Other", "w100": "Long"]

        let overview = HerdReport.overview(agents: [review, build, crashed], workspaceNames: names)
        #expect(overview.contains("[w1:p1]"))
        #expect(overview.contains("[w2:p1]"))
        #expect(overview.contains("[w100:p1000]"))
        #expect(!overview.contains("[p1]"))
        #expect(!overview.contains("…"))
        #expect(overview.contains("GONE"))
        #expect(overview.contains("bash permission prompt"))
        #expect(overview.contains("Agent id for other tools is the bracketed workspace:pane value."))

        let list = HerdReport.agentList(agents: [review, build, crashed], workspaceNames: names)
        #expect(list.contains("w1:p1"))
        #expect(list.contains("w2:p1"))
        #expect(list.contains("w100:p1000"))
        #expect(!list.contains("w100:p1…"))
        #expect(list.contains("ID"))
        #expect(!list.contains("Pane"))
        #expect(list.contains("ID is the agent_id other tools accept"))
        #expect(list.contains("claude"))
        #expect(list.contains("opencode"))
    }

    @Test("An empty herd keeps the same empty sentences")
    func emptyHerd() {
        #expect(HerdReport.overview(agents: [], workspaceNames: [:]) == "Herd Overview — 0 agents\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nNo agents found.")
        #expect(HerdReport.agentList(agents: [], workspaceNames: [:]) == "No agents found.")
    }

    @Test("A custom kind keeps the spelling the row stored")
    func customKindSpelling() {
        #expect(HerdReport.kindText(.custom("Claude")) == "Claude")
        #expect(HerdReport.kindText(.claude) == "claude")
    }
}

@Suite("A copied pane suffix resolves only when it names one agent")
struct HerdResolveTests {
    @Test("The full id wins, and a unique suffix still finds that pane")
    func exactAndUniqueSuffix() {
        let herd = snapshot([
            info(pane: "w1:p1", workspace: "w1", title: "Review"),
            info(pane: "other:w1:p1", workspace: "other", title: "Odd"),
            info(pane: "w1:p10", workspace: "w1", title: "Ten")
        ])

        let exact = herd.resolveAgent(agentId: "w1:p1", query: "Odd")
        #expect(pane(exact) == "w1:p1")

        let suffix = herd.resolveAgent(agentId: " p10 ", query: nil)
        #expect(pane(suffix) == "w1:p10")

        let missing = herd.resolveAgent(agentId: "p2", query: "Review")
        #expect(missing == .failure("Agent not found: p2"))
    }

    @Test("The same suffix on two panes is refused with both full ids")
    func ambiguousSuffix() {
        let herd = snapshot([
            info(pane: "w2:p1", workspace: "w2", title: "Build"),
            info(pane: "w1:p1", workspace: "w1", title: "Review")
        ])
        let resolved = herd.resolveAgent(agentId: "p1", query: nil)
        #expect(resolved == .failure(
            "Agent id 'p1' matches more than one pane: w1:p1, w2:p1. Pass the full id."
        ))
    }

    @Test("A query still has to match one agent, and the candidates use the full id")
    func query() {
        let herd = snapshot([
            info(pane: "w1:p1", workspace: "w1", tab: "w1:t1", title: "Review"),
            info(pane: "w2:p1", workspace: "w2", tab: "w2:t1", title: "Build")
        ])

        #expect(pane(herd.resolveAgent(agentId: nil, query: "Review")) == "w1:p1")
        #expect(pane(herd.resolveAgent(agentId: "   ", query: "Build")) == "w2:p1")

        let ambiguous = herd.resolveAgent(agentId: nil, query: "p1")
        guard case .failure(let message) = ambiguous else {
            Issue.record("expected an ambiguous query")
            return
        }
        #expect(message.contains("w1:p1"))
        #expect(message.contains("w2:p1"))
        #expect(message.contains("ambiguous"))

        #expect(herd.resolveAgent(agentId: nil, query: "  ") == .failure(
            "Missing required parameter: provide agent_id or query"
        ))
        #expect(herd.resolveAgent(agentId: nil, query: "nope") == .failure(
            "No agent matches query 'nope'"
        ))

        let named = HerdSnapshot(
            version: "0.7.5",
            protocol: 17,
            agents: [
                info(pane: "w1:p1", workspace: "w1", tab: "w1:t1", title: "Review"),
                info(pane: "w2:p1", workspace: "w2", tab: "w2:t1", title: "Build")
            ],
            workspaceNames: ["w1": "Proj", "w2": "Other"],
            tabNames: ["w1:t1": "main", "w2:t1": "side"],
            focusedWorkspaceId: nil,
            focusedTabId: nil,
            focusedPaneId: nil,
            paneLabels: ["w1:p1": "api"]
        )
        #expect(pane(named.resolveAgent(agentId: nil, query: "api")) == "w1:p1")
    }

    private func pane(_ resolution: AgentResolution) -> String? {
        guard case .found(let info) = resolution else { return nil }
        return info.paneId
    }

    private func snapshot(_ agents: [HerdrAgentInfo]) -> HerdSnapshot {
        HerdSnapshot(
            version: "0.7.5",
            protocol: 17,
            agents: agents,
            workspaceNames: ["w1": "Proj", "w2": "Other", "other": "Odd"],
            tabNames: ["w1:t1": "main", "w2:t1": "side", "other:t1": "odd"],
            focusedWorkspaceId: nil,
            focusedTabId: nil,
            focusedPaneId: nil
        )
    }

    private func info(
        pane: String,
        workspace: String,
        tab: String? = nil,
        title: String
    ) -> HerdrAgentInfo {
        HerdrAgentInfo(
            paneId: pane,
            workspaceId: workspace,
            tabId: tab ?? "\(workspace):t1",
            agent: "claude",
            displayAgent: nil,
            name: nil,
            title: title,
            terminalTitleStripped: title,
            agentStatus: "blocked",
            agentSession: nil,
            focused: false,
            stateChangeSeq: 1,
            cwd: nil,
            foregroundCwd: nil,
            revision: nil,
            tokens: [:],
            stateLabels: [:],
            interactiveReady: false,
            launchPending: false
        )
    }
}
