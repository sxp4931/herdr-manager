import Foundation

extension HerdSnapshot {
    /// herdmgr's live table after one subscription event. Rows an event
    /// introduces are labelled from this snapshot; the same staleness rules
    /// as `AgentStore.applyEvent` apply.
    ///
    /// `pane_created` adds nothing: every new pane starts as a plain shell,
    /// and a placeholder row for it showed as an unknown agent until the
    /// next resync. An agent gets a row from the `pane_updated` that first
    /// names its kind, whether or not a `pane_created` came before it.
    public func applying(_ event: HerdrEvent, to agents: [Agent], now: Date = Date()) -> [Agent] {
        var agents = agents
        switch event {
        case .agentStatusChanged(let paneId, let agentStatus, let seq):
            guard let idx = agents.firstIndex(where: { $0.id.raw == paneId }) else { break }
            if let seq, seq < agents[idx].stateChangeSeq { break }
            let newStatus = AgentStatus(rawValue: agentStatus) ?? .unknown
            if newStatus != agents[idx].status {
                agents[idx].enteredAt = now
            }
            agents[idx].status = newStatus
            if let seq { agents[idx].stateChangeSeq = seq }
            agents[idx].verdict = Self.displayVerdict(for: newStatus, now: now)

        case .paneUpdated(let info):
            guard !info.paneId.isEmpty else { break }
            let idx = agents.firstIndex(where: { $0.id.raw == info.paneId })
            // A real seq behind the stored one is an older state; a missing
            // seq (0) keeps the agent.list value.
            if info.stateChangeSeq != 0, let idx, info.stateChangeSeq < agents[idx].stateChangeSeq {
                break
            }
            guard let idx else {
                // First word of this agent (a plain shell yields nil).
                if let agent = displayAgent(for: info, now: now) {
                    agents.append(agent)
                }
                break
            }
            guard info.agent?.isEmpty == false else {
                // The pane dropped back to a plain shell.
                agents.remove(at: idx)
                break
            }
            let newStatus = AgentStatus(rawValue: info.agentStatus) ?? .unknown
            if newStatus != agents[idx].status {
                agents[idx].enteredAt = now
            }
            agents[idx].status = newStatus
            if info.stateChangeSeq != 0 { agents[idx].stateChangeSeq = info.stateChangeSeq }
            agents[idx].verdict = Self.displayVerdict(for: newStatus, now: now)

        case .paneClosed(let paneId), .paneExited(let paneId):
            agents.removeAll { $0.id.raw == paneId }

        case .paneMoved(let paneId, let workspaceId, let tabId):
            if let idx = agents.firstIndex(where: { $0.id.raw == paneId }) {
                if let ws = workspaceId { agents[idx].workspaceName = workspaceNames[ws] ?? ws }
                if let tab = tabId { agents[idx].tabName = tabNames[tab] ?? tab }
            }

        case .paneCreated, .paneFocused, .workspacesChanged, .connected, .disconnected, .ignored:
            break
        }
        return agents
    }
}
