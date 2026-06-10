#if os(macOS) || os(iOS)
import Foundation
import CpdbShared
#if os(macOS)
import AppKit
#endif

public struct FrontmostAppInfo: Sendable {
    public var bundleId: String
    public var name: String
    /// Raw icon bytes, PNG-encoded. Nil if we couldn't resolve.
    public var iconPng: Data?

    public init(bundleId: String, name: String, iconPng: Data? = nil) {
        self.bundleId = bundleId
        self.name = name
        self.iconPng = iconPng
    }

    /// Synthetic source-app identity used by non-clipboard ingest
    /// paths (the `cpdb import` command, future scripted seeders).
    /// Entries attributed to this show "cpdb import" as their
    /// source app in the popup + tooltips, distinguishing seeded
    /// data from real captures.
    public static let importer = FrontmostAppInfo(
        bundleId: "net.phfactor.cpdb.importer",
        name: "cpdb import",
        iconPng: nil
    )

    /// Synthetic source-app identity for clipboard captures made on
    /// iOS. iOS gives apps no way to learn which app the user copied
    /// *from* (there is no `NSWorkspace.frontmostApplication`
    /// equivalent, and reading the source app would require private
    /// API), so every iOS capture is attributed to this single
    /// identity. On the Mac, entry detail shows "captured on <device>"
    /// from the device row; the app row here just gives the popup a
    /// stable, honest label ("iOS clipboard") instead of "unknown".
    public static let iosClipboard = FrontmostAppInfo(
        bundleId: "net.phfactor.cpdb.ios.clipboard",
        name: "iOS clipboard",
        iconPng: nil
    )
}

#if os(macOS)
public enum FrontmostApp {
    /// Snapshot the current frontmost application. Must be called shortly
    /// after a pasteboard change — after that the race window is wide open.
    @MainActor
    public static func current() -> FrontmostAppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleId = app.bundleIdentifier ?? "unknown.\(app.processIdentifier)"
        let name = app.localizedName ?? bundleId
        let icon = app.icon.flatMap { pngData(from: $0) }
        return FrontmostAppInfo(bundleId: bundleId, name: name, iconPng: icon)
    }

    /// Encodes an NSImage as a 64×64 PNG. Good enough for storing in SQLite
    /// next to a source-app row — larger icons are easy to re-derive from
    /// NSWorkspace later if we ever need them.
    public static func pngData(from image: NSImage) -> Data? {
        let targetSize = NSSize(width: 64, height: 64)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        return rep.representation(using: .png, properties: [:])
    }
}
#endif // os(macOS) — FrontmostApp (NSWorkspace/NSImage) is macOS-only
#endif // os(macOS) || os(iOS)
