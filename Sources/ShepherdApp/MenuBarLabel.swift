import SwiftUI
import HerdrManagerCore

/// The menu-bar item. Composited into a single `NSImage` by `MenuBarIcon` —
/// see that file for why (a SwiftUI view stack of gradients/shapes next to
/// `MenuBarExtra`'s label rendered invisibly in practice; one predictable
/// image does not).
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Image(nsImage: MenuBarIcon.rendered(state: herdState(signal: signal), attentionCount: signal.total))
            .onAppear {
                appModel.start()
            }
    }

    /// The badge's three attention counts, gathered in one pass over the herd.
    /// The previous version read the store's three O(n) count properties twice
    /// per body evaluation (once for the count, once inside `herdState`) — six
    /// scans per herdr event on the always-visible menu-bar item. This derives
    /// both the count and the worst-colour decision from a single loop.
    private var signal: AttentionSignal {
        var blocked = 0
        var silent = 0
        var done = 0
        for agent in appModel.store.agents.values {
            switch agent.status {
            case .blocked: blocked += 1
            case .done: done += 1
            default: break
            }
            if agent.verdict.isSilent { silent += 1 }
        }
        return AttentionSignal(blocked: blocked, silent: silent, done: done)
    }

    /// Plain computed property (not part of the `body` ViewBuilder) — a
    /// result-builder context rewrites bare `if/else` statements even when
    /// they aren't producing view content, so this decision has to live
    /// outside `body`.
    private func herdState(signal: AttentionSignal) -> HerdState {
        let connected = appModel.connectionState == .connected
        guard connected else { return .disconnected }
        guard signal.total > 0 else { return .calm }
        return .attention(Brand.worstColor(
            blocked: signal.blocked, silent: signal.silent, done: signal.done, connected: true
        ))
    }
}

/// The three attention counts the badge renders, computed in one pass so the
/// label does not scan the herd once per count.
private struct AttentionSignal {
    var blocked: Int = 0
    var silent: Int = 0
    var done: Int = 0

    var total: Int { blocked + silent + done }
}
