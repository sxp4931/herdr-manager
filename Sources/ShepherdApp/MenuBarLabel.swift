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
        // surface with no words at all — VoiceOver read an unlabelled image.
        // It now spells out the same breakdown the panel would show, so "does
        // anything need me?" is answerable without opening anything.
        //
        // `.help` is best-effort: a status item takes its tooltip from
        // `NSStatusItem.button.toolTip`, and it is not guaranteed that a view
        // hosted in a `MenuBarExtra` label reaches it. Harmless where it
        // doesn't land, and the accessibility label carries the text either
        // way — so nothing here depends on the tooltip appearing.
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
        if signal.gone > 0 { parts.append("\(signal.gone) gone") }
        if signal.silent > 0 { parts.append("\(signal.silent) silent") }
        if signal.done > 0 { parts.append("\(signal.done) done") }
        guard parts.isEmpty else { return parts.joined(separator: ", ") }
        // A bare "all quiet" would carry the same ambiguity the panel's own
        // empty state was just rid of: a herd of twenty agents working away
        // and a herd of twenty doing nothing would read identically. Naming
        // how many are working makes it a claim rather than a mood.
        guard signal.working > 0 else { return "all quiet" }
        return signal.working == 1
            ? "1 working, nothing needs you"
            : "\(signal.working) working, nothing needs you"
    }

    /// The badge's attention counts, gathered in one pass over the herd.
    /// The previous version read the store's three O(n) count properties twice
    /// per body evaluation (once for the count, once inside `herdState`) — six
    /// scans per herdr event on the always-visible menu-bar item. This derives
    /// both the count and the worst-colour decision from a single loop.
    ///
    /// Panes whose process is gone are counted. They were not, which left the
    /// one surface the product asks you to trust at a glance staying calm over
    /// a herd that had entirely died — a state the panel's own Needs-you tab
    /// ranks at the top. The counts are also mutually exclusive now, so the
    /// digits beside the mark are a count of agents rather than of conditions.
    private var signal: AttentionSignal {
        var blocked = 0
        var gone = 0
        var silent = 0
        var done = 0
        var working = 0
        for agent in appModel.store.agents.values {
            if agent.verdict.isProcessGone {
                gone += 1
            } else if agent.status == .blocked {
                blocked += 1
            } else if agent.verdict.isSilent {
                silent += 1
            } else if agent.status == .done {
                done += 1
            } else if agent.status == .working {
                working += 1
            }
        }
        return AttentionSignal(
            blocked: blocked, gone: gone, silent: silent, done: done, working: working
        )
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
                blocked: signal.urgent, silent: signal.silent, done: signal.done, connected: true
            ),
            shape: Brand.worstShape(blocked: signal.urgent, silent: signal.silent)
        )
    }
}

/// The attention counts the badge renders, computed in one pass so the label
/// does not scan the herd once per count. Mutually exclusive, worst-first, so
/// `total` is a number of agents.
private struct AttentionSignal {
    var blocked: Int = 0
    var gone: Int = 0
    var silent: Int = 0
    var done: Int = 0
    /// Healthy working panes. Counted for the spoken summary only, and so
    /// deliberately outside `total`: nothing about a working agent belongs in
    /// the badge's attention count or its calm/attention decision.
    var working: Int = 0

    /// Agents wanting attention. Drives both the digits beside the mark and
    /// the choice between the calm and attention badges, so it counts only
    /// the states that actually ask for something.
    var total: Int { blocked + gone + silent + done }

    /// Blocked and process-gone are one urgency to every other surface —
    /// `Brand.color(for:)` gives them the same colour and the panel's
    /// Needs-you ranking gives them the same priority — so the badge ranks
    /// them together too. They stay separate fields only because the spoken
    /// summary says which of the two it found.
    var urgent: Int { blocked + gone }
}
