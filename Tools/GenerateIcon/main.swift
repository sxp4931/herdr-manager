#!/usr/bin/env swift
//
//  Shepherd — App Icon Builder
//  Compiles the authored artwork into a masked 1024 px master, a complete
//  macOS iconset, and an .icns file.
//
//  Usage: swift Tools/GenerateIcon/main.swift
//
//  Art direction:
//  - A single warm-gold shepherd's crook forming an understated "S"
//  - Three pearl nodes held inside the crook, representing guided agents
//  - Deep pine enamel, generous margins, and enough weight to read at 16 px
//

import Cocoa
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let canvasSize = 1024
let scriptDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
let projectRoot = scriptDirectory
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let resourcesDirectory = projectRoot.appendingPathComponent("Resources")
let artworkURL = resourcesDirectory.appendingPathComponent("AppIcon-Artwork.png")
let masterURL = resourcesDirectory.appendingPathComponent("AppIcon-1024.png")
let iconsetDirectory = resourcesDirectory.appendingPathComponent("AppIcon.iconset")
let icnsURL = resourcesDirectory.appendingPathComponent("AppIcon.icns")

let iconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

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
    return context
}

func loadImage(at url: URL) -> CGImage {
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        fatalError("Could not load artwork at \(url.path)")
    }
    return image
}

func savePNG(_ image: CGImage, to url: URL) {
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

func makeMaster(from artwork: CGImage) -> CGImage {
    let context = makeBitmapContext(width: canvasSize, height: canvasSize)
    let bounds = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)

    // The source render intentionally includes its own subtle edge treatment.
    // This outer mask supplies clean alpha corners for a proper macOS asset.
    let mask = CGPath(
        roundedRect: bounds,
        cornerWidth: CGFloat(canvasSize) * 0.22,
        cornerHeight: CGFloat(canvasSize) * 0.22,
        transform: nil
    )
    context.addPath(mask)
    context.clip()
    context.draw(artwork, in: bounds)

    guard let image = context.makeImage() else {
        fatalError("Could not create master icon")
    }
    return image
}

func downscale(_ source: CGImage, to pixels: Int) -> CGImage {
    let context = makeBitmapContext(width: pixels, height: pixels)
    context.draw(
        source,
        in: CGRect(x: 0, y: 0, width: pixels, height: pixels)
    )
    guard let image = context.makeImage() else {
        fatalError("Could not create \(pixels) px icon")
    }
    return image
}

print("🎨 Building Shepherd app icon")

try FileManager.default.createDirectory(
    at: iconsetDirectory,
    withIntermediateDirectories: true
)

let artwork = loadImage(at: artworkURL)
let master = makeMaster(from: artwork)
savePNG(master, to: masterURL)
print("✅ Master: \(masterURL.path)")

for iconSize in iconSizes {
    let image = downscale(master, to: iconSize.pixels)
    let outputURL = iconsetDirectory
        .appendingPathComponent("\(iconSize.name).png")
    savePNG(image, to: outputURL)
}
print("✅ Iconset: \(iconsetDirectory.path)")

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns",
    "-o", icnsURL.path,
    iconsetDirectory.path,
]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}

print("✅ ICNS: \(icnsURL.path)")
print("✨ Done")
