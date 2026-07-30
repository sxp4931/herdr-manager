import SwiftUI
import AppKit
import HerdrManagerCore

/// Brand identity: a deep teal field, a warm amber accent, and a herd of
/// small glowing status lights. The whole UI is built around this so the
/// menu bar, panel and rows feel like one object.
enum Brand {
    // Field
    static let bgDeep = Color(red: 0.045, green: 0.155, blue: 0.145)
    static let bgMid = Color(red: 0.075, green: 0.235, blue: 0.215)

    // Amber accent
    static let amber = Color(red: 0.945, green: 0.745, blue: 0.305)
    static let amberDeep = Color(red: 0.875, green: 0.595, blue: 0.175)

    // The herd lights (status vocabulary)
    static let blocked = Color(red: 1.00, green: 0.38, blue: 0.38)
    static let silent = Color(red: 1.00, green: 0.64, blue: 0.26)
    static let done = Color(red: 0.36, green: 0.68, blue: 1.00)
    static let working = Color(red: 0.32, green: 0.82, blue: 0.47)
    static let idle = Color(red: 0.46, green: 0.64, blue: 0.59)
    static let unknown = Color(red: 0.62, green: 0.66, blue: 0.66)

    static let amberGradient = LinearGradient(
        colors: [amber, amberDeep], startPoint: .top, endPoint: .bottom
    )

    /// The single colour that represents an agent right now (worst-state wins).
    static func color(for agent: Agent) -> Color {
        if agent.status == .blocked { return blocked }
        if agent.verdict.isProcessGone { return blocked }
        if agent.verdict.isSilent { return silent }
        if agent.status == .done { return done }
        if agent.status == .working { return working }
        if agent.status == .idle { return idle }
        return unknown
    }

    /// Worst-state colour across the whole herd, for the menu-bar light.
    /// Worst-state wins: blocked > silent > done.
    static func worstColor(blocked: Int, silent: Int, done: Int, connected: Bool) -> Color {
        if !connected { return Brand.unknown }
        if blocked > 0 { return Brand.blocked }
        if silent > 0 { return Brand.silent }
        if done > 0 { return Brand.done }
        return Brand.working
    }

    // MARK: - Mark symbol resolution

    /// SF Symbol for the flock mark, in preference order. `point.3.connected
    /// .trianglepath.dotted` (a small connected flock) is the intended mark;
    /// if it isn't available on the running OS, fall back to a symbol that
    /// still reads as "a cluster of things being watched."
    private static let markSymbolCandidates = [
        "point.3.connected.trianglepath.dotted",
        "circle.hexagongrid",
        "circle.grid.3x3",
    ]

    /// Resolve the first candidate that actually exists at runtime. Checked
    /// once and cached — `NSImage(systemSymbolName:)` is a real lookup, not
    /// something to repeat on every draw.
    static let markSymbolName: String = {
        for name in markSymbolCandidates {
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
                return name
            }
        }
        return "circle.grid.3x3"
    }()
}

/// The flock mark, drawn from an SF Symbol so it stays crisp at any size and
/// matches system rendering — no custom glyph drawing. Used in the panel
/// header and empty states. `MenuBarIcon` draws the NSImage equivalent of
/// this directly for the menu-bar item itself (SwiftUI views don't render
/// reliably inside `MenuBarExtra`'s label).
struct FlockMark: View {
    var size: CGFloat
    var glow: Bool = true
    /// Disconnected state: quiet, not alarming.
    var dimmed: Bool = false

    var body: some View {
        Image(systemName: Brand.markSymbolName)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Brand.amberGradient)
            .opacity(dimmed ? 0.4 : 1.0)
            .shadow(color: Brand.amber.opacity(glow && !dimmed ? 0.5 : 0), radius: size * 0.16)
    }
}
