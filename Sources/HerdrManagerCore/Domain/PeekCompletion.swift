import Foundation

// MARK: - PeekCompletion

/// What the menu bar does with a peek that just finished.
///
/// The read is addressed to the pane id the click named. A cross-workspace
/// move, or a poll that already continued that session, publishes a new id
/// and points the selection at it while the read is still in flight. The
/// bytes can be the shell that now occupies the old id, so they are not
/// shown on the row. Leaving the spinner up is worse than dropping them:
/// the click that would peek again is ignored for as long as that spinner
/// is the expansion, and the new row is the one it is drawn on.
public enum PeekCompletion: Sendable {
    public enum Decision: Equatable, Sendable {
        /// The selection is still the pane that was read.
        case show
        /// This peek is still the spinner, and the selection is a different
        /// pane. Read that pane. Do not show the bytes just returned.
        case reread
        /// Nothing is selected. A spinner left in place would attach to
        /// whichever row is selected next.
        case clear
        /// A newer peek owns the expansion, or this one was already closed.
        case ignore
    }

    /// `isLatest` is false once a newer peek has been started. `stillLoading`
    /// is false once the panel has closed or replaced the spinner. Both have
    /// to hold before a result is allowed to change what is on screen.
    public static func decide(
        isLatest: Bool,
        stillLoading: Bool,
        selectedId: AgentID?,
        readPaneId: AgentID
    ) -> Decision {
        guard isLatest, stillLoading else { return .ignore }
        guard let selectedId else { return .clear }
        if selectedId == readPaneId { return .show }
        return .reread
    }
}
