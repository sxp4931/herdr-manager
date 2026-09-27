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
    /// has to match one agent; the same fields as before, including the
    /// full pane id.
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

    private func resolveQuery(_ query: String?) -> AgentResolution {
        guard let query,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("Missing required parameter: provide agent_id or query")
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = agents.filter { info in
            let fields = [
                info.paneId,
                info.agent ?? "",
                info.displayAgent ?? "",
                info.name ?? "",
                info.title ?? "",
                info.terminalTitleStripped ?? "",
                workspaceNames[info.workspaceId] ?? info.workspaceId,
                tabNames[info.tabId] ?? info.tabId,
                info.workingDirectory ?? ""
            ]
            return fields.contains { $0.lowercased().contains(needle) }
        }

        if matches.count == 1, let match = matches.first {
            return .found(match)
        }
        if matches.isEmpty {
            return .failure("No agent matches query '\(query)'")
        }

        let candidates = matches.prefix(8).map { info in
            let title = AgentLabel.preferred(
                title: info.title,
                displayAgent: info.displayAgent,
                name: info.name,
                terminalTitleStripped: info.terminalTitleStripped
            ) ?? info.agent ?? "unknown"
            let workspace = workspaceNames[info.workspaceId] ?? info.workspaceId
            let tab = tabNames[info.tabId] ?? info.tabId
            return "\(info.paneId) (\(title), \(workspace) / \(tab))"
        }.joined(separator: "; ")
        return .failure("Query '\(query)' is ambiguous. Matches: \(candidates)")
    }
}
