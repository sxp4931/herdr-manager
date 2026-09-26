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

        case .paneMoved(let previousPaneId, let info, let createdWorkspaceLabel, let createdTabLabel):
            agents = applyingPaneMove(
                previousPaneId: previousPaneId,
                info: info,
                createdWorkspaceLabel: createdWorkspaceLabel,
                createdTabLabel: createdTabLabel,
                to: agents,
                now: now
            )

        case .paneCreated, .paneFocused, .workspacesChanged, .connected, .disconnected, .ignored:
            break
        }
        return agents
    }

    /// herdmgr's row after `pane_moved`. The id change is the event: the
    /// live table has no poll, and herdr does not emit close/create, so
    /// leaving the row on `previousPaneId` drops every later status event.
    /// A same-status move keeps the dwell. Labels prefer this snapshot,
    /// then the container the move created.
    private func applyingPaneMove(
        previousPaneId: String,
        info: HerdrAgentInfo,
        createdWorkspaceLabel: String?,
        createdTabLabel: String?,
        to agents: [Agent],
        now: Date
    ) -> [Agent] {
        guard !info.paneId.isEmpty else { return agents }
        let previousRaw = previousPaneId.isEmpty ? info.paneId : previousPaneId
        let existing = agents.first { $0.id.raw == previousRaw }
            ?? (previousRaw == info.paneId ? nil : agents.first { $0.id.raw == info.paneId })

        // Same rule as `AgentStore.applyPaneMove`. The wire event has no
        // seq. Re-key a row we already show; do not invent one, and do not
        // open a new dwell from the status riding along on the move.
        // herdmgr has no poll, so a replayed move would otherwise stick.
        if info.stateChangeSeq == 0 && existing == nil {
            return agents
        }

        guard let agentKind = info.agent, !agentKind.isEmpty else {
            return agents.filter { $0.id.raw != previousRaw && $0.id.raw != info.paneId }
        }

        let seqIsMeaningful = info.stateChangeSeq != 0
        let seqBehind = seqIsMeaningful && existing != nil && info.stateChangeSeq < existing!.stateChangeSeq
        let status: AgentStatus
        if !seqIsMeaningful, let existing {
            status = existing.status
        } else if seqBehind {
            status = existing!.status
        } else {
            status = AgentStatus(rawValue: info.agentStatus) ?? .unknown
        }
        let statusChanged = existing?.status != status
        let stateChangeSeq: UInt64
        if !seqIsMeaningful, let existing {
            stateChangeSeq = existing.stateChangeSeq
        } else if seqBehind {
            stateChangeSeq = existing!.stateChangeSeq
        } else if seqIsMeaningful {
            stateChangeSeq = info.stateChangeSeq
        } else {
            stateChangeSeq = existing?.stateChangeSeq ?? 0
        }
        let kind: AgentKind
        if let session = info.agentSession {
            kind = .custom(session.agent)
        } else {
            kind = .custom(agentKind)
        }
        let name = info.title ?? info.terminalTitleStripped ?? existing?.name ?? agentKind
        let wsName = labeled(info.workspaceId, in: workspaceNames, created: createdWorkspaceLabel)
            ?? existing?.workspaceName
            ?? ""
        let tabName = labeled(info.tabId, in: tabNames, created: createdTabLabel)
            ?? existing?.tabName
            ?? ""
        let updated = Agent(
            id: AgentID(info.paneId),
            kind: kind,
            name: name,
            displayName: name,
            status: status,
            stateChangeSeq: stateChangeSeq,
            enteredAt: (existing == nil || statusChanged) ? now : existing!.enteredAt,
            lastOutputAt: existing?.lastOutputAt,
            verdict: (existing == nil || statusChanged) ? Self.displayVerdict(for: status, now: now) : existing!.verdict,
            workspaceName: wsName,
            tabName: tabName,
            cwd: info.foregroundCwd ?? info.cwd ?? existing?.cwd ?? ""
        )

        var kept = agents.filter { row in
            if previousRaw != info.paneId && row.id.raw == previousRaw { return false }
            if row.id.raw == info.paneId { return false }
            return true
        }
        let insertAt = agents.firstIndex { $0.id.raw == previousRaw || $0.id.raw == info.paneId } ?? kept.count
        kept.insert(updated, at: min(insertAt, kept.count))
        return kept
    }

    private func labeled(_ id: String, in names: [String: String], created: String?) -> String? {
        guard !id.isEmpty else { return nil }
        if let known = names[id], !known.isEmpty { return known }
        if let created, !created.isEmpty { return created }
        return id
    }
}
