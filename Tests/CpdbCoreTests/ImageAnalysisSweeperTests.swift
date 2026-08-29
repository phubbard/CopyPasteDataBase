import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GRDB
@testable import CpdbShared

/// Tests for the image-analysis self-heal path: `EntryRepository`'s
/// candidate-selection queries, `ImageAnalysisSweeper.runOnce`, the
/// giant-image downscale guard in `ImageIndexer`, and the push-queue
/// enqueue that makes analysis results reach other devices.
/// True unless running on a CI runner (GitHub Actions sets `CI=true`
/// automatically). CI runners are virtualized macOS VMs with no ANE and
/// no resident Vision model assets, so any test path that actually
/// reaches `ImageAnalyzer.analyze` (via `ImageIndexer.analyzeAndStore`
/// or `ImageAnalysisSweeper.runOnce`) makes a synchronous
/// `VNImageRequestHandler.perform(...)` call that never returns there —
/// on a real Mac it's near-instant against already-downloaded models,
/// but a fresh CI VM waits forever on a model fetch with no path to
/// complete. Because swift-testing runs the suite concurrently on a
/// small fixed-size cooperative thread pool, that one wedged thread
/// starves every other concurrently scheduled test in the process — the
/// whole run times out instead of just this test failing. Tests that
/// never actually reach Vision (candidate-selection queries, the
/// missing-flavor skip path, the can't-even-downscale-it failure path,
/// pure `downscaledOrNil` ImageIO resizing) are pure logic and stay
/// unconditional. Not a member of the suite below — see
/// `EmbeddingServiceLiveTests.swift`'s comment on why gating helpers are
/// free functions, not static members.
private func notRunningInCI() -> Bool {
    ProcessInfo.processInfo.environment["CI"] == nil
}

@Suite("Image analysis sweep")
struct ImageAnalysisSweeperTests {

    // MARK: - fixtures

    /// A tiny, genuinely-decodable PNG — solid fill, no text. Fast to
    /// generate and enough to exercise the downscale/decode path
    /// without CoreText or a shipped binary fixture.
    private func renderSolidPNG(width: Int = 64, height: Int = 64) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw POSIXError(.EIO) }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else { throw POSIXError(.EIO) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw POSIXError(.EIO) }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw POSIXError(.EIO) }
        return output as Data
    }

    /// Insert a synthetic image entry, optionally with an inline image
    /// flavor (so `loadImageFlavorData` has something to find).
    @discardableResult
    private func insertImageEntry(
        _ store: Store,
        createdAt: Double = 1000,
        deleted: Bool = false,
        bodyEvictedAt: Double? = nil,
        analyzedAt: Double? = nil,
        flavorData: Data? = nil
    ) throws -> Int64 {
        try store.dbQueue.write { db in
            let devId: Int64
            if let existing = try Device.filter(Column("identifier") == "test-device").fetchOne(db) {
                devId = existing.id!
            } else {
                var d = Device(identifier: "test-device", name: "Test", kind: "mac")
                try d.insert(db)
                devId = d.id!
            }
            var entry = Entry(
                uuid: Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
                createdAt: createdAt,
                capturedAt: createdAt,
                kind: .image,
                sourceDeviceId: devId,
                textPreview: nil,
                contentHash: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                totalSize: Int64(flavorData?.count ?? 0),
                deletedAt: deleted ? createdAt : nil,
                analyzedAt: analyzedAt,
                bodyEvictedAt: bodyEvictedAt
            )
            try entry.insert(db)
            if let flavorData {
                var flavor = Flavor(
                    entryId: entry.id!, uti: "public.png",
                    size: Int64(flavorData.count), data: flavorData, blobKey: nil
                )
                try flavor.insert(db)
            }
            return entry.id!
        }
    }

    private func analyzedAt(_ store: Store, _ id: Int64) throws -> Double? {
        try store.dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT analyzed_at FROM entries WHERE id = ?", arguments: [id])
        }
    }

    private func ocrAndTags(_ store: Store, _ id: Int64) throws -> (ocr: String?, tags: String?) {
        try store.dbQueue.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT ocr_text, image_tags FROM entries WHERE id = ?", arguments: [id]
            )
            return (row?["ocr_text"], row?["image_tags"])
        }
    }

    // MARK: - EntryRepository.imagesNeedingAnalysis

    @Test("Picks unanalyzed images newest-first")
    func candidatesNewestFirst() throws {
        let store = try Store.inMemory()
        let older = try insertImageEntry(store, createdAt: 100)
        let newer = try insertImageEntry(store, createdAt: 200)
        let repo = EntryRepository(store: store)
        let candidates = try repo.imagesNeedingAnalysis(limit: 10)
        #expect(candidates == [newer, older])
    }

    @Test("Respects the limit cap")
    func candidatesRespectLimit() throws {
        let store = try Store.inMemory()
        for i in 0..<5 { _ = try insertImageEntry(store, createdAt: Double(i)) }
        let repo = EntryRepository(store: store)
        let candidates = try repo.imagesNeedingAnalysis(limit: 2)
        #expect(candidates.count == 2)
    }

    @Test("Skips deleted, body-evicted, and already-analyzed entries")
    func candidatesSkipIneligible() throws {
        let store = try Store.inMemory()
        let live = try insertImageEntry(store, createdAt: 400)
        _ = try insertImageEntry(store, createdAt: 300, deleted: true)
        _ = try insertImageEntry(store, createdAt: 200, bodyEvictedAt: 200)
        _ = try insertImageEntry(store, createdAt: 100, analyzedAt: 100)
        let repo = EntryRepository(store: store)
        let candidates = try repo.imagesNeedingAnalysis(limit: 10)
        #expect(candidates == [live])
    }

    @Test("isImageUnanalyzed reflects the current sentinel, for the sweeper's re-check")
    func isImageUnanalyzedReflectsSentinel() throws {
        let store = try Store.inMemory()
        let id = try insertImageEntry(store)
        let repo = EntryRepository(store: store)
        #expect(try repo.isImageUnanalyzed(entryId: id) == true)
        // Simulate a sibling Mac's result (or CloudKit pull) landing
        // between candidate-list build and per-entry work.
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE entries SET analyzed_at = ? WHERE id = ?", arguments: [999.0, id])
        }
        #expect(try repo.isImageUnanalyzed(entryId: id) == false)
    }

    @Test("isImageUnanalyzed returns false for a missing/tombstoned entry")
    func isImageUnanalyzedFalseForMissing() throws {
        let store = try Store.inMemory()
        let repo = EntryRepository(store: store)
        #expect(try repo.isImageUnanalyzed(entryId: 999_999) == false)
    }

    // MARK: - ImageAnalysisSweeper.runOnce

    @Test("runOnce analyzes candidates and stamps analyzed_at", .enabled(if: notRunningInCI()))
    func runOnceAnalyzesCandidates() throws {
        let store = try Store.inMemory()
        let png = try renderSolidPNG()
        let id = try insertImageEntry(store, flavorData: png)
        let sweeper = ImageAnalysisSweeper(repository: EntryRepository(store: store))
        let report = try sweeper.runOnce(limit: 10)
        #expect(report.candidates == 1)
        #expect(report.analyzed == 1)
        #expect(try analyzedAt(store, id) != nil)
    }

    @Test("runOnce with no candidates returns an empty report")
    func runOnceEmptyWhenNothingPending() throws {
        let store = try Store.inMemory()
        let sweeper = ImageAnalysisSweeper(repository: EntryRepository(store: store))
        let report = try sweeper.runOnce(limit: 10)
        #expect(report == ImageAnalysisSweeper.Report())
    }

    @Test("runOnce skips (does not mark analyzed) an entry with no image flavor locally yet")
    func runOnceHandlesMissingFlavor() throws {
        // No image flavor locally is the normal shape of a pull-synced
        // entry whose flavor records haven't landed yet (CloudKitSyncer
        // pushes entries and flavors in separate ops). The sweeper must
        // leave `analyzed_at IS NULL` so a later pass retries once the
        // flavor arrives — stamping an empty result here would push a
        // permanent, sync-propagated false negative to every sibling
        // device (this was the critical bug this test used to encode).
        let store = try Store.inMemory()
        let id = try insertImageEntry(store, flavorData: nil)
        let sweeper = ImageAnalysisSweeper(repository: EntryRepository(store: store))
        let report = try sweeper.runOnce(limit: 10)
        #expect(report.analyzed == 0)
        #expect(report.skippedNoFlavor == 1)
        #expect(try analyzedAt(store, id) == nil)
        let queued = try store.dbQueue.read { db in try PushQueue.count(in: db) }
        #expect(queued == 0)
    }

    // MARK: - ImageIndexer: push enqueue

    @Test("analyzeAndStore enqueues a push row in the same write as the analysis", .enabled(if: notRunningInCI()))
    func analyzeAndStoreEnqueuesPush() throws {
        let store = try Store.inMemory()
        let png = try renderSolidPNG()
        let id = try insertImageEntry(store, flavorData: png)
        ImageIndexer.analyzeAndStore(entryId: id, imageData: png, store: store)
        let queued = try store.dbQueue.read { db in try PushQueue.count(in: db) }
        #expect(queued == 1)
        let pending = try store.dbQueue.read { db in try PushQueue.peek(limit: 10, in: db) }
        #expect(pending.first?.entryId == id)
    }

    @Test(
        "analyzeAndStore enqueues a push row even on a Vision failure (empty-result path)",
        .enabled(if: notRunningInCI())
    )
    func analyzeAndStoreEnqueuesPushOnFailure() throws {
        let store = try Store.inMemory()
        let id = try insertImageEntry(store)
        // Empty Data can't be decoded by Vision — exercises the
        // "tried and got nothing" catch path. Still routes through the
        // same synchronous `handler.perform(...)` call as every other
        // live-ML test here (the decode failure surfaces from inside
        // that call, not before it), so it's gated the same way.
        ImageIndexer.analyzeAndStore(entryId: id, imageData: Data(), store: store)
        #expect(try analyzedAt(store, id) != nil)
        let queued = try store.dbQueue.read { db in try PushQueue.count(in: db) }
        #expect(queued == 1)
    }

    // MARK: - Giant-image guard

    @Test("Giant image over threshold is downscaled and still analyzed", .enabled(if: notRunningInCI()))
    func giantImageDownscalesSuccessfully() throws {
        let store = try Store.inMemory()
        let png = try renderSolidPNG(width: 512, height: 512)
        let id = try insertImageEntry(store, flavorData: png)
        // Inject a tiny threshold so this ordinary test PNG takes the
        // "giant" path without needing a real 48 MB fixture.
        ImageIndexer.analyzeAndStore(
            entryId: id,
            imageData: png,
            store: store,
            giantImageThresholdBytes: 16,
            maxPixelDimension: 32
        )
        #expect(try analyzedAt(store, id) != nil)
        let queued = try store.dbQueue.read { db in try PushQueue.count(in: db) }
        #expect(queued == 1)
    }

    @Test("Giant blob that can't be decoded at all marks analyzed-empty instead of hanging forever")
    func giantImageDownscaleFailureMarksEmpty() throws {
        let store = try Store.inMemory()
        // Not a real image — no recognizable header — but bigger than
        // the injected threshold, so it takes the downscale branch,
        // which must fail closed (mark analyzed-empty) rather than
        // leave the entry permanently pending.
        let junk = Data(repeating: 0xAB, count: 64)
        let id = try insertImageEntry(store, flavorData: junk)
        ImageIndexer.analyzeAndStore(
            entryId: id,
            imageData: junk,
            store: store,
            giantImageThresholdBytes: 16,
            maxPixelDimension: 32
        )
        #expect(try analyzedAt(store, id) != nil)
        let (ocr, tags) = try ocrAndTags(store, id)
        #expect(ocr == "")
        #expect(tags == "")
        let queued = try store.dbQueue.read { db in try PushQueue.count(in: db) }
        #expect(queued == 1)
    }

    @Test("downscaledOrNil returns a smaller, still-decodable image for a valid source")
    func downscaledOrNilShrinksValidImage() throws {
        let png = try renderSolidPNG(width: 512, height: 512)
        let downscaled = try #require(ImageIndexer.downscaledOrNil(png, maxPixelDimension: 32))
        guard let source = CGImageSourceCreateWithData(downscaled as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            Issue.record("downscaled data should itself be decodable")
            return
        }
        #expect(cgImage.width <= 32)
        #expect(cgImage.height <= 32)
    }

    @Test("downscaledOrNil returns nil for undecodable data")
    func downscaledOrNilFailsForJunk() {
        let junk = Data(repeating: 0xFF, count: 64)
        #expect(ImageIndexer.downscaledOrNil(junk, maxPixelDimension: 32) == nil)
    }
}
