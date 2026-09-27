import Foundation

/// Text `herd.overview` and `agent.list` return.
///
/// The id in each row is `AgentID.raw` (`w1:p1`). That is the `agent_id`
/// every other tool matches against `HerdrAgentInfo.paneId`. `AgentID.paneId`
/// is only the suffix after the first colon (`p1`). Printing the suffix,
/// and cutting it to fit a column, handed callers an id that looks up
/// nothing — and the same suffix on two workspaces could not be told apart.
public enum HerdReport: Sendable {

    /// Kind text for a row. A custom kind keeps the string herdr sent.
    /// `AgentKind.label` lowercases it; the list and the list filter have
    /// to agree, and a filter for the stored spelling would miss.
    public static func kindText(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        case .aider: return "aider"
        case .gemini: return "gemini"
        case .custom(let name): return name
        }
    }

    public static func overview(
        agents: [Agent],
        workspaceNames: [String: String]
    ) -> String {
        guard !agents.isEmpty else {
            return "Herd Overview — 0 agents\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nNo agents found."
        }

        // Count statuses. Mutually exclusive, worst-first — a gone pane
        // with a leftover working/silent label is gone, not working.
        let counts = AttentionTriage.counts(agents)
        let gone = counts.gone
        let blocked = counts.blocked
        let silent = counts.silent
        let done = counts.done
        let working = counts.working
        let idle = agents.filter { AttentionTriage.kind(for: $0) == .idle }.count

        var byWorkspace: [String: [Agent]] = [:]
        for agent in agents {
            let wsKey = agent.id.workspaceId
            byWorkspace[wsKey, default: []].append(agent)
        }

        var lines: [String] = []
        lines.append("Herd Overview — \(agents.count) agents across \(byWorkspace.count) workspace\(byWorkspace.count == 1 ? "" : "s")")
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        var statusParts: [String] = []
        if gone > 0 { statusParts.append("\(AttentionTriage.statusMark(for: AttentionTriage.Kind.gone)) \(gone) gone") }
        if blocked > 0 { statusParts.append("\(AttentionTriage.statusMark(for: AttentionTriage.Kind.blocked)) \(blocked) blocked") }
        if silent > 0 { statusParts.append("\(AttentionTriage.statusMark(for: AttentionTriage.Kind.silent)) \(silent) silent") }
        if done > 0 { statusParts.append("\(AttentionTriage.statusMark(for: AttentionTriage.Kind.done)) \(done) done") }
        if working > 0 {
            statusParts.append("\(AttentionTriage.statusMark(for: AttentionTriage.Kind.working, working: "🟡")) \(working) working")
        }
        if idle > 0 { statusParts.append("\(AttentionTriage.statusMark(for: AttentionTriage.Kind.idle)) \(idle) idle") }
        let unknown = agents.filter { AttentionTriage.kind(for: $0) == .unknown }.count
        if unknown > 0 {
            statusParts.append("\(AttentionTriage.statusMark(for: AttentionTriage.Kind.unknown)) \(unknown) unknown")
        }
        lines.append(statusParts.joined(separator: " · "))
        lines.append("")

        let sortedWs = byWorkspace.keys.sorted {
            let nameA = workspaceNames[$0] ?? $0
            let nameB = workspaceNames[$1] ?? $1
            return nameA < nameB
        }

        for wsId in sortedWs {
            let wsAgents = byWorkspace[wsId] ?? []
            let wsName = workspaceNames[wsId] ?? wsId
            lines.append("\(wsName) (\(wsId)) — \(wsAgents.count) agent\(wsAgents.count == 1 ? "" : "s")")

            // Worst first (gone/blocked, silent, done, rest), then by pane id
            // so equal-priority rows keep their order between calls.
            let sorted = wsAgents.sorted(by: AttentionTriage.ranksBefore)
            for agent in sorted {
                let glyph = AttentionTriage.statusMark(for: agent, working: "🟡")
                let verdictHint = agent.verdict.summaryLine ?? agent.status.rawValue
                lines.append("  \(glyph) \(agent.name) [\(agent.id.raw)] — \(verdictHint)")
            }
            lines.append("")
        }

        lines.append("Agent id for other tools is the bracketed workspace:pane value.")
        return lines.joined(separator: "\n")
    }

    public static func agentList(
        agents: [Agent],
        workspaceNames: [String: String]
    ) -> String {
        guard !agents.isEmpty else {
            return "No agents found."
        }

        var lines: [String] = []
        lines.append(pad("Status", 8) + " " + pad("Name", 20) + " " + pad("Kind", 10) + " " + pad("Workspace", 12) + " " + pad("ID", 8) + " Verdict")
        lines.append(String(repeating: "─", count: 90))

        let sorted = agents.sorted(by: AttentionTriage.ranksBefore)
        for agent in sorted {
            let glyph = AttentionTriage.statusMark(for: agent, working: "🟡")
            let kindStr = kindText(agent.kind)
            let wsName = workspaceNames[agent.id.workspaceId] ?? agent.id.workspaceId
            let verdictStr = agent.verdict.summaryLine ?? agent.status.rawValue
            // The id is not truncated. A column of 8 cut `w100:p1000`
            // down to a string that is not a pane, and the old column
            // was the suffix (`p1`) rather than `w1:p1`.
            lines.append(
                pad(glyph, 8) + " " + pad(truncate(agent.name, 20), 20) + " "
                    + pad(truncate(kindStr, 10), 10) + " " + pad(truncate(wsName, 12), 12) + " "
                    + pad(agent.id.raw, 8) + " " + truncate(verdictStr, 40)
            )
        }

        lines.append("")
        lines.append("Total: \(agents.count) agent\(agents.count == 1 ? "" : "s")")
        lines.append("ID is the agent_id other tools accept (workspace:pane, for example w5:p2).")
        return lines.joined(separator: "\n")
    }

    private static func truncate(_ string: String, _ maxLen: Int) -> String {
        if string.count <= maxLen { return string }
        return String(string.prefix(maxLen - 1)) + "…"
    }

    private static func pad(_ string: String, _ width: Int) -> String {
        if string.count >= width { return string }
        return string + String(repeating: " ", count: width - string.count)
    }
}
