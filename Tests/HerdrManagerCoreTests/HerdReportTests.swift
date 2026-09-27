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

@Suite("agent.list status and workspace filters")
struct AgentListFilterTests {
    private let names = ["w1": "Proj", "w2": "Other", "w100": "Long"]

    private func sample() -> [Agent] {
        let blocked = Agent(
            id: AgentID("w1:p1"),
            name: "Review",
            status: .blocked,
            verdict: .awaitingInput(BlockClassification(
                kind: .confirmation, since: Date(), summary: "confirmation prompt"
            )),
            workspaceName: "not the printed name"
        )
        let working = Agent(
            id: AgentID("w1:p2"),
            name: "Build",
            status: .working,
            verdict: .healthy,
            workspaceName: "Proj"
        )
        let quiet = Agent(
            id: AgentID("w1:p3"),
            name: "Quiet",
            status: .working,
            verdict: .silent(since: Date(), cpu: nil),
            workspaceName: "Proj"
        )
        let crashedWorking = Agent(
            id: AgentID("w1:p4"),
            name: "Crash",
            status: .working,
            verdict: .processGone(lastLine: "zsh"),
            workspaceName: "Proj"
        )
        let crashedBlocked = Agent(
            id: AgentID("w2:p1"),
            name: "Prompt",
            status: .blocked,
            verdict: .processGone(lastLine: "zsh"),
            workspaceName: "Other"
        )
        let done = Agent(
            id: AgentID("w2:p2"),
            name: "Finished",
            status: .done,
            verdict: .healthy,
            workspaceName: "Other"
        )
        let doneQuiet = Agent(
            id: AgentID("w2:p3"),
            name: "Stale",
            status: .done,
            verdict: .silent(since: Date(), cpu: nil),
            workspaceName: "Other"
        )
        let doneGone = Agent(
            id: AgentID("w2:p4"),
            name: "Died",
            status: .done,
            verdict: .processGone(lastLine: "zsh"),
            workspaceName: "Other"
        )
        let idle = Agent(
            id: AgentID("w100:p1"),
            name: "Idle",
            status: .idle,
            verdict: .healthy,
            workspaceName: "Long"
        )
        return [blocked, working, quiet, crashedWorking, crashedBlocked, done, doneQuiet, doneGone, idle]
    }

    private func ids(status: String, workspace: String = "") -> [String] {
        guard case .parsed(let parsed) = AgentListFilter.parseStatus(status) else {
            return ["unrecognized"]
        }
        return sample().filter {
            AgentListFilter.matchesStatus($0, status: parsed)
                && AgentListFilter.matchesWorkspace($0, query: workspace, workspaceNames: names)
        }.map(\.id.raw).sorted()
    }

    @Test("herdr statuses keep their rows, including a crash still marked working")
    func herdrStatuses() {
        #expect(AgentListFilter.parseStatus(" WORKING ") == .parsed(.herdr(.working)))
        #expect(ids(status: "working") == ["w1:p2", "w1:p3", "w1:p4"])
        #expect(ids(status: " blocked ") == ["w1:p1", "w2:p1"])
        #expect(ids(status: "done") == ["w2:p2", "w2:p3", "w2:p4"])
        #expect(ids(status: "idle") == ["w100:p1"])
        #expect(AgentListFilter.parseStatus("unknown") == .parsed(.herdr(.unknown)))
        #expect(ids(status: "   ") == [
            "w100:p1", "w1:p1", "w1:p2", "w1:p3", "w1:p4", "w2:p1", "w2:p2", "w2:p3", "w2:p4"
        ])
    }

    @Test("gone and silent select the overview marks, and a stale quiet on done does not")
    func marks() {
        #expect(AgentListFilter.parseStatus(" GONE ") == .parsed(.gone))
        #expect(AgentListFilter.parseStatus("Quiet") == .parsed(.silent))
        #expect(ids(status: "gone") == ["w1:p4", "w2:p1", "w2:p4"])
        #expect(ids(status: "silent") == ["w1:p3"])
        #expect(ids(status: " quiet ") == ["w1:p3"])
    }

    @Test("An unknown status is refused, and it is not the whole herd")
    func unknownStatus() {
        #expect(AgentListFilter.parseStatus(" running ") == .unrecognized("running"))
        #expect(AgentListFilter.parseStatus("blockedd") == .unrecognized("blockedd"))
        #expect(ids(status: "running") == ["unrecognized"])
    }

    @Test("A workspace filter trims, ignores case, and still matches the id")
    func workspace() {
        #expect(ids(status: "working", workspace: "  proj ") == ["w1:p2", "w1:p3", "w1:p4"])
        #expect(ids(status: "gone", workspace: "W2") == ["w2:p1", "w2:p4"])
        #expect(ids(status: "", workspace: "w100") == ["w100:p1"])
        #expect(ids(status: "", workspace: "  ") == [
            "w100:p1", "w1:p1", "w1:p2", "w1:p3", "w1:p4", "w2:p1", "w2:p2", "w2:p3", "w2:p4"
        ])
        #expect(ids(status: "working", workspace: "nope") == [])
        // The list prints the snapshot name, not a different name stored on the row.
        #expect(ids(status: "blocked", workspace: "not the printed name") == [])
        #expect(ids(status: "blocked", workspace: "pro") == ["w1:p1"])
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

    @Test("A list query matches the fields inspect uses, including a name the row does not show")
    func listQueryMatchesInspectFields() {
        let claude = info(
            pane: "w1:p1",
            workspace: "w1",
            title: "Review",
            agent: "claude",
            displayAgent: "Reviewer",
            name: "renamed",
            terminalTitle: "Action Required",
            session: HerdrSnapshot.AgentSession(
                source: "agent", agent: "OpenCode", kind: "session", value: "sess-1"
            ),
            cwd: "/hidden",
            foregroundCwd: "/work"
        )
        let other = info(pane: "w2:p1", workspace: "w2", title: "Build", agent: "codex")
        let herd = snapshot([claude, other], paneLabels: ["w1:p1": "api"])

        #expect(pane(herd.resolveAgent(agentId: nil, query: "api")) == "w1:p1")
        #expect(pane(herd.resolveAgent(agentId: nil, query: "  API  ")) == "w1:p1")
        #expect(pane(herd.resolveAgent(agentId: nil, query: "Action Required")) == "w1:p1")
        #expect(pane(herd.resolveAgent(agentId: nil, query: "Reviewer")) == "w1:p1")
        #expect(pane(herd.resolveAgent(agentId: nil, query: "renamed")) == "w1:p1")
        #expect(pane(herd.resolveAgent(agentId: nil, query: "OpenCode")) == "w1:p1")
        #expect(pane(herd.resolveAgent(agentId: nil, query: "/work")) == "w1:p1")
        #expect(herd.resolveAgent(agentId: nil, query: "/hidden") == .failure(
            "No agent matches query '/hidden'"
        ))
        // The Kind column is the session agent. It does not contain the
        // detected kind, and the detected kind does not contain it.
        #expect(herd.paneIds(matchingQuery: "OpenCode") == Optional(Set(["w1:p1"])))
        #expect(herd.paneIds(matchingQuery: "opencode") == Optional(Set(["w1:p1"])))
        #expect(herd.paneIds(matchingQuery: "claude") == Optional(Set(["w1:p1"])))
        #expect(herd.paneIds(matchingQuery: "codex") == Optional(Set(["w2:p1"])))
        #expect(herd.paneIds(matchingQuery: "api") == Optional(Set(["w1:p1"])))
        #expect(herd.paneIds(matchingQuery: "  API  ") == Optional(Set(["w1:p1"])))
        #expect(herd.paneIds(matchingQuery: "  ") == nil)
        #expect(herd.paneIds(matchingQuery: "") == nil)
    }

    @Test("An ambiguous query names a covered pane label, and that label leads the terminal title")
    func ambiguousQueryNamesPaneLabel() {
        let covered = snapshot([
            info(pane: "w1:p1", workspace: "w1", title: "Review", terminalTitle: "Bash"),
            info(pane: "w2:p1", workspace: "w2", title: "Review", terminalTitle: "Bash")
        ], paneLabels: ["w1:p1": "api", "w2:p1": "web"])
        #expect(covered.resolveAgent(agentId: nil, query: "Review") == .failure(
            "Query 'Review' is ambiguous. Matches: w1:p1 (Review, pane api, Proj / main); w2:p1 (Review, pane web, Other / side)"
        ))
        #expect(covered.paneIds(matchingQuery: "Review") == Optional(Set(["w1:p1", "w2:p1"])))

        let labeled = snapshot([
            info(pane: "w1:p1", workspace: "w1", title: "", terminalTitle: "Bash"),
            info(pane: "w2:p1", workspace: "w2", title: "", terminalTitle: "Bash")
        ], paneLabels: ["w1:p1": "api", "w2:p1": "web"])
        #expect(labeled.resolveAgent(agentId: nil, query: "Bash") == .failure(
            "Query 'Bash' is ambiguous. Matches: w1:p1 (api, Proj / main); w2:p1 (web, Other / side)"
        ))
        #expect(pane(labeled.resolveAgent(agentId: nil, query: "api")) == "w1:p1")
    }

    @Test("An ambiguous query says when more than eight panes match")
    func ambiguousQueryCountsTheRest() {
        let agents = (1...9).map { info(pane: "w1:p\($0)", workspace: "w1", title: "Review") }
        let herd = snapshot(agents)
        let result = herd.resolveAgent(agentId: nil, query: "Review")
        guard case .failure(let message) = result else {
            Issue.record("expected an ambiguous query")
            return
        }
        #expect(message.contains("w1:p1 ("))
        #expect(message.contains("w1:p8 ("))
        #expect(!message.contains("w1:p9"))
        #expect(message.hasSuffix("and 1 more"))
    }

    private func pane(_ resolution: AgentResolution) -> String? {
        guard case .found(let info) = resolution else { return nil }
        return info.paneId
    }

    private func snapshot(
        _ agents: [HerdrAgentInfo],
        paneLabels: [String: String] = [:]
    ) -> HerdSnapshot {
        HerdSnapshot(
            version: "0.7.5",
            protocol: 17,
            agents: agents,
            workspaceNames: ["w1": "Proj", "w2": "Other", "other": "Odd"],
            tabNames: ["w1:t1": "main", "w2:t1": "side", "other:t1": "odd"],
            focusedWorkspaceId: nil,
            focusedTabId: nil,
            focusedPaneId: nil,
            paneLabels: paneLabels
        )
    }

    private func info(
        pane: String,
        workspace: String,
        tab: String? = nil,
        title: String,
        agent: String = "claude",
        displayAgent: String? = nil,
        name: String? = nil,
        terminalTitle: String? = nil,
        session: HerdrSnapshot.AgentSession? = nil,
        cwd: String? = nil,
        foregroundCwd: String? = nil
    ) -> HerdrAgentInfo {
        HerdrAgentInfo(
            paneId: pane,
            workspaceId: workspace,
            tabId: tab ?? "\(workspace):t1",
            agent: agent,
            displayAgent: displayAgent,
            name: name,
            title: title,
            terminalTitleStripped: terminalTitle ?? title,
            agentStatus: "blocked",
            agentSession: session,
            focused: false,
            stateChangeSeq: 1,
            cwd: cwd,
            foregroundCwd: foregroundCwd,
            revision: nil,
            tokens: [:],
            stateLabels: [:],
            interactiveReady: false,
            launchPending: false
        )
    }
}
