import CoreGraphics
import AppKit

/// Shared geometry tokens for the surfaces presented in the menu-bar window.
///
/// The triage panel and the usage dashboard swap inside the same
/// `MenuBarExtra` window, so they must agree on the panel width or switching
/// surfaces visibly jumps the window. The peek-expansion numbers are the
/// single source of truth for both the view (`AgentRow`) and the list-height
/// budget (`PanelView`), so the estimate cannot silently drift from the
/// rendering again.
enum PanelLayout {
    /// Fixed width of the menu-bar window (triage panel and usage dashboard).
    static let panelWidth: CGFloat = 500

    // MARK: Peek expansion geometry
    //
    // The selected row's peek renders as: top inset + copy header + gap +
    // terminal body. `peekHeight` is what `PanelView` adds to the row-height
    // estimate while a peek is open; it is the sum of the parts the expansion
    // actually renders. The copy header was previously unbudgeted — the old
    // budget assumed only the two 4 pt gaps — leaving the estimate ~16 pt
    // short of the rendered 244 pt.

    /// Top inset of the peek expansion within the row.
    static let peekTopInset: CGFloat = 4
    /// Gap between the copy header and the terminal body.
    static let peekGap: CGFloat = 4
    /// Rendered height of the copy header: a small borderless button holding
    /// an 11 pt `Label` (~16 pt, measured via `NSHostingView.fittingSize`).
    /// If the copy header changes, update this — the budget depends on it.
    static let peekCopyHeight: CGFloat = 16
    /// Cap on the terminal-body scroll view (`AgentRow`).
    static let peekBodyHeight: CGFloat = 220
    /// Full expanded height of the peek: inset + copy header + gap + body.
    static let peekHeight: CGFloat =
        peekTopInset + peekCopyHeight + peekGap + peekBodyHeight

    /// The screen the menu-bar window will open on: the screen under the mouse
    /// (where the menu-bar click happened), falling back to the main screen.
    /// `NSScreen.main` alone is the screen holding the *key window*, which is
    /// not guaranteed to be the clicked screen on a multi-display setup.
    static var panelScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}