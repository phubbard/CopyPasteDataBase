#if os(macOS)
import Testing
import Foundation
import AppKit
import SwiftUI
import GRDB
@testable import CpdbApp
@testable import CpdbShared

/// Renders the REAL popup view tree offscreen at the shipped panel size
/// and measures the first card's rendered pixel geometry.
///
/// `PopupGeometryContractTests` only checks the arithmetic behind
/// `PopupController.panelHeight` — it can't catch a bug in how SwiftUI
/// actually lays the strip out inside that height. This suite is the
/// one that reproduces the v3.2.3 "clipped card" regression (the
/// horizontal ScrollView vertically centered its too-tall content and
/// guillotined ~29pt off the top and bottom of every card) and the
/// v3.2.4 "ghost text" regression (a no-op `rows` reassignment mid-
/// LazyHStack-materialization painted text fragments above the strip).
@Suite("Popup rendered-layout — card geometry & content")
@MainActor
struct PopupRenderedLayoutTests {

    // MARK: - Fixture

    private func makeStore() throws -> Store {
        let store = try Store.inMemory()
        let devId = try store.dbQueue.write { db -> Int64 in
            var d = Device(identifier: "d", name: "D", kind: "mac")
            try d.insert(db)
            return d.id!
        }
        // Multi-line text_preview: a distinctive first line for the
        // headline check, plus short body lines that stay well clear
        // of `scanColumnPoint` (see below) so they can't fragment the
        // near-white run the height measurement relies on.
        let text = "HEADLINE SENTINEL\nb1\nb2\nb3\nb4"
        _ = try store.dbQueue.write { db -> Int64 in
            var e = Entry(
                uuid: Data(repeating: 1, count: 16), createdAt: 1, capturedAt: 1,
                kind: .text, sourceDeviceId: devId, textPreview: text,
                contentHash: Data(repeating: 1, count: 32), totalSize: Int64(text.utf8.count)
            )
            try e.insert(db)
            var f = Flavor(
                entryId: e.id!, uti: "public.utf8-plain-text",
                size: Int64(text.utf8.count), data: Data(text.utf8), blobKey: nil
            )
            try f.insert(db)
            return e.id!
        }
        return store
    }

    // MARK: - Offscreen render

    /// Panel width used for the render. Wide enough that the first
    /// card's x offset (leading strip padding + card 0) matches a real
    /// summon; the exact value doesn't matter since we only ever look
    /// at the first card.
    private static let renderWidth: CGFloat = 900

    private struct Rendered {
        let bitmap: NSBitmapImageRep
        let scaleX: CGFloat
        let scaleY: CGFloat
    }

    private enum RenderError: Error { case noBitmap }

    private func render(store: Store) throws -> Rendered {
        let state = PopupState(store: store)
        state.refresh()
        #expect(state.rows.count == 1)
        // Deselect: EntryCard draws a 3pt accentColor selection stroke
        // around the selected card, which eats into the near-white
        // edge pixels this test measures (confirmed empirically: it
        // shifts the measured height by several points). Selection
        // chrome isn't what this test is checking. Setting the index
        // out of `rows`' bounds means no card renders as selected —
        // `PopupState.selectedEntry` already guards against an
        // out-of-range index, so this is safe.
        state.selectedIndex = -1

        let hosting = NSHostingView(
            rootView: PopupRootView(state: state, onPaste: {})
                .environment(\.cpdbStore, store)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: Self.renderWidth, height: PopupController.panelHeight)
        // Pin light appearance so the "near-white" pixel thresholds
        // below hold regardless of the host machine's system setting.
        hosting.appearance = NSAppearance(named: .aqua)

        // SwiftUI needs the hosting view to actually be in a window for
        // its layout engine to run a real pass. A borderless window
        // that's immediately ordered out never becomes visible on
        // screen.
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderOut(nil)
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            Issue.record("Failed to allocate an offscreen bitmap for the popup render")
            throw RenderError.noBitmap
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        // The bitmap can come back at Retina (2x) resolution even
        // though nothing here requested it explicitly — measure the
        // actual ratio rather than assuming 1x or 2x.
        let scaleX = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / hosting.bounds.height
        return Rendered(bitmap: bitmap, scaleX: scaleX, scaleY: scaleY)
    }

    // MARK: - Pixel helpers

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 1 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    /// Above this luminance a pixel reads as the card's (or the panel
    /// chrome's) near-white fill in light mode.
    private static let nearWhiteLuminance: CGFloat = 0.92
    /// Below this luminance a pixel reads as rendered text/glyph ink.
    private static let darkTextLuminance: CGFloat = 0.5

    /// x-coordinate (view points) of the vertical scan column used to
    /// measure the first card's height. 170pt = 16pt leading strip
    /// padding + ~154pt into the 320pt-wide card: safely past the end
    /// of "HEADLINE SENTINEL" and the short body lines seeded above
    /// (confirmed empirically — the near-white run below is
    /// uninterrupted end to end), so the column never crosses rendered
    /// text and the run it measures is purely the card's background.
    private static let scanColumnPoint: CGFloat = 170

    /// The card's known x-span: 16pt leading strip padding to
    /// +`EntryCard.cardSize.width` (320). The headline/ghost bands stay
    /// a few points inside this so antialiasing at the rounded-rect
    /// edge and the strip's own leading padding don't leak in.
    private static let cardXRange: ClosedRange<CGFloat> = 20...332

    /// Longest contiguous run of near-white pixels in the column at
    /// `columnPx` — i.e. the first card's visible background. It's the
    /// only element in the strip that reads as uninterrupted near-white
    /// for anywhere close to `EntryCard.cardSize.height` worth of
    /// pixels, so the longest run is an unambiguous stand-in for "where
    /// the card is and how tall it rendered."
    private func longestNearWhiteRun(bitmap: NSBitmapImageRep, columnPx: Int) -> (startPx: Int, lengthPx: Int) {
        var bestStart = 0, bestLen = 0
        var curStart = 0, curLen = 0
        for y in 0..<bitmap.pixelsHigh {
            let isNearWhite = bitmap.colorAt(x: columnPx, y: y)
                .map { Self.luminance($0) > Self.nearWhiteLuminance } ?? false
            if isNearWhite {
                if curLen == 0 { curStart = y }
                curLen += 1
                if curLen > bestLen { bestLen = curLen; bestStart = curStart }
            } else {
                curLen = 0
            }
        }
        return (bestStart, bestLen)
    }

    /// Minimum luminance found in a view-point rectangle. Used by the
    /// headline-presence and no-ghost-content checks below — both only
    /// care whether ANY dark (text) pixel exists in a region, not
    /// where exactly.
    private func minLuminance(
        bitmap: NSBitmapImageRep, scaleX: CGFloat, scaleY: CGFloat,
        xRange: ClosedRange<CGFloat>, yRange: ClosedRange<CGFloat>
    ) -> CGFloat {
        var minLum: CGFloat = 1
        var xP = xRange.lowerBound
        while xP <= xRange.upperBound {
            var yP = yRange.lowerBound
            while yP <= yRange.upperBound {
                let px = Int(xP * scaleX)
                let py = Int(yP * scaleY)
                if px >= 0, px < bitmap.pixelsWide, py >= 0, py < bitmap.pixelsHigh,
                   let color = bitmap.colorAt(x: px, y: py)
                {
                    minLum = min(minLum, Self.luminance(color))
                }
                yP += 1
            }
            xP += 4
        }
        return minLum
    }

    // MARK: - Tests

    @Test("First card renders at its full cardSize.height (v3.2.3 clipping regression)")
    func cardRendersFullHeight() throws {
        let store = try makeStore()
        let rendered = try render(store: store)
        let columnPx = Int(Self.scanColumnPoint * rendered.scaleX)
        let run = longestNearWhiteRun(bitmap: rendered.bitmap, columnPx: columnPx)
        let heightPt = CGFloat(run.lengthPx) / rendered.scaleY

        // The threshold crossing at the card's antialiased top/bottom
        // edge systematically undercounts by ~1pt per edge (measured:
        // 358pt for a 360pt card at the shipped panelHeight=480) — a
        // fixed artifact of thresholding an antialiased boundary, not
        // measurement noise. 2pt of slack absorbs exactly that and
        // nothing more: the v3.2.3 regression clipped ~29pt off *each*
        // edge (58pt total), so it fails this assertion by well over an
        // order of magnitude more than this tolerance allows.
        #expect(
            abs(heightPt - EntryCard.cardSize.height) <= 2.0,
            "measured card height \(heightPt)pt vs expected \(EntryCard.cardSize.height)pt (run started at pixel \(run.startPx), length \(run.lengthPx)px)"
        )
    }

    @Test("Headline text is visible near the top of the card")
    func headlineIsVisible() throws {
        let store = try makeStore()
        let rendered = try render(store: store)
        let columnPx = Int(Self.scanColumnPoint * rendered.scaleX)
        let run = longestNearWhiteRun(bitmap: rendered.bitmap, columnPx: columnPx)
        let cardTopPt = CGFloat(run.startPx) / rendered.scaleY

        let minLum = minLuminance(
            bitmap: rendered.bitmap, scaleX: rendered.scaleX, scaleY: rendered.scaleY,
            xRange: Self.cardXRange, yRange: cardTopPt...(cardTopPt + 60)
        )
        // A guillotined or fully mispositioned headline yields no dark
        // pixels in this band at all — that's the failure this catches.
        #expect(
            minLum < Self.darkTextLuminance,
            "no dark headline pixels found in the card's top 60pt (min luminance \(minLum))"
        )
    }

    @Test("No ghost text renders above the card's top edge (v3.2.4 LazyHStack regression)")
    func noGhostContentAboveCard() throws {
        let store = try makeStore()
        let rendered = try render(store: store)
        let columnPx = Int(Self.scanColumnPoint * rendered.scaleX)
        let run = longestNearWhiteRun(bitmap: rendered.bitmap, columnPx: columnPx)
        let cardTopPt = CGFloat(run.startPx) / rendered.scaleY

        let minLum = minLuminance(
            bitmap: rendered.bitmap, scaleX: rendered.scaleX, scaleY: rendered.scaleY,
            xRange: Self.cardXRange, yRange: (cardTopPt - 10)...cardTopPt
        )
        // The v3.2.4 bug painted stray text fragments in exactly this
        // band — the strip's top padding, directly above the card.
        #expect(
            minLum >= Self.darkTextLuminance,
            "found dark pixels in the strip's top-padding band above the card (min luminance \(minLum)) — looks like ghost text"
        )
    }
}
#endif
