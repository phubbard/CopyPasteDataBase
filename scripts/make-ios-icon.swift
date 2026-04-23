#!/usr/bin/env swift
//
// make-ios-icon.swift — render cpdb's iOS AppIcon PNG.
//
// iOS masks the app icon itself with the system squircle on every
// home-screen render, so unlike the Mac icon this one is a FLAT
// square with a filled background and no client-side rounding.
// That avoids the double-rounded look you'd get from reusing
// scripts/make-icon.swift (which bakes in a rounded-square mask
// for macOS's flat-on-disk convention).
//
// Output: iOS/cpdb/cpdb/Assets.xcassets/AppIcon.appiconset/AppIcon.png
// (1024×1024). Xcode 14+ handles downscaling to every runtime size.
//
// Run from repo root:
//   scripts/make-ios-icon.swift

import AppKit
import CoreGraphics

let outputPath = "iOS/cpdb/cpdb/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let symbolName = "list.clipboard.fill"

// Matches the Mac icon's tonal palette so both platforms read as
// the same product family at a glance.
let backgroundTop    = NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 1)
let backgroundBottom = NSColor(calibratedRed: 0.12, green: 0.30, blue: 0.72, alpha: 1)
let symbolFillFraction: CGFloat = 0.56

let pixels = 1024
let size = CGFloat(pixels)
let rect = NSRect(x: 0, y: 0, width: size, height: size)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 32
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Flat square background (NO squircle mask — iOS applies its own).
let gradient = NSGradient(starting: backgroundTop, ending: backgroundBottom)!
gradient.draw(in: rect, angle: -90)

// Centered white glyph. Same symbol as the Mac app + menu-bar icon.
let pointSize = size * symbolFillFraction
let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
if let symbol = NSImage(
    systemSymbolName: symbolName,
    accessibilityDescription: "cpdb"
)?.withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size, flipped: false) { drawRect in
        symbol.draw(in: drawRect)
        NSColor.white.set()
        drawRect.fill(using: .sourceAtop)
        return true
    }
    let glyphRect = NSRect(
        x: (size - tinted.size.width) / 2,
        y: (size - tinted.size.height) / 2,
        width: tinted.size.width,
        height: tinted.size.height
    )
    tinted.draw(in: glyphRect)
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("png encoding failed\n".data(using: .utf8)!)
    exit(1)
}
let url = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try data.write(to: url)
print("wrote \(outputPath) (\(data.count / 1024) KiB)")
