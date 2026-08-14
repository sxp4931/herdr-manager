#!/usr/bin/env swift
//
//  Shepherd — DMG installer background
//
//  Usage: swift Tools/GenerateDMGBackground/main.swift
//
//  THESIS: A light Finder installer that makes one action obvious — drag
//  Shepherd into Applications — and refuses a blank charcoal slab.
//  OWN-WORLD: Pale warm paper, one matte gold chevron (the crook metal),
//  SF Pro caption in charcoal. Finder draws the real icons; this file
//  never impersonates them.
//  STORY: Open the DMG, see Shepherd on the left, gold chevron, Applications
//  on the right, drag.
//  FIRST VIEWPORT: 660×400 Finder window. Icon wells at layout.json.
//  Gold chevron in the gap. Caption below the labels.
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

// Warm paper — Finder-like, slightly warmer so the gold has a home.
let paperTop = CGColor(srgbRed: 0.949, green: 0.941, blue: 0.918, alpha: 1)   // #F2F0EA
let paperBottom = CGColor(srgbRed: 0.925, green: 0.914, blue: 0.886, alpha: 1) // #ECE9E2
let goldLight = CGColor(srgbRed: 0.910, green: 0.690, blue: 0.220, alpha: 1)   // #E8B038
let goldMid = CGColor(srgbRed: 0.820, green: 0.560, blue: 0.125, alpha: 1)     // #D18E20
let goldDeep = CGColor(srgbRed: 0.580, green: 0.390, blue: 0.055, alpha: 1)    // #94630E
let goldHighlight = CGColor(srgbRed: 0.980, green: 0.840, blue: 0.400, alpha: 1) // #FAD666
let captionColor = NSColor(srgbRed: 0.353, green: 0.373, blue: 0.392, alpha: 1) // Brand.secondaryText light

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

    // A whisper of gold behind the chevron so the metal sits in the paper,
    // not on it.
    let glowColors = [
        CGColor(srgbRed: 0.890, green: 0.710, blue: 0.275, alpha: 0.07),
        CGColor(srgbRed: 0.890, green: 0.710, blue: 0.275, alpha: 0),
    ] as CFArray
    if let glow = CGGradient(colorsSpace: context.colorSpace, colors: glowColors, locations: [0, 1]) {
        let midX = (CGFloat(layout.appX) + CGFloat(layout.applicationsX)) / 2
        let midY = cgY(CGFloat(layout.appY))
        context.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: midX, y: midY),
            startRadius: 0,
            endCenter: CGPoint(x: midX, y: midY),
            endRadius: 140,
            options: [.drawsAfterEndLocation]
        )
    }
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
    let width: CGFloat = 108
    let height: CGFloat = 64
    let rect = CGRect(
        x: midX - width / 2,
        y: midY - height / 2,
        width: width,
        height: height
    )

    let lineWidth: CGFloat = 14
    let path = chevronPath(in: rect)
    let stroked = path.copy(
        strokingWithWidth: lineWidth,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 10
    )

    context.saveGState()
    context.addPath(stroked)
    context.clip()

    let colors = [goldHighlight, goldLight, goldMid, goldDeep] as CFArray
    let locations: [CGFloat] = [0, 0.28, 0.68, 1]
    if let gradient = CGGradient(
        colorsSpace: context.colorSpace,
        colors: colors,
        locations: locations
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.minY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
    context.restoreGState()

    // A hairline of deeper gold on the underside so the chevron reads as
    // a piece of metal, not a flat sticker.
    context.saveGState()
    context.addPath(stroked)
    context.setStrokeColor(goldDeep.copy(alpha: 0.35)!)
    context.setLineWidth(0.75)
    context.strokePath()
    context.restoreGState()
}

func addCaption(in context: CGContext) {
    let font = NSFont.systemFont(ofSize: 15, weight: .medium)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: captionColor,
        .kern: 0.25,
    ]
    let attributed = NSAttributedString(string: caption, attributes: attributes)
    let line = CTLineCreateWithAttributedString(attributed)

    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

    let iconBottom = CGFloat(layout.appY) + CGFloat(layout.iconSize) / 2
    // Finder's icon label sits ~28pt under the icon body. Sit the caption
    // clearly below that, still inside the window with a generous footer.
    let finderY = iconBottom + 92
    let baseline = cgY(finderY) - descent
    let x = CGFloat(layout.windowWidth) / 2 - width / 2

    context.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(line, context)
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
