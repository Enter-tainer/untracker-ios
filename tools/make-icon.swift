#!/usr/bin/env swift
//
// make-icon.swift — renders the 1024×1024 app icon (no external dependencies).
//
//   swift tools/make-icon.swift Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
//

import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: swift make-icon.swift <output.png>")
    exit(1)
}
let outputPath = arguments[1]
let side = 1024
let sideF = CGFloat(side)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side,
    pixelsHigh: side,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    print("could not create bitmap")
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let context = NSGraphicsContext.current?.cgContext else {
    print("no graphics context")
    exit(1)
}

// Background: diagonal indigo → teal gradient.
let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradientColors = [
    CGColor(red: 0.27, green: 0.235, blue: 0.886, alpha: 1.0),
    CGColor(red: 0.086, green: 0.639, blue: 0.60, alpha: 1.0)
] as CFArray
if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0]) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: sideF),
        end: CGPoint(x: sideF, y: 0),
        options: []
    )
}

// Soft radial highlight in the upper-left.
if let highlight = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
    ] as CFArray,
    locations: [0.0, 1.0]
) {
    context.drawRadialGradient(
        highlight,
        startCenter: CGPoint(x: 300, y: 760),
        startRadius: 0,
        endCenter: CGPoint(x: 300, y: 760),
        endRadius: 560,
        options: []
    )
}

// Chain link: two capsules, rotated, drawn as thick strokes.
context.saveGState()
context.translateBy(x: sideF / 2, y: sideF / 2 + 40)
context.rotate(by: -45 * .pi / 180)
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.setLineWidth(66)
context.setLineCap(.round)

let capsuleHeight: CGFloat = 210
let capsuleWidth: CGFloat = 260
let first = CGRect(x: -250, y: -capsuleHeight / 2, width: capsuleWidth, height: capsuleHeight)
let second = CGRect(x: -10, y: -capsuleHeight / 2, width: capsuleWidth, height: capsuleHeight)
for rect in [first, second] {
    let path = CGPath(
        roundedRect: rect,
        cornerWidth: capsuleHeight / 2,
        cornerHeight: capsuleHeight / 2,
        transform: nil
    )
    context.addPath(path)
    context.strokePath()
}
context.restoreGState()

// Badge: white circle with an indigo check mark, bottom-right.
let badgeCenter = CGPoint(x: 790, y: 250)
let badgeRadius: CGFloat = 148
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.fillEllipse(in: CGRect(
    x: badgeCenter.x - badgeRadius,
    y: badgeCenter.y - badgeRadius,
    width: badgeRadius * 2,
    height: badgeRadius * 2
))

context.setStrokeColor(CGColor(red: 0.27, green: 0.235, blue: 0.886, alpha: 1))
context.setLineWidth(34)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: badgeCenter.x - 62, y: badgeCenter.y + 2))
context.addLine(to: CGPoint(x: badgeCenter.x - 18, y: badgeCenter.y - 44))
context.addLine(to: CGPoint(x: badgeCenter.x + 66, y: badgeCenter.y + 44))
context.strokePath()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    print("could not encode png")
    exit(1)
}
try data.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) (\(data.count) bytes)")
