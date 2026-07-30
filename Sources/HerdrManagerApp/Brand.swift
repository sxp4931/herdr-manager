import SwiftUI
import HerdrManagerCore

/// Brand identity pulled from the app icon: a deep teal field, a warm amber
/// "H" herd-mark, and a herd of small glowing status lights. The whole UI is
/// built around this so the menu bar, panel and rows feel like one object.
enum Brand {
    // Field
    static let bgDeep = Color(red: 0.045, green: 0.155, blue: 0.145)
    static let bgMid = Color(red: 0.075, green: 0.235, blue: 0.215)

    // The amber H
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
    static func worstColor(blocked: Int, silent: Int, done: Int, connected: Bool) -> Color {
        if !connected { return Brand.unknown }
        if blocked > 0 { return Brand.blocked }
        if silent > 0 { return Brand.silent }
        if done > 0 { return Brand.done }
        return Brand.working
    }
}

/// The drawn amber "H" herd-mark, echoing the app icon at any size.
/// With `herd: true` it also scatters a few glowing status lights around the
/// mark, exactly like the icon — used for the large empty-state hero.
struct HerdMark: View {
    var size: CGFloat
    var glow: Bool = true
    var herd: Bool = false

    var body: some View {
        let w = size * 0.86
        let stroke = max(1.4, size * 0.17)
        let gap = size * 0.30
        ZStack {
            HStack(alignment: .center, spacing: gap) {
                Capsule().fill(Brand.amberGradient).frame(width: stroke, height: size)
                Capsule().fill(Brand.amberGradient).frame(width: stroke, height: size)
            }
            Capsule()
                .fill(Brand.amberGradient)
                .frame(width: gap + stroke, height: stroke)

            if herd {
                herdDot(Brand.working, x: 0.00, y: 0.84, w: w, h: size)
                herdDot(Brand.done, x: 0.33, y: 0.66, w: w, h: size)
                herdDot(Brand.blocked, x: 0.72, y: 0.50, w: w, h: size)
                herdDot(Brand.amber, x: 0.45, y: 0.95, w: w, h: size)
                herdDot(Brand.silent, x: 1.00, y: 0.28, w: w, h: size)
            }
        }
        .frame(width: w, height: size)
        .shadow(color: Brand.amber.opacity(glow ? 0.5 : 0), radius: size * 0.16)
    }

    private func herdDot(_ color: Color, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        let d = max(2.5, h * 0.12)
        return Circle()
            .fill(color)
            .frame(width: d, height: d)
            .shadow(color: color.opacity(0.9), radius: h * 0.10)
            .position(x: x * w, y: y * h)
    }
}
