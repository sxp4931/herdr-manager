import Foundation

extension HerdSnapshot {
    /// `displayAgents`, but carrying `enteredAt` over from `previous` for any
    /// pane whose episode (status *and* `state_change_seq`) has not moved.
    ///
    /// A snapshot refetch driven by a workspace/tab/layout event says nothing
    /// about the agents themselves; stamping a fresh `enteredAt` on all of
    /// them resets every dwell timer, which is the one number the caller is
    /// watching to see how long something has been stuck.
    public func displayAgents(preserving previous: [Agent], now: Date = Date()) -> [Agent] {
        let byId = Dictionary(
            previous.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }
        )
        return displayAgents(now: now).map { agent in
            guard let old = byId[agent.id],
                  old.status == agent.status,
                  old.stateChangeSeq == agent.stateChangeSeq else {
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
/// leaves the episode alone do not drop it.
public struct HerdLiveTable: Sendable {
    public private(set) var herd: HerdSnapshot
    public private(set) var agents: [Agent]
    /// Rows from before the layout refetch this burst is still restoring.
    private var rowsBeforeLayout: [Agent]?
    /// A move has already restored from `rowsBeforeLayout`. The next layout
    /// refetch is a new burst and remembers the rows as they are then.
    private var restoredMoveSinceRefresh = false

    public init(herd: HerdSnapshot, agents: [Agent]) {
        self.herd = herd
        self.agents = agents
    }

    /// Apply one `herdSnapshot` taken because a layout event arrived.
    /// `nil` is a failed read: the table and any open burst stay as they are.
    public mutating func noteLayoutRefresh(_ refreshed: HerdSnapshot?, now: Date = Date()) {
        guard let refreshed else { return }
        if rowsBeforeLayout == nil || restoredMoveSinceRefresh {
            rowsBeforeLayout = agents
            restoredMoveSinceRefresh = false
        }
        herd = refreshed
        agents = refreshed.displayAgents(preserving: agents, now: now)
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
        if case .paneMoved = event, let saved = rowsBeforeLayout {
            agents = applyingMove(event, savedRows: saved, now: now)
            restoredMoveSinceRefresh = true
            return
        }
        let before = episodeIdentity(of: agents)
        agents = herd.applying(event, to: agents, now: now)
        if rowsBeforeLayout != nil, episodeIdentity(of: agents) != before {
            rowsBeforeLayout = nil
            restoredMoveSinceRefresh = false
        }
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
