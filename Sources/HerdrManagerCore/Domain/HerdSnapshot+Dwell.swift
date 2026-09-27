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
            guard let old = byId[agent.id],
                  old.status == agent.status,
                  old.stateChangeSeq == agent.stateChangeSeq,
                  !SessionIdentity.replaced(
                    stored: previousSessions[agent.id.raw],
                    incoming: incomingSessions[agent.id.raw]
                  ) else {
                return agent
            }
            var merged = agent
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

    public init(herd: HerdSnapshot, agents: [Agent]) {
        self.herd = herd
        self.agents = agents
        self.sessionByPane = Self.sessions(in: herd)
    }

    /// Apply one `herdSnapshot` taken because a layout event arrived.
    /// `nil` is a failed read: the table and any open burst stay as they are.
    public mutating func noteLayoutRefresh(_ refreshed: HerdSnapshot?, now: Date = Date()) {
        guard let refreshed else { return }
        let previousSessions = sessionByPane
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
        let replaced = sessionReplaced(by: event)
        if case .paneMoved = event, let saved = rowsBeforeLayout, !replaced {
            agents = applyingMove(event, savedRows: saved, now: now)
            noteSession(from: event)
            restoredMoveSinceRefresh = true
            return
        }
        let before = episodeIdentity(of: agents)
        agents = herd.applying(event, to: agents, now: now)
        if replaced, let paneId = Self.addressedPaneId(of: event) {
            openFreshEpisode(paneId: paneId, now: now)
        }
        noteSession(from: event)
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

    private static func sessions(in herd: HerdSnapshot) -> [String: String] {
        var sessions: [String: String] = [:]
        for info in herd.agents {
            guard !info.paneId.isEmpty, let session = info.sessionIdentity else { continue }
            sessions[info.paneId] = session
        }
        return sessions
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
            return herd.applying(event, to: agents, now: now)
        }
        let previousRaw = previousPaneId.isEmpty ? info.paneId : previousPaneId
        let saved = savedRows.first { $0.id.raw == previousRaw }
        var updated = herd.applying(event, to: agents, now: now)
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
