#!/usr/bin/env swift
//
//  Shepherd — App Icon Generator
//  Generates a 1024×1024 master PNG, full iconset, and .icns file.
//
//  Usage: swift Tools/GenerateIcon/main.swift
//
//  Art direction:
//  - Deep pine/teal layered background with radial depth
//  - A small connected flock — three dotted-linked nodes in warm amber/gold,
//    echoing the app's SF Symbol mark (point.3.connected.trianglepath.dotted)
//  - 7 glowing status dots streaming diagonally past the mark
//  - macOS squircle canvas, legible at 16px
//

import Cocoa
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Configuration

let canvasSize = 1024
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let projectRoot = scriptDir.deletingLastPathComponent().deletingLastPathComponent()
let resourcesDir = projectRoot.appendingPathComponent("Resources")
let iconsetDir = resourcesDir.appendingPathComponent("AppIcon.iconset")

// Colors
let deepPine     = (r: 0.043, g: 0.169, b: 0.161)   // #0B2B29
let tealGlow     = (r: 0.118, g: 0.373, b: 0.357)   // #1E5F5B
let tealMid      = (r: 0.082, g: 0.275, b: 0.263)   // #154643
let amberLight   = (r: 0.949, g: 0.702, b: 0.239)   // #F2B33D
let amberDark    = (r: 0.851, g: 0.557, b: 0.122)   // #D98E1F

// Status dot colors
let dotGreen  = (r: 0.200, g: 0.780, b: 0.349)  // #34C759
let dotAmber  = (r: 1.000, g: 0.690, b: 0.125)  // #FFB020
let dotRed    = (r: 1.000, g: 0.271, b: 0.227)  // #FF453A
let dotBlue   = (r: 0.231, g: 0.620, b: 1.000)  // #3B9EFF
let dotWhite  = (r: 0.950, g: 0.950, b: 0.970)  // soft white

// Dot layout: (x, y, radius, color, hasTrail)
// Streaming diagonally from lower-left to upper-right, beneath the crook
let dots: [(x: CGFloat, y: CGFloat, radius: CGFloat,
            color: (r: Double, g: Double, b: Double), hasTrail: Bool)] = [
    (180, 740, 11, dotGreen, false),
    (300, 670, 14, dotBlue,  false),
    (430, 610, 13, dotAmber, true),
    (540, 560,  9, dotWhite, false),
    (660, 510, 12, dotRed,   false),
    (770, 460, 10, dotGreen, true),
    (860, 420,  8, dotWhite, false),
]

// MARK: - Helpers

func cgColor(_ c: (r: Double, g: Double, b: Double), alpha: CGFloat = 1.0) -> CGColor {
    CGColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: alpha)
}

func makeBitmapContext(width: Int, height: Int) -> CGContext {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Flip so origin is top-left
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func squirclePath(size: CGFloat, cornerRadius: CGFloat) -> CGPath {
    // macOS-style continuous-corner squircle approximated by a rounded rect
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    return CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
}

func savePNG(image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func downscaleHQ(source: CGImage, to size: Int) -> CGImage {
    let ctx = makeBitmapContext(width: size, height: size)
    ctx.interpolationQuality = .high
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

// MARK: - Drawing functions

func drawBackground(ctx: CGContext, size: Int) {
    let s = CGFloat(size)

    // Layer 1: Base fill — deep pine
    ctx.setFillColor(cgColor(deepPine))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // Layer 2: Primary radial glow — upper center
    let gradient1Colors = [
        cgColor(tealGlow, alpha: 0.95),
        cgColor(tealGlow, alpha: 0.4),
        cgColor(tealMid, alpha: 0.0)
    ] as CFArray
    let gradient1 = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: gradient1Colors,
        locations: [0.0, 0.5, 1.0]
    )!
    ctx.drawRadialGradient(
        gradient1,
        startCenter: CGPoint(x: s * 0.50, y: s * 0.30),
        startRadius: 0,
        endCenter: CGPoint(x: s * 0.50, y: s * 0.55),
        endRadius: s * 0.62,
        options: []
    )

    // Layer 3: Secondary subtle glow — slightly lower, for depth
    let gradient2Colors = [
        cgColor(tealMid, alpha: 0.35),
        cgColor(deepPine, alpha: 0.0)
    ] as CFArray
    let gradient2 = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: gradient2Colors,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        gradient2,
        startCenter: CGPoint(x: s * 0.45, y: s * 0.60),
        startRadius: 0,
        endCenter: CGPoint(x: s * 0.50, y: s * 0.65),
        endRadius: s * 0.45,
        options: []
    )

    // Layer 4: Vignette — darken edges
    let vigColors = [
        cgColor(deepPine, alpha: 0.0),
        cgColor(deepPine, alpha: 0.55)
    ] as CFArray
    let vig = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: vigColors,
        locations: [0.6, 1.0]
    )!
    ctx.drawRadialGradient(
        vig,
        startCenter: CGPoint(x: s * 0.5, y: s * 0.5),
        startRadius: s * 0.3,
        endCenter: CGPoint(x: s * 0.5, y: s * 0.5),
        endRadius: s * 0.72,
        options: []
    )
}

/// Three dotted-linked nodes in a small triangle, echoing the app's SF
/// Symbol mark (`point.3.connected.trianglepath.dotted`) rather than a
/// monogram — replaces the old drawn "H" (Shepherd dropped that glyph
/// entirely; it didn't render legibly at menu-bar size).
func drawFlockMark(ctx: CGContext, size: Int) {
    let s = CGFloat(size)

    let topPoint = CGPoint(x: s * 0.500, y: s * 0.775)
    let leftPoint = CGPoint(x: s * 0.335, y: s * 0.415)
    let rightPoint = CGPoint(x: s * 0.665, y: s * 0.415)
    let nodeRadius = s * 0.072
    let strokeW = s * 0.026

    let amberGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [cgColor(amberLight), cgColor(amberDark)] as CFArray,
        locations: [0.0, 1.0]
    )!

    // --- Dotted connecting strokes, glowing ---
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22, color: cgColor(amberLight, alpha: 0.4))
    ctx.setStrokeColor(cgColor(amberLight, alpha: 0.9))
    ctx.setLineWidth(strokeW)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [strokeW * 1.5, strokeW * 1.8])
    let linkPath = CGMutablePath()
    linkPath.move(to: topPoint)
    linkPath.addLine(to: leftPoint)
    linkPath.move(to: topPoint)
    linkPath.addLine(to: rightPoint)
    linkPath.move(to: leftPoint)
    linkPath.addLine(to: rightPoint)
    ctx.addPath(linkPath)
    ctx.strokePath()
    ctx.restoreGState()

    // --- Three glowing nodes, gradient-filled ---
    for point in [topPoint, leftPoint, rightPoint] {
        let rect = CGRect(
            x: point.x - nodeRadius, y: point.y - nodeRadius,
            width: nodeRadius * 2, height: nodeRadius * 2
        )

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 30, color: cgColor(amberLight, alpha: 0.45))
        ctx.addEllipse(in: rect)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        ctx.drawRadialGradient(
            amberGradient,
            startCenter: point, startRadius: 0,
            endCenter: point, endRadius: nodeRadius,
            options: []
        )
        ctx.restoreGState()
    }
}

func fillEllipseWithRadialGradient(ctx: CGContext, rect: CGRect, gradient: CGGradient) {
    ctx.saveGState()
    ctx.addEllipse(in: rect)
    ctx.clip()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) / 2.0
    ctx.drawRadialGradient(
        gradient,
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: radius,
        options: []
    )
    ctx.restoreGState()
}

func drawDots(ctx: CGContext, size: Int) {
    let s = CGFloat(size)
    let scale = s / 1024.0

    for dot in dots {
        let x = dot.x * scale
        let y = dot.y * scale
        let r = dot.radius * scale
        let color = dot.color

        // Trail (if enabled) — faint streak behind the dot
        if dot.hasTrail {
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            // Motion direction: roughly upper-right (45°)
            ctx.rotate(by: -CGFloat.pi / 4)
            let trailGrad = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    cgColor(color, alpha: 0.0),
                    cgColor(color, alpha: 0.25)
                ] as CFArray,
                locations: [0.0, 1.0]
            )!
            let trailRect = CGRect(x: -r * 3.5, y: -r * 0.4,
                                    width: r * 3.5, height: r * 0.8)
            // Fill trail ellipse with gradient
            ctx.addEllipse(in: trailRect)
            ctx.clip()
            let trailCenter = CGPoint(x: trailRect.midX, y: trailRect.midY)
            ctx.drawRadialGradient(
                trailGrad,
                startCenter: trailCenter,
                startRadius: 0,
                endCenter: trailCenter,
                endRadius: min(trailRect.width, trailRect.height) / 2.0,
                options: []
            )
            ctx.restoreGState()
        }

        // Outer glow halo
        let glowR = r * 2.8
        let glowGrad = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                cgColor(color, alpha: 0.50),
                cgColor(color, alpha: 0.15),
                cgColor(color, alpha: 0.0)
            ] as CFArray,
            locations: [0.0, 0.4, 1.0]
        )!
        fillEllipseWithRadialGradient(
            ctx: ctx,
            rect: CGRect(x: x - glowR, y: y - glowR, width: glowR * 2, height: glowR * 2),
            gradient: glowGrad
        )

        // Core dot
        let coreGrad = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                cgColor(color, alpha: 1.0),
                cgColor(color, alpha: 0.85)
            ] as CFArray,
            locations: [0.0, 1.0]
        )!
        fillEllipseWithRadialGradient(
            ctx: ctx,
            rect: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2),
            gradient: coreGrad
        )

        // Bright center highlight
        let hiR = r * 0.4
        ctx.setFillColor(cgColor(dotWhite, alpha: 0.6))
        ctx.fillEllipse(
            in: CGRect(x: x - hiR - r * 0.15, y: y - hiR - r * 0.15,
                       width: hiR * 2, height: hiR * 2)
        )
    }
}

// MARK: - Main

print("🎨 Shepherd Icon Generator")
print("================================")

// Ensure output directories exist
try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// 1. Create master 1024×1024 context
let ctx = makeBitmapContext(width: canvasSize, height: canvasSize)
ctx.interpolationQuality = .high

// 2. Clip to squircle
let squircle = squirclePath(size: CGFloat(canvasSize), cornerRadius: CGFloat(canvasSize) * 0.22)
ctx.addPath(squircle)
ctx.clip()

// 3. Draw layers
drawBackground(ctx: ctx, size: canvasSize)
drawFlockMark(ctx: ctx, size: canvasSize)
drawDots(ctx: ctx, size: canvasSize)

// 4. Get the master image
guard let masterImage = ctx.makeImage() else {
    fatalError("Failed to create master image")
}

// 5. Save master PNG
let masterURL = resourcesDir.appendingPathComponent("AppIcon-1024.png")
savePNG(image: masterImage, to: masterURL)
print("✅ Master PNG: \(masterURL.path)")

// 6. Generate iconset
let iconSizes: [(name: String, px: Int)] = [
    ("icon_16x16",      16),
    ("icon_16x16@2x",   32),
    ("icon_32x32",      32),
    ("icon_32x32@2x",   64),
    ("icon_128x128",    128),
    ("icon_128x128@2x", 256),
    ("icon_256x256",    256),
    ("icon_256x256@2x", 512),
    ("icon_512x512",    512),
    ("icon_512x512@2x", 1024),
]

for spec in iconSizes {
    let scaled = downscaleHQ(source: masterImage, to: spec.px)
    let fileURL = iconsetDir.appendingPathComponent("\(spec.name).png")
    savePNG(image: scaled, to: fileURL)
}
print("✅ Iconset: \(iconsetDir.path) (\(iconSizes.count) sizes)")

// 7. Run iconutil to create .icns
let icnsURL = resourcesDir.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", icnsURL.path, iconsetDir.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("✅ ICNS: \(icnsURL.path)")
} else {
    print("❌ iconutil failed with status \(process.terminationStatus)")
}

// 8. Print artifact summary
print("\n📦 Artifacts:")
let fm = FileManager.default
let resourceFiles = try fm.contentsOfDirectory(at: resourcesDir, includingPropertiesForKeys: [.fileSizeKey])
for file in resourceFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    let attrs = try file.resourceValues(forKeys: [.fileSizeKey])
    let sizeStr = attrs.fileSize.map { "\($0) bytes" } ?? "?"
    print("   \(file.lastPathComponent): \(sizeStr)")
}

print("\n✨ Done!")
