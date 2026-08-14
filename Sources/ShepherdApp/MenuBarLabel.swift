import SwiftUI
import HerdrManagerCore

/// The menu-bar item. Composited into a single `NSImage` by `MenuBarIcon` —
/// see that file for why (a SwiftUI view stack of gradients/shapes next to
/// `MenuBarExtra`'s label rendered invisibly in practice; one predictable
/// image does not).
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let signal = self.signal
        let summary = Self.summary(signal, connected: appModel.connectionState == .connected)
        return Image(nsImage: MenuBarIcon.rendered(
            state: herdState(signal: signal), attentionCount: signal.total
        ))
        // The badge is a picture of a number, and until now it was the one
        // surface with no words at all: VoiceOver read an unlabelled image,
        // and hovering told you nothing the icon hadn't already said. Both
        // now spell out the same breakdown the panel would show, so "does
        // anything need me?" is answerable without opening anything.
        .accessibilityLabel("Shepherd — \(summary)")
        .help("Shepherd — \(summary)")
        .onAppear {
            appModel.start()
        }
    }

    /// Plain-language reading of the badge: the same counts, in the same
    /// worst-first order the colour and shape rank them by. Only non-zero
    /// counts appear — a herd with two blocked agents and nothing else should
    /// not have to read "0 silent, 0 done" to learn that.
    private static func summary(_ signal: AttentionSignal, connected: Bool) -> String {
        guard connected else { return "herdr not connected" }
        var parts: [String] = []
        if signal.blocked > 0 { parts.append("\(signal.blocked) blocked") }
        if signal.silent > 0 { parts.append("\(signal.silent) silent") }
        if signal.done > 0 { parts.append("\(signal.done) done") }
        guard !parts.isEmpty else { return "all quiet" }
        return parts.joined(separator: ", ")
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
        return .attention(
            color: Brand.worstColor(
                blocked: signal.blocked, silent: signal.silent, done: signal.done, connected: true
            ),
            shape: Brand.worstShape(
                blocked: signal.blocked, silent: signal.silent, done: signal.done
            )
        )
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
