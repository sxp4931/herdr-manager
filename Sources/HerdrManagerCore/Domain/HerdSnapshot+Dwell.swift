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
            return merged
        }
    }
}
