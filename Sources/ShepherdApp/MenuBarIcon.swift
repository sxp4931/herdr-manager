import SwiftUI
import AppKit
import HerdrManagerCore

/// The three states the menu-bar icon can render. Calm and disconnected are
/// template images — macOS tints those correctly for light, dark, and
/// vibrant/tinted bars. Attention is drawn in a fixed state colour instead,
/// because a coloured badge must stay visibly red/amber/blue regardless of
/// bar appearance; a template image would strip that colour to monochrome.
enum HerdState: Equatable {
    case calm
    case attention(Color)
    case disconnected
}

/// Renders the flock mark, an optional status dot, and an optional
/// attention count into a single `NSImage` sized for the menu bar.
///
/// `MenuBarExtra`'s label does not reliably render an arbitrary SwiftUI
/// view stack (gradients/ZStacks over `Capsule`/`RoundedRectangle` were
/// invisible in practice) — drawing everything into one NSImage up front
/// and handing it to `Image(nsImage:)` is deterministic and is what shipping
/// menu-bar apps do.
enum MenuBarIcon {
    /// Standard macOS menu-bar item height.
    private static let barHeight: CGFloat = 18
    private static let markPointSize: CGFloat = 14
    private static let dotDiameter: CGFloat = 6
    private static let digitFontSize: CGFloat = 11
    private static let spacing: CGFloat = 3

    static func render(state: HerdState, attentionCount: Int) -> NSImage {
        switch state {
        case .calm:
            // Nothing needs the user: quiet, monochrome, and let macOS tint it.
            return composite(tint: nil, alpha: 1.0, isTemplate: true, showDot: false, countText: nil)
        case .disconnected:
            // Quiet, not alarming — dimmed template mark, no count.
            return composite(tint: nil, alpha: 0.4, isTemplate: true, showDot: false, countText: nil)
        case .attention(let color):
            let countText = attentionCount > 0 ? "\(attentionCount)" : nil
            return composite(tint: color, alpha: 1.0, isTemplate: false, showDot: true, countText: countText)
        }
    }

    /// Draw the mark (optionally tinted), an optional status dot, and
    /// optional count digits into one bitmap. `tint == nil` means "draw a
    /// plain monochrome mark and let the caller mark the image as a
    /// template" (calm/disconnected); a non-nil tint paints mark, dot, and
    /// digits in that exact colour (attention).
    private static func composite(
        tint: Color?, alpha: CGFloat, isTemplate: Bool, showDot: Bool, countText: String?
    ) -> NSImage {
        let markSide = barHeight
        let digitFont = NSFont.monospacedDigitSystemFont(ofSize: digitFontSize, weight: .semibold)
        let color = tint.map { NSColor($0) } ?? .black

        var digitsAttrString: NSAttributedString?
        var digitsSize = NSSize.zero
        if let countText {
            let attrs: [NSAttributedString.Key: Any] = [.font: digitFont, .foregroundColor: color]
            let str = NSAttributedString(string: countText, attributes: attrs)
            digitsAttrString = str
            digitsSize = str.size()
        }

        let totalWidth = markSide + (digitsAttrString != nil ? spacing + digitsSize.width : 0)
        let size = NSSize(width: max(totalWidth, markSide), height: barHeight)

        let image = NSImage(size: size, flipped: false) { _ in
            let markRect = NSRect(x: 0, y: 0, width: markSide, height: markSide)

            if let symbol = NSImage(systemSymbolName: Brand.markSymbolName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: markPointSize, weight: .medium)
                let configured = symbol.withSymbolConfiguration(config) ?? symbol
                let tinted = tintTemplate(configured, color: color)
                tinted.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: alpha)
            }

            if showDot {
                let dotRect = NSRect(
                    x: markRect.maxX - dotDiameter - 1,
                    y: markRect.maxY - dotDiameter - 1,
                    width: dotDiameter,
                    height: dotDiameter
                )
                let path = NSBezierPath(ovalIn: dotRect)
                color.setFill()
                path.fill()
                NSColor.black.withAlphaComponent(0.4).setStroke()
                path.lineWidth = 0.75
                path.stroke()
            }

            if let digitsAttrString {
                let origin = NSPoint(
                    x: markRect.maxX + spacing,
                    y: (barHeight - digitsSize.height) / 2
                )
                digitsAttrString.draw(at: origin)
            }

            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    /// Recolour a template (alpha-mask) image to a solid colour: fill a
    /// same-size rect with the colour, then punch it through the source
    /// image's alpha via `.destinationIn` so only the glyph's shape survives.
    private static func tintTemplate(_ image: NSImage, color: NSColor) -> NSImage {
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill()
        image.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1.0)
        tinted.unlockFocus()
        return tinted
    }
}
