import SwiftUI
import AppKit
import HerdrManagerCore

/// Brand identity: a clean, native macOS utility with a single warm amber
/// accent and a herd of small status lights. The palette is deliberately
/// two-layered:
///
/// - **Adaptive body layer** (`blocked`, `silent`, `done`, `working`, `idle`,
///   `unknown`, `amber`): dynamic colors that resolve against the panel's
///   appearance. The light variants are darkened so every text use passes WCAG
///   AA (≥4.5:1) on a light material; dark variants are bright for a dark bar.
/// - **Fixed menu-bar layer** (`worstColor`): the menu-bar attention badge is
///   baked into an `NSImage` at paint time, so adaptive colors would resolve
///   against the wrong appearance (panel vs bar). It uses fixed system colors
///   instead.
enum Brand {
    // MARK: Adaptive body palette

    /// An adaptive color that resolves to a light/dark variant based on the
    /// current appearance. Both variants are chosen to keep text ≥4.5:1.
    private static func adaptive(
        light rgbL: (Double, Double, Double),
        dark rgbD: (Double, Double, Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? rgbD : rgbL
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    // Status vocabulary (the herd lights). Light variants are darkened for AA
    // text contrast on light materials; dark variants are bright.
    static let blocked = adaptive(
        light: (0.702, 0.151, 0.118), // #B3261E
        dark: (1.00, 0.42, 0.42)      // #FF6B6B
    )
    static let silent = adaptive(
        light: (0.541, 0.353, 0.00),  // #8A5A00 (dark amber for text)
        dark: (1.00, 0.788, 0.302)    // #FFC94D
    )
    static let done = adaptive(
        light: (0.118, 0.294, 0.824), // #1E4BD2
        dark: (0.424, 0.651, 1.00)    // #6CA6FF
    )
    static let working = adaptive(
        light: (0.118, 0.443, 0.220), // #1E7138
        dark: (0.329, 0.851, 0.557)   // #54D98E
    )
    static let idle = adaptive(
        light: (0.357, 0.420, 0.392), // #5B6B64
        dark: (0.561, 0.659, 0.627)   // #8FA8A0
    )
    static let unknown = adaptive(
        light: (0.373, 0.400, 0.420), // #5F666B
        dark: (0.573, 0.604, 0.624)   // #929A9F
    )

    /// Stronger variants of the status colors for TEXT that sits ON a tinted
    /// pill. The tinted fill (accent at 14% over material) pulls the background
    /// toward the text colour, so pill text needs more headroom than body text
    /// to hold ≥4.5:1: light variants are darker, dark variants are brighter.
    static let pillBlocked = adaptive(
        light: (0.60, 0.10, 0.07),  // #991A12
        dark: (1.00, 0.55, 0.55)    // #FF8C8C
    )
    static let pillSilent = adaptive(
        light: (0.42, 0.27, 0.00),  // #6B4500
        dark: (1.00, 0.84, 0.45)    // #FFD873
    )
    static let pillDone = adaptive(
        light: (0.09, 0.22, 0.62),  // #17389E
        dark: (0.54, 0.72, 1.00)    // #8AB8FF
    )
    static let pillWorking = adaptive(
        light: (0.08, 0.32, 0.15),  // #145126
        dark: (0.44, 0.90, 0.63)    // #70E6A1
    )
    static let pillIdle = adaptive(
        light: (0.24, 0.29, 0.27),  // #3E4A45
        dark: (0.66, 0.76, 0.72)    // #A8C2BA
    )
    static let pillUnknown = adaptive(
        light: (0.26, 0.28, 0.30),  // #43474C
        dark: (0.66, 0.69, 0.72)    // #A8B0B8
    )

    /// The pill text colour for an agent: the status-strong variant matching
    /// `color(for:)`, so the pill label holds ≥4.5:1 on its tinted fill.
    static func pillText(for agent: Agent) -> Color {
        if agent.status == .blocked || agent.verdict.isProcessGone { return pillBlocked }
        if agent.verdict.isSilent { return pillSilent }
        if agent.status == .done { return pillDone }
        if agent.status == .working { return pillWorking }
        if agent.status == .idle { return pillIdle }
        return pillUnknown
    }

    /// Search placeholder text: an AA-safe neutral gray held ≥4.5:1 in both
    /// appearances (system placeholder colour drops to ~4.3:1 in dark mode,
    /// and a mid-gray is too close to the light field fill). Shares the
    /// secondary-text token so the whole panel speaks one grey vocabulary.
    static let searchPlaceholder = secondaryText

    // The single warm amber accent. `amber` is the body-text-safe variant
    // (darkened in light mode so cost lines pass AA); `amberDeep` is a quieter
    // deeper amber for accents that don't carry text.
    static let amber = adaptive(
        light: (0.541, 0.353, 0.00),  // #8A5A00
        dark: (1.00, 0.788, 0.302)    // #FFC94D
    )
    static let amberDeep = adaptive(
        light: (0.420, 0.271, 0.00),  // #6B4500
        dark: (0.961, 0.698, 0.290)   // #F5B24A
    )

    /// Warning orange — a distinct hue from the silent-state amber and the
    /// blocked red, reserved for operational warnings (health banner, pending
    /// actions, unpriced usage). System `.orange` drops to ~2.2:1 in light
    /// mode; this darkened variant holds ≥4.5:1 on a light material.
    static let warn = adaptive(
        light: (0.761, 0.255, 0.047),  // #C2410C
        dark: (1.00, 0.655, 0.149)     // #FFA726
    )

    /// Fill for the affirmative Approve button. System `.green` leaves white
    /// label text at ~2.2:1; this darkened green keeps white ≥4.5:1 in both
    /// appearances and ties approval to the working/active state family.
    static let approveFill = adaptive(
        light: (0.118, 0.443, 0.220), // #1E7138
        dark: (0.08, 0.32, 0.15)      // #145126
    )

    /// AA-safe secondary text grey. System `.secondary`/`.tertiary` drop to
    /// ~3.5:1 / ~2.2:1 in light mode on small text; this holds ≥4.5:1 in both
    /// appearances while staying visually demoted.
    static let secondaryText = adaptive(
        light: (0.353, 0.373, 0.392), // #5A5F64
        dark: (0.700, 0.720, 0.740)   // #B3B8BD
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

    /// Worst-state colour across the whole herd, for the menu-bar attention
    /// badge. This is the FIXED menu-bar layer: `MenuBarIcon` bakes the colour
    /// into an `NSImage` at paint time, so it must not be adaptive (adaptive
    /// colors would resolve against the wrong appearance, panel vs bar). The
    /// returned `Color`s are fixed `NSColor.system*`-backed and stay visibly
    /// red/amber/blue on every bar appearance.
    static func worstColor(blocked: Int, silent: Int, done: Int, connected: Bool) -> Color {
        if !connected { return Color(nsColor: .systemGray) }
        if blocked > 0 { return Color(nsColor: .systemRed) }
        if silent > 0 { return Color(nsColor: .systemYellow) }
        if done > 0 { return Color(nsColor: .systemBlue) }
        return Color(nsColor: .systemGreen)
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
            .foregroundStyle(Brand.amber)
            .opacity(dimmed ? 0.4 : 1.0)
            .shadow(
                color: Brand.amber.opacity(glow && !dimmed ? 0.20 : 0),
                radius: size * 0.10
            )
    }
}