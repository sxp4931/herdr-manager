#!/usr/bin/env swift
//
//  Shepherd — DMG installer background
//
//  Usage: swift Tools/GenerateDMGBackground/main.swift
//
//  THESIS: A light Finder installer that makes one action obvious — drag
//  Shepherd into Applications — and refuses a blank charcoal slab.
//  OWN-WORLD: Pale warm paper, one thin charcoal chevron, SF Pro caption.
//  Finder draws the real icons; this file never impersonates them.
//  STORY: Open the DMG, see Shepherd on the left, a quiet chevron,
//  Applications on the right, drag; then close this window.
//  FIRST VIEWPORT: 660×400 Finder window. Icon wells at layout.json.
//  Thin chevron in the gap. Drag caption, then the close cue, below the labels.
//  FORM: Classic Mac drag-install; approved classic comp.
//  FINISH: unreviewed and undocumented is unfinished; this build ends with
//  the finish review, the verdict, and DESIGN.md
//

import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Layout: Decodable {
    let windowWidth: Int
    let windowHeight: Int
    let iconSize: Int
    let appX: Int
    let appY: Int
    let applicationsX: Int
    let applicationsY: Int
}

let scriptDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
let projectRoot = scriptDirectory
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let dmgDirectory = projectRoot.appendingPathComponent("Resources/dmg")
let layoutURL = dmgDirectory.appendingPathComponent("layout.json")

let layout: Layout = {
    let data = try! Data(contentsOf: layoutURL)
    return try! JSONDecoder().decode(Layout.self, from: data)
}()

let scale = 2
let caption = "Drag Shepherd to Applications"
let closeCue = "Then close this window"

// Warm paper — Finder-like, slightly warmer than system grey.
let paperTop = CGColor(srgbRed: 0.949, green: 0.941, blue: 0.918, alpha: 1)   // #F2F0EA
let paperBottom = CGColor(srgbRed: 0.925, green: 0.914, blue: 0.886, alpha: 1) // #ECE9E2
let captionColor = NSColor(srgbRed: 0.353, green: 0.373, blue: 0.392, alpha: 1) // Brand.secondaryText light
let chevronColor = CGColor(srgbRed: 0.353, green: 0.373, blue: 0.392, alpha: 0.45)

func makeBitmapContext(width: Int, height: Int) -> CGContext {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create \(width)×\(height) bitmap context")
    }
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    return context
}

func savePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("Could not create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write PNG at \(url.path)")
    }
}

/// Finder icon positions use a top-left origin. CoreGraphics uses bottom-left.
func cgY(_ finderY: CGFloat) -> CGFloat {
    CGFloat(layout.windowHeight) - finderY
}

func addPaper(in context: CGContext, bounds: CGRect) {
    let colors = [paperTop, paperBottom] as CFArray
    let locations: [CGFloat] = [0, 1]
    guard let gradient = CGGradient(
        colorsSpace: context.colorSpace,
        colors: colors,
        locations: locations
    ) else { return }
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: bounds.midX, y: bounds.maxY),
        end: CGPoint(x: bounds.midX, y: bounds.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

func chevronPath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let insetX = rect.width * 0.08
    let insetY = rect.height * 0.10
    path.move(to: CGPoint(x: rect.minX + insetX, y: rect.maxY - insetY))
    path.addLine(to: CGPoint(x: rect.maxX - insetX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.minX + insetX, y: rect.minY + insetY))
    return path
}

func addChevron(in context: CGContext) {
    let gapLeading = CGFloat(layout.appX) + CGFloat(layout.iconSize) / 2
    let gapTrailing = CGFloat(layout.applicationsX) - CGFloat(layout.iconSize) / 2
    let midX = (gapLeading + gapTrailing) / 2
    let midY = cgY(CGFloat(layout.appY) - 4)
    let width: CGFloat = 36
    let height: CGFloat = 28
    let rect = CGRect(
        x: midX - width / 2,
        y: midY - height / 2,
        width: width,
        height: height
    )

    context.saveGState()
    context.setStrokeColor(chevronColor)
    context.setLineWidth(2)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(chevronPath(in: rect))
    context.strokePath()
    context.restoreGState()
}

func drawCenteredLine(
    _ text: String,
    finderY: CGFloat,
    font: NSFont,
    color: NSColor,
    kern: CGFloat,
    in context: CGContext
) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .kern: kern,
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let line = CTLineCreateWithAttributedString(attributed)

    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let baseline = cgY(finderY) - descent
    let x = CGFloat(layout.windowWidth) / 2 - width / 2

    context.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(line, context)
}

func addCaption(in context: CGContext) {
    let iconBottom = CGFloat(layout.appY) + CGFloat(layout.iconSize) / 2
    // Finder's icon label sits ~28pt under the icon body. Sit the drag
    // instruction clearly below that, with the close cue as the next beat.
    let dragY = iconBottom + 80
    drawCenteredLine(
        caption,
        finderY: dragY,
        font: NSFont.systemFont(ofSize: 15, weight: .medium),
        color: captionColor,
        kern: 0.25,
        in: context
    )
    drawCenteredLine(
        closeCue,
        finderY: dragY + 22,
        font: NSFont.systemFont(ofSize: 13, weight: .regular),
        color: captionColor,
        kern: 0.2,
        in: context
    )
}

func render(previewWells: Bool) -> CGImage {
    let pixelWidth = layout.windowWidth * scale
    let pixelHeight = layout.windowHeight * scale
    let context = makeBitmapContext(width: pixelWidth, height: pixelHeight)
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    let bounds = CGRect(
        x: 0,
        y: 0,
        width: layout.windowWidth,
        height: layout.windowHeight
    )
    addPaper(in: context, bounds: bounds)
    addChevron(in: context)
    addCaption(in: context)

    if previewWells {
        context.setStrokeColor(CGColor(srgbRed: 0.353, green: 0.373, blue: 0.392, alpha: 0.22))
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        for (x, y) in [(layout.appX, layout.appY), (layout.applicationsX, layout.applicationsY)] {
            let well = CGRect(
                x: CGFloat(x) - CGFloat(layout.iconSize) / 2,
                y: cgY(CGFloat(y)) - CGFloat(layout.iconSize) / 2,
                width: CGFloat(layout.iconSize),
                height: CGFloat(layout.iconSize)
            )
            context.strokeEllipse(in: well)
        }
    }

    guard let image = context.makeImage() else {
        fatalError("Could not render DMG background")
    }
    return image
}

func downscale(_ source: CGImage, width: Int, height: Int) -> CGImage {
    let context = makeBitmapContext(width: width, height: height)
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        fatalError("Could not downscale DMG background")
    }
    return image
}

print("🎨 Building Shepherd DMG background")

let retina = render(previewWells: false)
let oneX = downscale(retina, width: layout.windowWidth, height: layout.windowHeight)
let preview = render(previewWells: true)

let retinaURL = dmgDirectory.appendingPathComponent("background@2x.png")
let oneXURL = dmgDirectory.appendingPathComponent("background.png")
let tiffURL = dmgDirectory.appendingPathComponent("background.tiff")
let previewDirectory = projectRoot.appendingPathComponent(".impeccable/mocks")
let previewURL = previewDirectory.appendingPathComponent("dmg-background-preview.png")

savePNG(oneX, to: oneXURL)
savePNG(retina, to: retinaURL)
savePNG(preview, to: previewURL)
print("✅ PNG: \(oneXURL.path)")
print("✅ PNG@2x: \(retinaURL.path)")
print("✅ Preview: \(previewURL.path)")

let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = [
    "-cathidpicheck",
    oneXURL.path,
    retinaURL.path,
    "-out",
    tiffURL.path,
]
try tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else {
    fatalError("tiffutil failed with status \(tiffutil.terminationStatus)")
}
print("✅ TIFF: \(tiffURL.path)")
print("✨ Done")
