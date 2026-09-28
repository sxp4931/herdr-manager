import Foundation

extension HerdSnapshot {
    /// `displayAgents`, but carrying `enteredAt` over from `previous` for any
    /// pane whose episode (status *and* `state_change_seq`) has not moved.
    ///
    /// A snapshot refetch driven by a workspace/tab/layout event says nothing
    /// about the agents themselves; stamping a fresh `enteredAt` on all of
    /// them resets every dwell timer, which is the one number the caller is
    /// watching to see how long something has been stuck.
    ///
    /// `sessions` is the identity the caller had stored for each pane, keyed
    /// by pane id. When both that and this snapshot name one, and they
    /// differ, the episode did move: the status and seq can stay put while
    /// a new session takes the pane. Omit the map and every same-status row
    /// keeps its dwell, which is what a caller that has not tracked sessions
    /// does.
    public func displayAgents(
        preserving previous: [Agent],
        sessions previousSessions: [String: String] = [:],
        now: Date = Date()
    ) -> [Agent] {
        let byId = Dictionary(
            previous.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }
        )
        var incomingSessions: [String: String] = [:]
        for info in agents {
            guard !info.paneId.isEmpty, let session = info.sessionIdentity else { continue }
            incomingSessions[info.paneId] = session
        }
        return displayAgents(now: now).map { agent in
            // The caller's map is the occupant it tracked. A caller that
            // omitted the map still has the session on the previous row.
            // A list that leaves the field off is not a new person.
            let tracked = previousSessions[agent.id.raw]
            let incoming = incomingSessions[agent.id.raw]
            let session = SessionIdentity.carried(
                stored: tracked ?? byId[agent.id]?.sessionIdentity,
                incoming: incoming
            )
            guard let old = byId[agent.id],
                  old.status == agent.status,
                  old.stateChangeSeq == agent.stateChangeSeq,
                  !SessionIdentity.replaced(stored: tracked, incoming: incoming) else {
                var fresh = agent
                fresh.sessionIdentity = session
                return fresh
            }
            var merged = agent
            merged.sessionIdentity = session
            merged.enteredAt = old.enteredAt
            // The refetch rebuilds the row from herdr's status, which stays
            // working or blocked after the process dies. A crash already
            // stamped on this episode has to survive that rebuild; the next
            // process read clears it if the agent is actually back.
            if old.verdict.isProcessGone {
                merged.verdict = old.verdict
            }
            return merged
        }
    }
}

// MARK: - HerdLiveTable

/// herdmgr's live table.
///
/// A cross-workspace move emits `workspace.created`, `tab.created`,
/// `workspace.closed`, or `tab.closed` before `pane.moved`. herdr does not
/// emit close or create for the pane, and the new id is already in
/// `agent.list` by the time the layout event is handled. Refetching there
/// used to adopt the new id as a new row, and the move then kept that fresh
/// dwell because the old id was already gone.
///
/// The first layout refetch of a burst remembers the rows from before it.
/// Each `pane.moved` puts that row's `enteredAt` on its new id when the
/// status and `state_change_seq` are still the ones the refetch shows, and
/// the remembered rows stay so a second pane in the same burst is restored
/// too. A further refetch before any of those moves does not replace them:
/// herdr emits `workspace.created` and `tab.created` before `pane.moved`,
/// and the second snapshot would otherwise be the only copy, already
/// stamped with the reset dwell. A refetch after a move has been restored
/// starts a new burst from the rows as they are now. An event that changes
/// some row's id, status, or seq drops the copy: a seq-less `pane_updated`
/// can open a new episode without advancing seq, and restoring across that
/// would glue the two episodes together. Focus and a seq-less update that
/// leaves the episode alone do not drop it. A session that replaces the
/// one stored for that pane drops it too: status and seq can stay put
/// while a different occupant takes the pane.
public struct HerdLiveTable: Sendable {
    public private(set) var herd: HerdSnapshot
    public private(set) var agents: [Agent]
    /// Rows from before the layout refetch this burst is still restoring.
    private var rowsBeforeLayout: [Agent]?
    /// A move has already restored from `rowsBeforeLayout`. The next layout
    /// refetch is a new burst and remembers the rows as they are then.
    private var restoredMoveSinceRefresh = false
    /// Session identity last stored for a pane id. Empty values are not stored.
    private var sessionByPane: [String: String]
    /// Tab id last stored for a pane id. `Agent` keeps the label, and a
    /// `tab.renamed` event names the id. Empty values are not stored.
    private var tabIdByPane: [String: String]
    /// `name` from the last `agent.list` that mentioned the pane. That is
    /// `herdr agent rename` / `agent start`. Pane events do not carry it,
    /// and a terminal title on those events is not a new name.
    private var aliasByPane: [String: String]
    /// `herdr pane rename`, from the session snapshot or a pane event that
    /// named one. An event that leaves the field off does not clear it.
    /// A snapshot that lists the pane and omits the label does.
    private var paneLabelByPane: [String: String]

    public init(herd: HerdSnapshot, agents: [Agent]) {
        self.herd = herd
        self.agents = agents
        self.sessionByPane = Self.sessions(in: herd)
        self.tabIdByPane = Self.tabIds(in: herd)
        self.aliasByPane = Self.aliases(in: herd)
        self.paneLabelByPane = Self.paneLabels(in: herd)
    }

    /// Apply one `agent.list` taken so a status change reaches the table.
    ///
    /// herdr emits that change as `pane.agent_status_changed`. The
    /// subscription requires a pane id; omitting it is rejected, and
    /// `pane.updated` is not emitted for a status change. The menu bar
    /// polls every 3s. A live table that only refetches on a layout event
    /// keeps the previous status until a container is created or closed.
    /// Focusing one is not that event: it does not add or drop a row, and
    /// a refetch on the click armed the move-dwell baseline.
    ///
    /// Only ids this table already shows are updated. A list that adds a
    /// pane, or that drops one, does not change membership: a move's new
    /// id is already in `agent.list` before `pane.moved`, and adopting
    /// that list here would replace the row the layout refetch remembers.
    /// `pane.updated` and `pane.closed` still insert and remove. `nil` is
    /// a failed read. An open layout burst is left in place, including
    /// its remembered dwell. A rename that arrives while this read is in
    /// flight is applied by the caller after this returns.
    ///
    /// The returned ids are the rows whose status, seq, or session opened
    /// a new episode. The fresh verdict on those rows is the status
    /// verdict, so a crash the last process read stamped is gone until
    /// the caller reads those panes. A row that keeps the episode — same
    /// status and seq, including a list that only changes the title or
    /// leaves the session off — is not included, and neither is a pane
    /// this list does not contain. A failed read returns an empty array.
    /// Rows left off the result keep the crash they had. Reading them
    /// on this poll would scan a table whose episode did not change.
    @discardableResult
    public mutating func noteStatusRefresh(_ refreshed: HerdSnapshot?, now: Date = Date()) -> [AgentID] {
        guard let refreshed else { return [] }
        let previousSessions = sessionByPane
        let previousTabs = tabIdByPane
        let previousAliases = aliasByPane
        let previousPaneLabels = paneLabelByPane
        var listed: [String: HerdrAgentInfo] = [:]
        for info in refreshed.agents where !info.paneId.isEmpty {
            listed[info.paneId] = info
        }
        var next: [Agent] = []
        next.reserveCapacity(agents.count)
        var openedEpisodes: [AgentID] = []
        for old in agents {
            guard let info = listed[old.id.raw],
                  var updated = refreshed.displayAgent(for: info, now: now) else {
                next.append(old)
                continue
            }
            // Same episode, including a list that leaves the session off.
            // The fresh row's verdict is stamped at `now`; the one already
            // on the table is the episode the process scan and the dwell
            // are about. A new episode is named so the caller can read
            // the process list for that row before it draws.
            let sameEpisode = old.status == updated.status
                && old.stateChangeSeq == updated.stateChangeSeq
                && !SessionIdentity.replaced(
                    stored: previousSessions[old.id.raw],
                    incoming: info.sessionIdentity
                )
            if sameEpisode {
                updated.enteredAt = old.enteredAt
                updated.verdict = old.verdict
            } else {
                openedEpisodes.append(updated.id)
            }
            // A list that leaves every name source off is not a rename.
            // `displayAgent` would otherwise fall through to the kind. A
            // list that names a rename, a display agent, or a title does
            // change the row: that string is the name herdr's panel shows.
            if AgentLabel.preferred(
                title: info.title,
                displayAgent: info.displayAgent,
                name: info.name,
                terminalTitleStripped: info.terminalTitleStripped,
                paneLabel: refreshed.paneLabels[info.paneId]
            ) == nil,
               !SessionIdentity.replaced(
                   stored: previousSessions[old.id.raw],
                   incoming: info.sessionIdentity
               ) {
                updated.name = old.name
                updated.displayName = old.displayName
            }
            if Self.absent(info.foregroundCwd), Self.absent(info.cwd) {
                updated.cwd = old.cwd
            }
            updated.sessionIdentity = SessionIdentity.carried(
                stored: previousSessions[old.id.raw] ?? old.sessionIdentity,
                incoming: info.sessionIdentity
            )
            if Self.absent(refreshed.workspaceNames[info.workspaceId]) {
                updated.workspaceName = old.workspaceName
            }
            if Self.absent(refreshed.tabNames[info.tabId]) {
                updated.tabName = old.tabName
            }
            next.append(updated)
        }
        if let saved = rowsBeforeLayout {
            let kept = saved.filter { agent in
                !SessionIdentity.replaced(
                    stored: previousSessions[agent.id.raw],
                    incoming: Self.session(in: refreshed, paneId: agent.id.raw)
                )
            }
            rowsBeforeLayout = kept.isEmpty ? nil : kept
        }
        herd = refreshed
        agents = next
        adoptSessions(from: refreshed, previous: previousSessions)
        adoptTabIds(from: refreshed, previous: previousTabs)
        adoptAliases(from: refreshed, previous: previousAliases)
        adoptPaneLabels(from: refreshed, previous: previousPaneLabels)
        return openedEpisodes
    }

    /// Nil and "" are both "the list did not name this".
    private static func absent(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.isEmpty
    }

    /// Apply one `herdSnapshot` taken because a layout event arrived.
    /// `nil` is a failed read: the table and any open burst stay as they are.
    public mutating func noteLayoutRefresh(_ refreshed: HerdSnapshot?, now: Date = Date()) {
        guard let refreshed else { return }
        let previousSessions = sessionByPane
        let previousTabs = tabIdByPane
        let previousAliases = aliasByPane
        let previousPaneLabels = paneLabelByPane
        let armingBurst = rowsBeforeLayout == nil || restoredMoveSinceRefresh
        if armingBurst {
            rowsBeforeLayout = agents
            restoredMoveSinceRefresh = false
        }
        herd = refreshed
        agents = refreshed.displayAgents(
            preserving: agents,
            sessions: previousSessions,
            now: now
        )
        // A later refetch in the same burst can replace a session too.
        // That pane's pre-burst dwell must not be put back by the move.
        if let saved = rowsBeforeLayout {
            let kept = saved.filter { agent in
                !SessionIdentity.replaced(
                    stored: previousSessions[agent.id.raw],
                    incoming: Self.session(in: refreshed, paneId: agent.id.raw)
                )
            }
            rowsBeforeLayout = kept.isEmpty ? nil : kept
        }
        adoptSessions(from: refreshed, previous: previousSessions)
        adoptTabIds(from: refreshed, previous: previousTabs)
        adoptAliases(from: refreshed, previous: previousAliases)
        adoptPaneLabels(from: refreshed, previous: previousPaneLabels)
    }

    /// Stamp process-list reads onto the rows. See `ProcessGoneObservation.apply`.
    public mutating func applyProcessGone(
        _ observations: [AgentID: ProcessGoneObservation],
        now: Date = Date()
    ) {
        agents = ProcessGoneObservation.apply(observations, to: agents, now: now)
    }

    /// Apply one subscription event. `.workspacesChanged` is not applied
    /// here: the caller refetches and passes the snapshot to
    /// `noteLayoutRefresh`. Treating it as a normal event would leave the
    /// remembered rows in place either way; skipping it keeps that refetch
    /// as the only response to the event.
    public mutating func apply(_ event: HerdrEvent, now: Date = Date()) {
        if case .workspacesChanged = event {
            return
        }
        // A rename's label has to be on this snapshot before the next
        // pane_updated. Otherwise the old name, which is what this snapshot
        // still has, is written back over the row.
        switch event {
        case .workspaceRenamed(let id, let label):
            herd = herd.renamingWorkspace(id, to: label)
        case .tabRenamed(let id, let label):
            herd = herd.renamingTab(id, to: label)
        default:
            break
        }
        let replaced = sessionReplaced(by: event)
        // herdr drops the rename when the session owner changes. Clear it
        // before the row is labelled, or the new occupant keeps the old name.
        if replaced {
            clearAlias(for: event)
        }
        if case .paneMoved = event, let saved = rowsBeforeLayout, !replaced {
            agents = applyingMove(event, savedRows: saved, now: now)
            noteSession(from: event)
            noteTab(from: event)
            noteAlias(from: event)
            notePaneLabel(from: event)
            restoredMoveSinceRefresh = true
            return
        }
        let before = episodeIdentity(of: agents)
        agents = herd.applying(
            event,
            to: agents,
            tabIds: tabIdByPane,
            aliases: aliasByPane,
            paneLabels: paneLabelByPane,
            preservingExistingName: !replaced,
            now: now
        )
        if replaced, let paneId = Self.addressedPaneId(of: event) {
            openFreshEpisode(paneId: paneId, now: now)
        }
        noteSession(from: event)
        noteTab(from: event)
        // A new occupant already cleared the rename. The last list still
        // names the person who left, and noteAlias would put that back.
        if !replaced {
            noteAlias(from: event)
        }
        notePaneLabel(from: event)
        if rowsBeforeLayout != nil, replaced || episodeIdentity(of: agents) != before {
            rowsBeforeLayout = nil
            restoredMoveSinceRefresh = false
        }
    }

    /// True when this event names a session and the pane already had a
    /// different one. A move that omits `agent_session` uses the session
    /// the last snapshot stored for the destination: the layout refetch
    /// already learned it, and the wire move often does not repeat it.
    private func sessionReplaced(by event: HerdrEvent) -> Bool {
        switch event {
        case .paneUpdated(let info):
            return SessionIdentity.replaced(
                stored: sessionByPane[info.paneId],
                incoming: info.sessionIdentity
            )
        case .paneMoved(let previousPaneId, let info, _, _):
            let previousRaw = previousPaneId.isEmpty ? info.paneId : previousPaneId
            let incoming = info.sessionIdentity ?? Self.session(in: herd, paneId: info.paneId)
            return SessionIdentity.replaced(
                stored: sessionByPane[previousRaw],
                incoming: incoming
            )
        default:
            return false
        }
    }

    /// The pane a session-changing event addresses now. A move's id is the
    /// new one; the row, if the event kept it, is what gets the fresh dwell.
    private static func addressedPaneId(of event: HerdrEvent) -> String? {
        switch event {
        case .paneUpdated(let info):
            return info.paneId.isEmpty ? nil : info.paneId
        case .paneMoved(_, let info, _, _):
            return info.paneId.isEmpty ? nil : info.paneId
        default:
            return nil
        }
    }

    /// Drop the dwell and the crash mark. The status string did not have
    /// to change for the occupant to.
    private mutating func openFreshEpisode(paneId: String, now: Date) {
        guard let index = agents.firstIndex(where: { $0.id.raw == paneId }) else { return }
        agents[index].enteredAt = now
        agents[index].verdict = HerdSnapshot.displayVerdict(for: agents[index].status, now: now)
    }

    private mutating func noteSession(from event: HerdrEvent) {
        switch event {
        case .paneUpdated(let info):
            guard !info.paneId.isEmpty else { return }
            guard agents.contains(where: { $0.id.raw == info.paneId }) else {
                sessionByPane.removeValue(forKey: info.paneId)
                return
            }
            if let incoming = info.sessionIdentity {
                sessionByPane[info.paneId] = incoming
            }
        case .paneMoved(let previousPaneId, let info, _, _):
            let previousRaw = previousPaneId.isEmpty ? info.paneId : previousPaneId
            let carried = sessionByPane[previousRaw]
            if previousRaw != info.paneId {
                sessionByPane.removeValue(forKey: previousRaw)
            }
            guard agents.contains(where: { $0.id.raw == info.paneId }) else {
                sessionByPane.removeValue(forKey: info.paneId)
                return
            }
            if let incoming = info.sessionIdentity {
                sessionByPane[info.paneId] = incoming
            } else if previousRaw != info.paneId, let carried {
                sessionByPane[info.paneId] = carried
            }
        case .paneClosed(let paneId), .paneExited(let paneId):
            sessionByPane.removeValue(forKey: paneId)
        default:
            break
        }
    }

    /// The tab a pane is in, kept the same way as its session. A payload
    /// that names one replaces it. A payload that leaves `tab_id` off keeps
    /// the one already stored, and a pane that left the table drops it.
    private mutating func noteTab(from event: HerdrEvent) {
        switch event {
        case .paneUpdated(let info):
            guard !info.paneId.isEmpty else { return }
            guard agents.contains(where: { $0.id.raw == info.paneId }) else {
                tabIdByPane.removeValue(forKey: info.paneId)
                return
            }
            if !info.tabId.isEmpty {
                tabIdByPane[info.paneId] = info.tabId
            }
        case .paneMoved(let previousPaneId, let info, _, _):
            let previousRaw = previousPaneId.isEmpty ? info.paneId : previousPaneId
            let carried = tabIdByPane[previousRaw]
            if previousRaw != info.paneId {
                tabIdByPane.removeValue(forKey: previousRaw)
            }
            guard agents.contains(where: { $0.id.raw == info.paneId }) else {
                tabIdByPane.removeValue(forKey: info.paneId)
                return
            }
            if !info.tabId.isEmpty {
                tabIdByPane[info.paneId] = info.tabId
            } else if previousRaw != info.paneId, let carried {
                tabIdByPane[info.paneId] = carried
            }
        case .paneClosed(let paneId), .paneExited(let paneId):
            tabIdByPane.removeValue(forKey: paneId)
        default:
            break
        }
    }

    /// The rename moves with the row. A list is what sets or clears it;
    /// a pane event has no `name` and must not drop the one already stored.
    /// A pane that left the table drops it.
    private mutating func noteAlias(from event: HerdrEvent) {
        switch event {
        case .paneUpdated(let info):
            guard !info.paneId.isEmpty else { return }
            guard agents.contains(where: { $0.id.raw == info.paneId }) else {
                aliasByPane.removeValue(forKey: info.paneId)
                return
            }
            if let incoming = AgentLabel.nonempty(info.name) {
                aliasByPane[info.paneId] = incoming
            }
        case .paneMoved(let previousPaneId, let info, _, _):
            let previousRaw = previousPaneId.isEmpty ? info.paneId : previousPaneId
            let carried = aliasByPane[previousRaw]
            if previousRaw != info.paneId {
                aliasByPane.removeValue(forKey: previousRaw)
            }
            guard agents.contains(where: { $0.id.raw == info.paneId }) else {
                aliasByPane.removeValue(forKey: info.paneId)
                return
            }
            // The refetch already replaced `herd`. Its `name` wins over the
            // rename the previous id was still holding.
            if let listed = herd.agents.first(where: { $0.paneId == info.paneId }) {
                if let incoming = AgentLabel.nonempty(listed.name) {
                    aliasByPane[info.paneId] = incoming
                } else {
                    aliasByPane.removeValue(forKey: info.paneId)
                }
                return
            }
            if let incoming = AgentLabel.nonempty(info.name) {
                aliasByPane[info.paneId] = incoming
            } else if previousRaw != info.paneId, let carried {
                aliasByPane[info.paneId] = carried
            }
        case .paneClosed(let paneId), .paneExited(let paneId):
            aliasByPane.removeValue(forKey: paneId)
        default:
            break
        }
    }

    /// The pane label moves with the row. A payload that names one wins.
    /// A session snapshot that listed the pane is the clear: the label
    /// stored for the id the pane left does not come back. An event that
    /// leaves the field off keeps the stored label when this snapshot
    /// never saw the pane. A pane that left the table drops it. A new
    /// session does not: the label names the pane.
    private mutating func notePaneLabel(from event: HerdrEvent) {
        switch event {
        case .paneUpdated(let info):
            guard !info.paneId.isEmpty else { return }
            guard agents.contains(where: { $0.id.raw == info.paneId }) else {
                paneLabelByPane.removeValue(forKey: info.paneId)
                return
            }
            if let incoming = AgentLabel.nonempty(info.paneLabel) {
                paneLabelByPane[info.paneId] = incoming
            }
        case .paneMoved(let previousPaneId, let info, _, _):
            let previousRaw = previousPaneId.isEmpty ? info.paneId : previousPaneId
            let carried = paneLabelByPane[previousRaw]
            if previousRaw != info.paneId {
                paneLabelByPane.removeValue(forKey: previousRaw)
            }
            guard agents.contains(where: { $0.id.raw == info.paneId }) else {
                paneLabelByPane.removeValue(forKey: info.paneId)
                return
            }
            if let incoming = AgentLabel.nonempty(info.paneLabel) {
                paneLabelByPane[info.paneId] = incoming
            } else if paneLabelByPane[info.paneId] == nil && !herd.snapshotPaneIds.contains(info.paneId),
                      previousRaw != info.paneId, let carried {
                paneLabelByPane[info.paneId] = carried
            }
        case .paneClosed(let paneId), .paneExited(let paneId):
            paneLabelByPane.removeValue(forKey: paneId)
        default:
            break
        }
    }

    /// Drop the rename herdr clears when the occupant changes. The event
    /// itself has no `name`, so leaving the old one stored would put it
    /// back on the next terminal-title update.
    private mutating func clearAlias(for event: HerdrEvent) {
        switch event {
        case .paneUpdated(let info):
            if !info.paneId.isEmpty {
                aliasByPane.removeValue(forKey: info.paneId)
            }
        case .paneMoved(let previousPaneId, let info, _, _):
            let previousRaw = previousPaneId.isEmpty ? info.paneId : previousPaneId
            aliasByPane.removeValue(forKey: previousRaw)
            if !info.paneId.isEmpty {
                aliasByPane.removeValue(forKey: info.paneId)
            }
        default:
            break
        }
    }

    /// Sessions named by `herd`, plus an identity a pane that is still
    /// showing left off this list. A layout refetch is `agent.list`.
    /// Leaving `agent_session` off is not a new occupant, and forgetting
    /// it made the next session look like the first one. Panes a burst is
    /// still restoring keep the identity they had before the refetch even
    /// after that row has already moved, so the move can tell a new
    /// session from the one that left.
    private mutating func adoptSessions(from herd: HerdSnapshot, previous: [String: String]) {
        var next = Self.sessions(in: herd)
        for agent in agents where next[agent.id.raw] == nil {
            if let session = previous[agent.id.raw] {
                next[agent.id.raw] = session
            }
        }
        if let saved = rowsBeforeLayout {
            for agent in saved where next[agent.id.raw] == nil {
                if let session = previous[agent.id.raw] {
                    next[agent.id.raw] = session
                }
            }
        }
        sessionByPane = next
    }

    /// Tab ids named by `herd`, plus one a pane that is still showing left
    /// off this list. Forgetting it made the next `tab.renamed` miss the row.
    private mutating func adoptTabIds(from herd: HerdSnapshot, previous: [String: String]) {
        var next = Self.tabIds(in: herd)
        for agent in agents where next[agent.id.raw] == nil {
            if let tab = previous[agent.id.raw] {
                next[agent.id.raw] = tab
            }
        }
        tabIdByPane = next
    }

    /// Renames named by `herd`. A pane the list contains and does not name
    /// has no rename: `agent rename --clear` omits the field. A pane the
    /// list does not contain keeps the one it had, including an id a burst
    /// is still restoring, so the following move can carry it.
    private mutating func adoptAliases(from herd: HerdSnapshot, previous: [String: String]) {
        var listed: Set<String> = []
        var next: [String: String] = [:]
        for info in herd.agents {
            guard !info.paneId.isEmpty else { continue }
            listed.insert(info.paneId)
            if let name = AgentLabel.nonempty(info.name) {
                next[info.paneId] = name
            }
        }
        for agent in agents where !listed.contains(agent.id.raw) {
            if let alias = previous[agent.id.raw] {
                next[agent.id.raw] = alias
            }
        }
        if let saved = rowsBeforeLayout {
            for agent in saved where next[agent.id.raw] == nil && !listed.contains(agent.id.raw) {
                if let alias = previous[agent.id.raw] {
                    next[agent.id.raw] = alias
                }
            }
        }
        aliasByPane = next
    }

    /// Pane labels named by `herd`. A snapshot that lists the pane and
    /// does not name one has cleared it. A pane the snapshot does not
    /// list keeps the label it had, including an id a burst is still
    /// restoring. A snapshot built without pane ids is not a clear.
    private mutating func adoptPaneLabels(from herd: HerdSnapshot, previous: [String: String]) {
        if herd.snapshotPaneIds.isEmpty {
            paneLabelByPane = previous
            return
        }
        var next: [String: String] = [:]
        for paneId in herd.snapshotPaneIds {
            if let label = AgentLabel.nonempty(herd.paneLabels[paneId]) {
                next[paneId] = label
            }
        }
        for agent in agents where !herd.snapshotPaneIds.contains(agent.id.raw) {
            if let label = previous[agent.id.raw] {
                next[agent.id.raw] = label
            }
        }
        if let saved = rowsBeforeLayout {
            for agent in saved where next[agent.id.raw] == nil && !herd.snapshotPaneIds.contains(agent.id.raw) {
                if let label = previous[agent.id.raw] {
                    next[agent.id.raw] = label
                }
            }
        }
        paneLabelByPane = next
    }

    private static func aliases(in herd: HerdSnapshot) -> [String: String] {
        var aliases: [String: String] = [:]
        for info in herd.agents {
            guard !info.paneId.isEmpty, let name = AgentLabel.nonempty(info.name) else { continue }
            aliases[info.paneId] = name
        }
        return aliases
    }

    private static func paneLabels(in herd: HerdSnapshot) -> [String: String] {
        var labels: [String: String] = [:]
        for (paneId, label) in herd.paneLabels {
            guard !paneId.isEmpty, let label = AgentLabel.nonempty(label) else { continue }
            labels[paneId] = label
        }
        return labels
    }

    private static func sessions(in herd: HerdSnapshot) -> [String: String] {
        var sessions: [String: String] = [:]
        for info in herd.agents {
            guard !info.paneId.isEmpty, let session = info.sessionIdentity else { continue }
            sessions[info.paneId] = session
        }
        return sessions
    }

    private static func tabIds(in herd: HerdSnapshot) -> [String: String] {
        var tabs: [String: String] = [:]
        for info in herd.agents {
            guard !info.paneId.isEmpty, !info.tabId.isEmpty else { continue }
            tabs[info.paneId] = info.tabId
        }
        return tabs
    }

    private static func session(in herd: HerdSnapshot, paneId: String) -> String? {
        herd.agents.first { $0.paneId == paneId }?.sessionIdentity
    }

    /// Re-key `current`, then keep the pre-refetch dwell when this move did
    /// not change the episode the refetch already shows.
    private func applyingMove(
        _ event: HerdrEvent,
        savedRows: [Agent],
        now: Date
    ) -> [Agent] {
        guard case .paneMoved(let previousPaneId, let info, _, _) = event else {
            return herd.applying(
                event,
                to: agents,
                tabIds: tabIdByPane,
                aliases: aliasByPane,
                paneLabels: paneLabelByPane,
                now: now
            )
        }
        let previousRaw = previousPaneId.isEmpty ? info.paneId : previousPaneId
        let saved = savedRows.first { $0.id.raw == previousRaw }
        var updated = herd.applying(
            event,
            to: agents,
            tabIds: tabIdByPane,
            aliases: aliasByPane,
            paneLabels: paneLabelByPane,
            now: now
        )
        guard let saved,
              let index = updated.firstIndex(where: { $0.id.raw == info.paneId }),
              updated[index].status == saved.status,
              updated[index].stateChangeSeq == saved.stateChangeSeq else {
            return updated
        }
        updated[index].enteredAt = saved.enteredAt
        // The new id's row was built from herdr's status. The crash was
        // stamped on the pre-refetch id, and a same-episode move keeps it.
        // A process read after this move clears it if the agent is back.
        if saved.verdict.isProcessGone {
            updated[index].verdict = saved.verdict
        }
        return updated
    }

    /// Id, status, and seq. `enteredAt` is left out on purpose: the refetch
    /// resets it when the id changes, and that reset is what the move undoes.
    private func episodeIdentity(of agents: [Agent]) -> [String: (AgentStatus, UInt64)] {
        var identity: [String: (AgentStatus, UInt64)] = [:]
        for agent in agents {
            identity[agent.id.raw] = (agent.status, agent.stateChangeSeq)
        }
        return identity
    }
}

extension HerdLiveTable {
    /// What herdmgr does after one subscription event.
    ///
    /// A focus, a newly created shell, and an event this table does not
    /// model leave the rows alone. Reading every process and clearing the
    /// screen for those stalled the live table on a click. A rename only
    /// changes a label. A pane update still reads processes when the
    /// visible row did not change: the process can have exited while
    /// herdr's status string stayed `working`, and the 15s tick is the
    /// only other time that crash is read. Reconnect is the same read.
    /// Disconnect is not: the socket is down, and a failed read must not
    /// be what the next paint waits on.
    public enum FollowUp: Equatable, Sendable {
        case skip
        case paint
        case scanAndPaint

        public static func after(_ event: HerdrEvent, rowsChanged: Bool) -> FollowUp {
            switch event {
            case .paneFocused, .paneCreated, .ignored, .disconnected,
                 .workspaceRenamed, .tabRenamed:
                // A row that did change is still shown. These events are
                // not a reason to read every process list.
                return rowsChanged ? .paint : .skip
            case .connected, .workspacesChanged, .paneUpdated:
                return .scanAndPaint
            case .agentStatusChanged, .paneClosed, .paneExited, .paneMoved:
                return rowsChanged ? .scanAndPaint : .skip
            }
        }
    }
}
