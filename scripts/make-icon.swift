#!/usr/bin/env swift
//
// make-icon.swift — render cpdb's AppIcon.icns from scratch.
//
// Draws the `list.clipboard.fill` SF Symbol centred on a blue gradient
// with a rounded-square mask, at every size macOS's .icns wants
// (16–1024 pt, @1x and @2x). Writes an `.iconset` directory and invokes
// `iconutil` to compile the final `AppIcon.icns`.
//
// Run from repo root:
//   scripts/make-icon.swift
//
// The script is idempotent: wipes the iconset directory each run so a
// symbol change produces a clean icns.

import AppKit
import CoreGraphics

// MARK: - Config

let outputDir  = "Sources/CpdbApp/Resources/Assets"
let iconsetDir = "\(outputDir)/AppIcon.iconset"
let icnsPath   = "\(outputDir)/AppIcon.icns"

// SF Symbol rendered in white on top of the gradient. `list.clipboard.fill`
// matches the menu-bar icon used by `StatusItemController`.
let symbolName = "list.clipboard.fill"

// Apple Human Interface Guidelines for macOS icons: leave ~10% padding,
// use a rounded square (the "squircle"), lean into gradient depth.
let cornerRadiusFraction: CGFloat = 0.225     // matches macOS Big Sur+ icons
let symbolFillFraction:   CGFloat = 0.56      // how big the symbol sits
let backgroundTop    = NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 1) // bright blue
let backgroundBottom = NSColor(calibratedRed: 0.12, green: 0.30, blue: 0.72, alpha: 1) // deep blue

// Apple's required sizes for a macOS iconset. `iconutil` expects these
// exact filenames.
struct IconSize {
    let pixels: Int
    let filename: String
}
let sizes: [IconSize] = [
    .init(pixels: 16,   filename: "icon_16x16.png"),
    .init(pixels: 32,   filename: "icon_16x16@2x.png"),
    .init(pixels: 32,   filename: "icon_32x32.png"),
    .init(pixels: 64,   filename: "icon_32x32@2x.png"),
    .init(pixels: 128,  filename: "icon_128x128.png"),
    .init(pixels: 256,  filename: "icon_128x128@2x.png"),
    .init(pixels: 256,  filename: "icon_256x256.png"),
    .init(pixels: 512,  filename: "icon_256x256@2x.png"),
    .init(pixels: 512,  filename: "icon_512x512.png"),
    .init(pixels: 1024, filename: "icon_512x512@2x.png"),
]

// MARK: - Rendering

/// Renders the icon at `pixels` × `pixels` and returns PNG bytes.
func renderIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // Bitmap rep at 1× (we pre-bake @2x into bigger pixel counts via the
    // sizes table above, so there's no `scaleFactor` to worry about here).
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded-square clip.
    let cornerRadius = size * cornerRadiusFraction
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    path.addClip()

    // Vertical gradient background.
    let gradient = NSGradient(starting: backgroundTop, ending: backgroundBottom)!
    gradient.draw(in: rect, angle: -90)

    // Symbol layer. Pointsize ≈ 60% of icon edge gives a readable glyph
    // with breathing room; tweak `symbolFillFraction` to taste.
    let pointSize = size * symbolFillFraction
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    let symbol = NSImage(
        systemSymbolName: symbolName,
        accessibilityDescription: "cpdb"
    )?.withSymbolConfiguration(config)
    if let symbol = symbol {
        // Tint the symbol white by rendering it through a `template` pass.
        let tinted = NSImage(size: symbol.size, flipped: false) { drawRect in
            symbol.draw(in: drawRect)
            NSColor.white.set()
            drawRect.fill(using: .sourceAtop)
            return true
        }
        // Centre it on the canvas.
        let glyphRect = NSRect(
            x: (size - tinted.size.width) / 2,
            y: (size - tinted.size.height) / 2,
            width: tinted.size.width,
            height: tinted.size.height
        )
        tinted.draw(in: glyphRect)
    } else {
        FileHandle.standardError.write("warning: SF Symbol '\(symbolName)' not available at \(pixels)px\n".data(using: .utf8)!)
    }

    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Pipeline

let fm = FileManager.default
try? fm.removeItem(atPath: iconsetDir)
try fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for sz in sizes {
    let data = renderIcon(pixels: sz.pixels)
    let path = "\(iconsetDir)/\(sz.filename)"
    try data.write(to: URL(fileURLWithPath: path))
    print("  rendered \(sz.filename) (\(sz.pixels)px, \(data.count / 1024) KiB)")
}

// Invoke `iconutil` to pack the iconset into an icns.
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus == 0 {
    print("wrote \(icnsPath)")
} else {
    FileHandle.standardError.write("iconutil failed with status \(proc.terminationStatus)\n".data(using: .utf8)!)
    exit(1)
}
