import SwiftUI
import HerdrManagerCore

/// The menu-bar item. Composited into a single `NSImage` by `MenuBarIcon` —
/// see that file for why (a SwiftUI view stack of gradients/shapes next to
/// `MenuBarExtra`'s label rendered invisibly in practice; one predictable
/// image does not).
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Image(nsImage: MenuBarIcon.render(state: herdState, attentionCount: attentionCount))
            .onAppear {
                appModel.start()
            }
    }

    private var attentionCount: Int {
        let store = appModel.store
        return store.blockedCount + store.silentCount + store.doneCount
    }

    /// Plain computed property (not part of the `body` ViewBuilder) — a
    /// result-builder context rewrites bare `if/else` statements even when
    /// they aren't producing view content, so this decision has to live
    /// outside `body`.
    private var herdState: HerdState {
        let store = appModel.store
        let connected = appModel.connectionState == .connected
        guard connected else { return .disconnected }
        guard attentionCount > 0 else { return .calm }
        return .attention(Brand.worstColor(
            blocked: store.blockedCount, silent: store.silentCount, done: store.doneCount, connected: true
        ))
    }
}
