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
    ///
    /// `aliases` is the `name` from the last `agent.list` (`herdr agent
    /// rename` / `agent start`). `pane_updated` and `pane_moved` do not
    /// carry that field. Omit the map and a terminal title is the name.
    /// `preservingExistingName` is false when the occupant changed: the
    /// previous person's name is not this row's.
    public func applying(
        _ event: HerdrEvent,
        to agents: [Agent],
        tabIds: [String: String] = [:],
        aliases: [String: String] = [:],
        preservingExistingName: Bool = true,
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
                if var agent = displayAgent(for: info, now: now) {
                    // `displayAgent` cannot see a rename stored for an id
                    // this table has not drawn yet. The list already did.
                    if let alias = aliases[info.paneId],
                       let named = AgentLabel.preferred(
                           title: info.title,
                           displayAgent: info.displayAgent,
                           name: alias,
                           terminalTitleStripped: info.terminalTitleStripped
                       ) {
                        agent.name = named
                        agent.displayName = named
                    }
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
            // A title, kind, directory, or tab change is not a new episode.
            // A missing title keeps the row's current value: a seq-less
            // payload leaves fields off, and a workspace this snapshot has
            // not labelled yet may still be wearing the name the move created.
            // The rename from the last list outranks the terminal title on
            // this event, which does not carry `name`.
            applyPresentation(
                of: info,
                to: &agents[idx],
                alias: aliases[info.paneId],
                preservingExistingName: preservingExistingName
            )

        case .paneClosed(let paneId), .paneExited(let paneId):
            agents.removeAll { $0.id.raw == paneId }

        case .paneMoved(let previousPaneId, let info, let createdWorkspaceLabel, let createdTabLabel):
            agents = applyingPaneMove(
                previousPaneId: previousPaneId,
                info: info,
                createdWorkspaceLabel: createdWorkspaceLabel,
                createdTabLabel: createdTabLabel,
                aliases: aliases,
                preservingExistingName: preservingExistingName,
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
        aliases: [String: String],
        preservingExistingName: Bool,
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
        // The status poll does not insert a pane, so a replayed move would
        // otherwise stick.
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
        // A list that already contains the destination is the authority for
        // `name`. The id the row is leaving still has the old rename, and
        // carrying it would undo `agent rename --clear` on the refetch that
        // ran ahead of this move. A move that lands before any list has the
        // new id still uses the rename stored for the id it left.
        let listed = self.agents.first { $0.paneId == info.paneId }
        let alias: String?
        if !preservingExistingName {
            // The occupant changed. herdr clears the rename, and the name
            // on the last list is the person who left.
            alias = nil
        } else if listed != nil {
            alias = listed.flatMap { AgentLabel.nonempty($0.name) }
        } else {
            alias = aliases[previousRaw] ?? (previousRaw == info.paneId ? nil : aliases[info.paneId])
        }
        let name = AgentLabel.preferred(
            title: info.title,
            displayAgent: info.displayAgent,
            name: alias,
            terminalTitleStripped: info.terminalTitleStripped
        ) ?? (preservingExistingName ? existing?.name : nil) ?? agentKind
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
            cwd: AgentLabel.nonempty(info.foregroundCwd)
                ?? AgentLabel.nonempty(info.cwd)
                ?? existing?.cwd
                ?? ""
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
    /// The name uses `AgentLabel`: a metadata title, then `display_agent`,
    /// then `alias` (the rename from the last list), then the stripped
    /// terminal title. An empty string is absent. Kind prefers the session's
    /// agent when that string is non-empty, then the detected `agent`.
    /// Directory prefers `foreground_cwd`. Workspace and tab update only
    /// when this snapshot already has a label for the id, so a raw id cannot
    /// replace a name the move just created. When every name source is
    /// absent the row keeps its name, unless the occupant changed.
    private func applyPresentation(
        of info: HerdrAgentInfo,
        to agent: inout Agent,
        alias: String?,
        preservingExistingName: Bool
    ) {
        guard let agentKind = info.agent, !agentKind.isEmpty else { return }
        if let session = info.agentSession, !session.agent.isEmpty {
            agent.kind = .custom(session.agent)
        } else {
            agent.kind = .custom(agentKind)
        }
        if let name = AgentLabel.preferred(
            title: info.title,
            displayAgent: info.displayAgent,
            name: alias,
            terminalTitleStripped: info.terminalTitleStripped
        ) {
            agent.name = name
            agent.displayName = name
        } else if !preservingExistingName {
            agent.name = agentKind
            agent.displayName = agentKind
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
