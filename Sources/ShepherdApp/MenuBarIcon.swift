import SwiftUI
import AppKit
import HerdrManagerCore

/// The three states the menu-bar icon can render. Calm and disconnected are
/// template images — macOS tints those correctly for light, dark, and
/// vibrant/tinted bars. Attention is drawn in a fixed state colour instead,
/// because a coloured badge must stay visibly red/amber/blue regardless of
/// bar appearance; a template image would strip that colour to monochrome.
///
/// Attention carries a shape alongside the colour. A tinted menu bar, a
/// greyscale screenshot, and a red-green colour deficiency all flatten the
/// hue; the silhouette (triangle → diamond → circle) keeps the worst-state
/// ranking readable when it does.
enum HerdState: Equatable, Hashable {
    case calm
    case attention(color: Color, shape: Brand.BadgeShape)
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
    /// Badge side length. A shape needs slightly more room than the plain dot
    /// it replaced: at 6 pt a triangle and a diamond are hard to tell apart,
    /// at 7 pt they read cleanly and still clear the mark's bounds.
    private static let dotDiameter: CGFloat = 7
    private static let digitFontSize: CGFloat = 11
    private static let spacing: CGFloat = 3

    /// Bounded cache of rendered badges. The menu-bar label re-evaluates on
    /// every herdr event, but the badge only *looks* different when the herd
    /// signal or the count changes; re-running `render` (symbol lookup plus
    /// `lockFocus` tint compositing) on every event is pure waste on the
    /// always-on hot path. When the cache outgrows its cap it is dropped
    /// wholesale and rebuilt lazily — the count shifts often enough on a busy
    /// herd that a precise LRU is not worth the bookkeeping.
    @MainActor
    private static var cache: [RenderKey: NSImage] = [:]

    /// Identity of a rendered badge: enough to know whether the bitmap needs
    /// to change. The count is part of the key because the attention digits
    /// are painted into the same image.
    private struct RenderKey: Hashable {
        let state: HerdState
        let attentionCount: Int
    }

    /// Render the badge for the current herd signal, or return the cached
    /// bitmap when the signal has not changed since the last render.
    @MainActor
    static func rendered(state: HerdState, attentionCount: Int) -> NSImage {
        let key = RenderKey(state: state, attentionCount: attentionCount)
        if let cached = cache[key] { return cached }
        let image = render(state: state, attentionCount: attentionCount)
        if cache.count >= 16 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = image
        return image
    }

    static func render(state: HerdState, attentionCount: Int) -> NSImage {
        switch state {
        case .calm:
            // Nothing needs the user: quiet, monochrome, and let macOS tint it.
            return composite(tint: nil, alpha: 1.0, isTemplate: true, dotShape: nil, countText: nil)
        case .disconnected:
            // Quiet, not alarming — dimmed template mark, no count.
            return composite(tint: nil, alpha: 0.4, isTemplate: true, dotShape: nil, countText: nil)
        case .attention(let color, let shape):
            let countText = attentionCount > 0 ? "\(attentionCount)" : nil
            return composite(
                tint: color, alpha: 1.0, isTemplate: false, dotShape: shape, countText: countText
            )
        }
    }

    /// Draw the mark (optionally tinted), an optional status badge, and
    /// optional count digits into one bitmap. `tint == nil` means "draw a
    /// plain monochrome mark and let the caller mark the image as a
    /// template" (calm/disconnected); a non-nil tint paints mark, badge, and
    /// digits in that exact colour (attention). `dotShape == nil` omits the
    /// badge entirely.
    private static func composite(
        tint: Color?, alpha: CGFloat, isTemplate: Bool, dotShape: Brand.BadgeShape?, countText: String?
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

            if let dotShape {
                let dotRect = NSRect(
                    x: markRect.maxX - dotDiameter - 1,
                    y: markRect.maxY - dotDiameter - 1,
                    width: dotDiameter,
                    height: dotDiameter
                )
                let path = badgePath(dotShape, in: dotRect)
                color.setFill()
                path.fill()
                // A dark hairline keeps the badge legible where it overlaps a
                // light bar or the mark's own strokes. It also sharpens the
                // silhouette, which is the point of having shapes at all.
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

    /// The badge silhouette for a herd state, inscribed in `rect`. Drawn as
    /// paths rather than glyphs so the shapes stay crisp at 7 pt on both 1x
    /// and 2x bars — an SF Symbol at this size would blur into a smudge.
    private static func badgePath(_ shape: Brand.BadgeShape, in rect: NSRect) -> NSBezierPath {
        switch shape {
        case .circle:
            return NSBezierPath(ovalIn: rect)
        case .diamond:
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.midX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            path.line(to: NSPoint(x: rect.midX, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX, y: rect.midY))
            path.close()
            return path
        case .triangle:
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.midX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY))
            path.close()
            return path
        }
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
