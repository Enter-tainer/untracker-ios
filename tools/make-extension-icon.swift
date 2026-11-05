#!/usr/bin/env swift
//
// make-extension-icon.swift — draws the monochrome line-art icon used by the Share
// and Action extensions.
//
// Share-sheet action icons are shown small and monochrome (the system renders them
// as template images, and even when it does not, a colour app icon looks out of
// place). So this draws just the chain-link glyph on a transparent background in a
// neutral grey, which reads correctly in both light and dark mode.
//
//   swift tools/make-extension-icon.swift <output-directory> [name]
//
// Writes <name>@1x.png (60pt), @2x.png (120pt) and @3x.png (180pt).
//

import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: swift make-extension-icon.swift <output-directory> [name]")
    exit(1)
}
let outputDirectory = arguments[1]
let baseName = arguments.count >= 3 ? arguments[2] : "UntrackerIcon"

/// Point sizes the system asks for; the 60pt slot covers the share sheet row.
let sizes: [(suffix: String, pixels: Int)] = [
    ("@1x", 60),
    ("@2x", 120),
    ("@3x", 180)
]

/// Neutral grey that stays legible on both white and near-black sheets.
let glyphColour = CGColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1.0)

func renderIcon(pixels: Int) -> Data? {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    guard let context = NSGraphicsContext.current?.cgContext else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }

    // Transparent background: nothing to fill, but clear explicitly in case the
    // backing store is not zeroed.
    context.clear(CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))

    // Geometry is authored for a 180pt canvas and scaled to the requested size.
    let scale = CGFloat(pixels) / 180.0
    let lineWidth = 11.0 * scale
    let capsuleWidth = 74.0 * scale
    let capsuleHeight = 58.0 * scale
    let gap = 4.0 * scale

    context.translateBy(x: CGFloat(pixels) / 2, y: CGFloat(pixels) / 2)
    context.rotate(by: -45 * .pi / 180)
    context.setStrokeColor(glyphColour)
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)

    // Two overlapping capsules read as a chain link.
    let left = CGRect(
        x: -(capsuleWidth + gap / 2),
        y: -capsuleHeight / 2,
        width: capsuleWidth,
        height: capsuleHeight
    )
    let right = CGRect(
        x: gap / 2,
        y: -capsuleHeight / 2,
        width: capsuleWidth,
        height: capsuleHeight
    )
    for rect in [left, right] {
        let radius = capsuleHeight / 2
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.addPath(path)
        context.strokePath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return representation.representation(using: .png, properties: [:])
}

try? FileManager.default.createDirectory(
    atPath: outputDirectory,
    withIntermediateDirectories: true
)

for size in sizes {
    guard let data = renderIcon(pixels: size.pixels) else {
        print("failed to render \(size.suffix)")
        exit(1)
    }
    let path = "\(outputDirectory)/\(baseName)\(size.suffix).png"
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(size.pixels)x\(size.pixels), \(data.count) bytes)")
    } catch {
        print("failed to write \(path): \(error)")
        exit(1)
    }
}
