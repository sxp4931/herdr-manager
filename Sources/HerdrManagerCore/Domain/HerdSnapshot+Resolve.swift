import Foundation

/// One attempt to name an agent in a herd snapshot.
public enum AgentResolution: Sendable, Equatable {
    case found(HerdrAgentInfo)
    case failure(String)
}

extension HerdSnapshot {
    /// The agent a read tool should open.
    ///
    /// `agentId` is matched against the full pane id first (`w1:p1`).
    /// Anything else is compared to the local piece `AgentID.paneId`
    /// (`p1` of `w1:p1`). That piece is what the overview used to print,
    /// so a caller that copied it still resolves when exactly one pane
    /// has it. Two panes with the same piece are not a guess: the failure
    /// names both full ids. An exact id wins over a pane whose own suffix
    /// happens to be that whole string.
    ///
    /// An empty id is not a lookup. The query is used only then. A query
    /// has to match one agent, on the same fields as
    /// `paneIds(matchingQuery:)`. A blank query is an error here. The
    /// list treats a blank query as no filter.
    public func resolveAgent(agentId: String?, query: String?) -> AgentResolution {
        if let agentId {
            let trimmed = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return resolveListed(agentId: trimmed)
            }
        }
        return resolveQuery(query)
    }

    private func resolveListed(agentId: String) -> AgentResolution {
        if let exact = agents.first(where: { $0.paneId == agentId }) {
            return .found(exact)
        }

        let suffixMatches = agents.filter { info in
            let local = AgentID(info.paneId).paneId
            return !local.isEmpty && local == agentId
        }
        if suffixMatches.count == 1, let only = suffixMatches.first {
            return .found(only)
        }
        if suffixMatches.count > 1 {
            let listed = suffixMatches.map(\.paneId).sorted().joined(separator: ", ")
            return .failure(
                "Agent id '\(agentId)' matches more than one pane: \(listed). Pass the full id."
            )
        }
        return .failure("Agent not found: \(agentId)")
    }

    /// Pane ids a list filter should keep. Nil when `query` is blank,
    /// which is not a filter. Otherwise every pane whose fields contain
    /// the trimmed query, including several.
    ///
    /// The row's name collapses title, `display_agent`, the agent rename,
    /// the pane label, and the terminal title into one string. Searching
    /// only that string hid a pane label or a terminal title that the
    /// read tools already matched, and the Kind column is the session
    /// agent when herdr named one. The read tools used to search only the
    /// detected agent, so that column did not resolve. Both sides use
    /// this list. A directory hidden behind a foreground directory is
    /// not a field: the row shows the foreground one.
    public func paneIds(matchingQuery query: String) -> Set<String>? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return Set(agents.filter { matchesQuery(needle, info: $0) }.map(\.paneId))
    }

    private func resolveQuery(_ query: String?) -> AgentResolution {
        guard let query,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("Missing required parameter: provide agent_id or query")
        }

        let matches = agents.filter { matchesQuery(query, info: $0) }

        if matches.count == 1, let match = matches.first {
            return .found(match)
        }
        if matches.isEmpty {
            return .failure("No agent matches query '\(query)'")
        }

        // Eight lines, then a count. A short query can match the whole
        // herd, and naming only the first eight looked like that was all.
        let listed = matches.prefix(8)
        let candidates = listed.map { candidateSummary(for: $0) }.joined(separator: "; ")
        var message = "Query '\(query)' is ambiguous. Matches: \(candidates)"
        let remaining = matches.count - listed.count
        if remaining > 0 {
            message += "; and \(remaining) more"
        }
        return .failure(message)
    }

    private func matchesQuery(_ query: String, info: HerdrAgentInfo) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        return queryFields(for: info).contains { $0.lowercased().contains(needle) }
    }

    private func queryFields(for info: HerdrAgentInfo) -> [String] {
        [
            info.paneId,
            info.agent ?? "",
            info.agentSession?.agent ?? "",
            info.displayAgent ?? "",
            info.name ?? "",
            info.title ?? "",
            info.terminalTitleStripped ?? "",
            workspaceNames[info.workspaceId] ?? info.workspaceId,
            tabNames[info.tabId] ?? info.tabId,
            info.workingDirectory ?? "",
            paneLabels[info.paneId] ?? "",
        ]
    }

    /// The name the row shows, plus the pane label when a higher field
    /// covered it. The label leads the terminal title, which is the row's
    /// order.
    private func candidateSummary(for info: HerdrAgentInfo) -> String {
        let paneLabel = AgentLabel.nonempty(paneLabels[info.paneId])
        let title = AgentLabel.preferred(
            title: info.title,
            displayAgent: info.displayAgent,
            name: info.name,
            terminalTitleStripped: info.terminalTitleStripped,
            paneLabel: paneLabel
        ) ?? info.agent ?? "unknown"
        let workspace = workspaceNames[info.workspaceId] ?? info.workspaceId
        let tab = tabNames[info.tabId] ?? info.tabId
        let labelNote: String
        if let paneLabel, paneLabel != title {
            labelNote = ", pane \(paneLabel)"
        } else {
            labelNote = ""
        }
        return "\(info.paneId) (\(title)\(labelNote), \(workspace) / \(tab))"
    }
}
