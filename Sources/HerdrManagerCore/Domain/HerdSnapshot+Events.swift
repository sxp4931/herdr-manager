import Foundation

extension HerdSnapshot {
    /// `workspaceNames` after a rename. An empty id or label is not a
    /// rename. The same label returns this snapshot: a copy would look
    /// like a new herd to a caller that compares by value.
    public func renamingWorkspace(_ workspaceId: String, to label: String) -> HerdSnapshot {
        guard !workspaceId.isEmpty, !label.isEmpty, workspaceNames[workspaceId] != label else {
            return self
        }
        var names = workspaceNames
        names[workspaceId] = label
        return replacing(workspaceNames: names, tabNames: tabNames)
    }

    public func renamingTab(_ tabId: String, to label: String) -> HerdSnapshot {
        guard !tabId.isEmpty, !label.isEmpty, tabNames[tabId] != label else { return self }
        var names = tabNames
        names[tabId] = label
        return replacing(workspaceNames: workspaceNames, tabNames: names)
    }

    private func replacing(workspaceNames: [String: String], tabNames: [String: String]) -> HerdSnapshot {
        HerdSnapshot(
            version: version,
            protocol: `protocol`,
            agents: agents,
            workspaceNames: workspaceNames,
            tabNames: tabNames,
            focusedWorkspaceId: focusedWorkspaceId,
            focusedTabId: focusedTabId,
            focusedPaneId: focusedPaneId
        )
    }

    /// herdmgr's live table after one subscription event. Rows an event
    /// introduces are labelled from this snapshot; the same staleness rules
    /// as `AgentStore.applyEvent` apply. An existing row also takes the
    /// event's title, kind, directory, and any container this snapshot can
    /// already name. Those fields are not a new episode.
    ///
    /// `pane_created` adds nothing: every new pane starts as a plain shell,
    /// and a placeholder row for it showed as an unknown agent until the
    /// next resync. An agent gets a row from the `pane_updated` that first
    /// names its kind, whether or not a `pane_created` came before it.
    ///
    /// `tabIds` maps a pane id to the tab it is in. A tab rename has no
    /// other way to find the row: `Agent` stores the tab's label, not its
    /// id. Omit the map and a tab rename changes nothing.
    public func applying(
        _ event: HerdrEvent,
        to agents: [Agent],
        tabIds: [String: String] = [:],
        now: Date = Date()
    ) -> [Agent] {
        var agents = agents
        switch event {
        case .agentStatusChanged(let paneId, let agentStatus, let seq):
            guard let idx = agents.firstIndex(where: { $0.id.raw == paneId }) else { break }
            if let seq, seq < agents[idx].stateChangeSeq { break }
            let previous = agents[idx]
            let newStatus = AgentStatus(rawValue: agentStatus) ?? .unknown
            if newStatus != previous.status {
                agents[idx].enteredAt = now
            }
            agents[idx].status = newStatus
            if let seq { agents[idx].stateChangeSeq = seq }
            agents[idx].verdict = Self.verdict(replacing: previous, with: newStatus, now: now)

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
            let previous = agents[idx]
            let newStatus = AgentStatus(rawValue: info.agentStatus) ?? .unknown
            if newStatus != previous.status {
                agents[idx].enteredAt = now
            }
            agents[idx].status = newStatus
            if info.stateChangeSeq != 0 { agents[idx].stateChangeSeq = info.stateChangeSeq }
            agents[idx].verdict = Self.verdict(replacing: previous, with: newStatus, now: now)
            // herdmgr has no poll. This event is the only copy of a title,
            // kind, directory, or tab change, and none of those open an
            // episode. A missing title or an unknown container keeps the
            // row's current value: a seq-less payload leaves fields off,
            // and a workspace this snapshot has not labelled yet may still
            // be wearing the name the move created.
            applyPresentation(of: info, to: &agents[idx])

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

        case .workspaceRenamed(let workspaceId, let label):
            guard !workspaceId.isEmpty, !label.isEmpty else { break }
            for index in agents.indices where agents[index].id.workspaceId == workspaceId {
                agents[index].workspaceName = label
            }

        case .tabRenamed(let tabId, let label):
            guard !tabId.isEmpty, !label.isEmpty else { break }
            for index in agents.indices where tabIds[agents[index].id.raw] == tabId {
                agents[index].tabName = label
            }

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

    /// Fields on `pane_updated` that are not the status episode.
    ///
    /// `title` wins over the stripped terminal title, matching
    /// `displayAgent`. An empty string is absent. Kind prefers the session's
    /// agent when that string is non-empty, then the detected `agent`.
    /// Directory prefers `foreground_cwd`. Workspace and tab update only
    /// when this snapshot already has a label for the id, so a raw id cannot
    /// replace a name the move just created.
    private func applyPresentation(of info: HerdrAgentInfo, to agent: inout Agent) {
        guard let agentKind = info.agent, !agentKind.isEmpty else { return }
        if let session = info.agentSession, !session.agent.isEmpty {
            agent.kind = .custom(session.agent)
        } else {
            agent.kind = .custom(agentKind)
        }
        if let name = Self.nonempty(info.title) ?? Self.nonempty(info.terminalTitleStripped) {
            agent.name = name
            agent.displayName = name
        }
        if let directory = Self.nonempty(info.foregroundCwd) ?? Self.nonempty(info.cwd) {
            agent.cwd = directory
        }
        if let workspace = knownLabel(info.workspaceId, in: workspaceNames) {
            agent.workspaceName = workspace
        }
        if let tab = knownLabel(info.tabId, in: tabNames) {
            agent.tabName = tab
        }
    }

    /// A container this snapshot can name. An unknown id is not the raw id:
    /// the caller keeps the label the row already has.
    private func knownLabel(_ id: String, in names: [String: String]) -> String? {
        guard !id.isEmpty, let known = names[id], !known.isEmpty else { return nil }
        return known
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// A same-status update does not clear a crash. herdr keeps reporting
    /// working or blocked after the process has died, and that event is
    /// what would otherwise paint the status verdict back over the crash.
    /// A real status change is a new episode and takes the status verdict;
    /// the next process read stamps a crash again if the shell is still bare.
    private static func verdict(replacing previous: Agent, with status: AgentStatus, now: Date) -> Verdict {
        if status == previous.status, previous.verdict.isProcessGone {
            return previous.verdict
        }
        return displayVerdict(for: status, now: now)
    }

    private func labeled(_ id: String, in names: [String: String], created: String?) -> String? {
        guard !id.isEmpty else { return nil }
        if let known = names[id], !known.isEmpty { return known }
        if let created, !created.isEmpty { return created }
        return id
    }
}
