import Testing
import Foundation
import GRDB
@testable import CpdbCore
@testable import CpdbShared

/// Ingestor behavior under canonical-hash v2 (semantic content identity).
///
/// Pre-v2, same-content captures with jittering sidecar flavors (Chromium
/// tokens, Universal Clipboard re-publication noise) forked the full-flavor
/// hash and were papered over by a 30s text-preview window. Under v2 the
/// sidecars never reach the hash, so those cases are plain primary-dedup
/// hits — and the window is LOG-ONLY (fires a counter, never merges),
/// scheduled for deletion in R2. See docs/canonical-hash-v2.md §3/§7.
@Suite("Ingestor — semantic identity (v2)")
struct IngestorDedupTests {

    /// The observation window still exists (log-only) until R2.
    @Test("Window constant pinned at 30 s until R2 deletes it")
    func windowConstantPinned() {
        #expect(Ingestor.secondaryDedupWindowSeconds == 30.0)
    }

    private func makeStore() throws -> (Store, Ingestor, Int64) {
        let store = try Store.inMemory()
        let ingestor = Ingestor(store: store)
        let dev = try DeviceIdentity.ensureLocalDevice(in: store)
        return (store, ingestor, dev)
    }

    private func snap(_ flavors: [(String, Data)], at: Date) -> PasteboardSnapshot {
        PasteboardSnapshot(
            items: [.init(flavors: flavors.map { .init(uti: $0.0, data: $0.1) })],
            capturedAt: at
        )
    }

    private func liveCount(_ store: Store) throws -> Int {
        try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL") ?? -1
        }
    }

    // MARK: - Sidecar immunity (the v1 failure modes, now plain hash hits)

    @Test("Chromium sidecar jitter: same text, different token bytes → primary-dedup bump")
    func chromiumJitterIsPlainHashHit() throws {
        let (store, ingestor, dev) = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let text = Data("{\n  header_up X-Real-IP {remote_host}\n}".utf8)

        let s1 = snap([("public.utf8-plain-text", text),
                       ("org.chromium.source-url", Data(String(repeating: "x", count: 67).utf8))], at: t0)
        // 19 s later (the production 9807/9808 gap) — AND far beyond any
        // window: 19 days later must behave identically under v2.
        let s2 = snap([("public.utf8-plain-text", text),
                       ("org.chromium.source-url", Data(String(repeating: "x", count: 68).utf8))],
                      at: t0.addingTimeInterval(19))
        let s3 = snap([("public.utf8-plain-text", text),
                       ("org.chromium.internal.source-rfh-token", Data([0xAB]))],
                      at: t0.addingTimeInterval(19 * 86400))

        guard case .inserted = try ingestor.ingest(s1, sourceApp: nil, deviceId: dev) else {
            Issue.record("first should insert"); return
        }
        guard case .bumped = try ingestor.ingest(s2, sourceApp: nil, deviceId: dev) else {
            Issue.record("19s jitter should bump via hash"); return
        }
        guard case .bumped = try ingestor.ingest(s3, sourceApp: nil, deviceId: dev) else {
            Issue.record("19-DAY re-copy should also bump — identity is time-independent"); return
        }
        #expect(try liveCount(store) == 1)
    }

    @Test("Universal Clipboard re-publication (public.text + utf16 + BOM noise) bumps")
    func universalClipboardEchoBumps() throws {
        let (store, ingestor, dev) = try makeStore()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        // Origin Mac capture.
        let origin = snap([("public.utf8-plain-text", Data("hello world".utf8))], at: t0)
        // Receiving-Mac UC echo: adds public.text, a BOM'd utf16 variant,
        // and the is-remote-clipboard marker (now stored, not stripped).
        var utf16 = Data([0xFF, 0xFE])
        for u in "hello world".utf16 { utf16.append(UInt8(u & 0xFF)); utf16.append(UInt8(u >> 8)) }
        let echo = snap([("public.utf8-plain-text", Data("hello world".utf8)),
                         ("public.text", Data("hello world".utf8)),
                         ("public.utf16-external-plain-text", utf16),
                         ("com.apple.is-remote-clipboard", Data())],
                        at: t0.addingTimeInterval(2))
        _ = try ingestor.ingest(origin, sourceApp: nil, deviceId: dev)
        guard case .bumped(let id) = try ingestor.ingest(echo, sourceApp: nil, deviceId: dev) else {
            Issue.record("UC echo must bump, not insert"); return
        }
        #expect(try liveCount(store) == 1)
        // The marker flavor was stored (union), not stripped.
        let utis = try store.dbQueue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT uti FROM entry_flavors WHERE entry_id = ?", arguments: [id]))
        }
        #expect(utis.contains("com.apple.is-remote-clipboard"))
    }

    // MARK: - Union-preserving bump (§3)

    @Test("Echo-text bump preserves RTF and adopts missing HTML; never overwrites")
    func unionBumpPreservesRichFlavors() throws {
        let (store, ingestor, dev) = try makeStore()
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        let rtf = Data("{\\rtf1 rich}".utf8)
        let first = snap([("public.utf8-plain-text", Data("same text".utf8)),
                          ("public.rtf", rtf)], at: t0)
        // Same text from a different route: html instead of rtf, plus a
        // DIFFERENT rtf byte-stream must NOT clobber the stored one.
        let second = snap([("public.utf8-plain-text", Data("same text".utf8)),
                           ("public.rtf", Data("{\\rtf1 other-writer}".utf8)),
                           ("public.html", Data("<p>same text</p>".utf8))],
                          at: t0.addingTimeInterval(60))
        guard case .inserted(let id) = try ingestor.ingest(first, sourceApp: nil, deviceId: dev) else {
            Issue.record("insert expected"); return
        }
        guard case .bumped(let bumpedId) = try ingestor.ingest(second, sourceApp: nil, deviceId: dev),
              bumpedId == id else {
            Issue.record("same-text different-route should bump the same row"); return
        }
        let rows = try store.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT uti, data FROM entry_flavors WHERE entry_id = ? ORDER BY uti", arguments: [id])
        }
        let byUti = Dictionary(uniqueKeysWithValues: rows.map { ($0["uti"] as String, $0["data"] as Data? ?? Data()) })
        #expect(byUti["public.html"] == Data("<p>same text</p>".utf8))   // adopted
        #expect(byUti["public.rtf"] == rtf)                              // first capture's bytes win
        // total_size reflects the union.
        let total = try store.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT total_size FROM entries WHERE id = ?", arguments: [id]) ?? -1
        }
        #expect(total == Int64(byUti.values.reduce(0) { $0 + $1.count }))
    }

    // MARK: - Capture-policy skips (§2.4 / §3)

    @Test("Concealed marker → .skipped, never bumps an existing visible entry")
    func concealedMarkerRejected() throws {
        let (store, ingestor, dev) = try makeStore()
        let t0 = Date(timeIntervalSince1970: 4_000_000)
        _ = try ingestor.ingest(snap([("public.utf8-plain-text", Data("hunter2".utf8))], at: t0),
                                sourceApp: nil, deviceId: dev)
        let createdBefore = try store.dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT created_at FROM entries LIMIT 1") ?? -1
        }
        // Same text, now carrying the concealed marker (password manager).
        let concealed = snap([("public.utf8-plain-text", Data("hunter2".utf8)),
                              ("org.nspasteboard.ConcealedType", Data())],
                             at: t0.addingTimeInterval(5))
        guard case .skipped = try ingestor.ingest(concealed, sourceApp: nil, deviceId: dev) else {
            Issue.record("concealed snapshot must be skipped, not bumped — a bump would sync fleet-wide"); return
        }
        let createdAfter = try store.dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT created_at FROM entries LIMIT 1") ?? -1
        }
        #expect(createdBefore == createdAfter)
        #expect(try liveCount(store) == 1)
    }

    @Test("All-empty snapshot → .skipped")
    func allEmptySkipped() throws {
        let (store, ingestor, dev) = try makeStore()
        let s = snap([("public.utf8-plain-text", Data()), ("public.text", Data())],
                     at: Date(timeIntervalSince1970: 5_000_000))
        guard case .skipped = try ingestor.ingest(s, sourceApp: nil, deviceId: dev) else {
            Issue.record("all-empty must skip"); return
        }
        #expect(try liveCount(store) == 0)
    }

    @Test("Sole shared-pasteboard file echo → .skipped; with image bytes → kept, keys as image")
    func sharedPasteboardEchoHandling() throws {
        let (store, ingestor, dev) = try makeStore()
        let t0 = Date(timeIntervalSince1970: 6_000_000)
        let echoURL = Data(("file:///Users/pfh/Library/Group%20Containers/"
            + "group.com.apple.coreservices.useractivityd/shared-pasteboard/items/ABC-123/photo.png").utf8)

        // Mac-to-Mac Finder-file mirror: file-url only → noise, skip.
        let fileOnly = snap([("public.file-url", echoURL)], at: t0)
        guard case .skipped = try ingestor.ingest(fileOnly, sourceApp: nil, deviceId: dev) else {
            Issue.record("file-only shared-pasteboard mirror must skip"); return
        }

        // iPhone-origin image echo: same file-url BUT substantive PNG bytes
        // — this is the ONLY record of the iPhone copy; must be kept and
        // must key by the image bytes (not the per-transfer echo path).
        let png = Data([0x89, 0x50, 0x4E, 0x47]) + Data(repeating: 0x42, count: 2000)
        let imageEcho = snap([("public.file-url", echoURL), ("public.png", png)],
                             at: t0.addingTimeInterval(1))
        guard case .inserted(let id) = try ingestor.ingest(imageEcho, sourceApp: nil, deviceId: dev) else {
            Issue.record("image-bearing echo must be captured"); return
        }
        let tag = try store.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT identity_tag FROM entries WHERE id = ?", arguments: [id])
        }
        #expect(tag == "image")

        // Same PNG captured directly (no echo path) → same identity → bump.
        let direct = snap([("public.png", png)], at: t0.addingTimeInterval(2))
        guard case .bumped(let bumpedId) = try ingestor.ingest(direct, sourceApp: nil, deviceId: dev),
              bumpedId == id else {
            Issue.record("direct capture of the same image must converge with the echo"); return
        }
    }

    // MARK: - Stamping + the log-only window

    @Test("Inserts stamp hash_version=2 + identity_tag")
    func stampsVersionAndTag() throws {
        let (store, ingestor, dev) = try makeStore()
        _ = try ingestor.ingest(
            snap([("public.utf8-plain-text", Data("https://x.com\n".utf8))],
                 at: Date(timeIntervalSince1970: 7_000_000)),
            sourceApp: nil, deviceId: dev)
        let row = try store.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT hash_version, identity_tag FROM entries LIMIT 1")
        }
        #expect(row?["hash_version"] as Int? == 2)
        // URL-shaped text promotes to the url rung.
        #expect(row?["identity_tag"] as String? == "url")
    }

    @Test("Window fires counter but NEVER merges: v2-distinct same-preview captures both insert")
    func windowIsLogOnly() throws {
        let (store, ingestor, dev) = try makeStore()
        let t0 = Date(timeIntervalSince1970: 8_000_000)
        let before = Ingestor.secondaryWindowFireCount
        // "hello" vs "hello\n": TRIM-equal preview (window probe hits)
        // but different v2 text identity (no outer trim — V5 rejected).
        _ = try ingestor.ingest(snap([("public.utf8-plain-text", Data("hello".utf8))], at: t0),
                                sourceApp: nil, deviceId: dev)
        guard case .inserted = try ingestor.ingest(
            snap([("public.utf8-plain-text", Data("hello\n".utf8))], at: t0.addingTimeInterval(5)),
            sourceApp: nil, deviceId: dev) else {
            Issue.record("v2-distinct capture must INSERT — the window no longer merges"); return
        }
        #expect(try liveCount(store) == 2)
        #expect(Ingestor.secondaryWindowFireCount == before + 1)
    }
}

#if os(macOS)
/// Capture-time file-reference URL resolution (docs §2.4): Finder's
/// `file:///.file/id=…` reference URLs are volatile across machines, so the
/// factory resolves them to path URLs BEFORE storage.
@Suite("PasteboardSnapshot — file-reference URL resolution")
struct FileReferenceResolutionTests {

    @Test("Reference URL resolves to the path form while the file exists")
    func resolvesLiveReference() throws {
        let dir = FileManager.default.temporaryDirectory
        let fileURL = dir.appendingPathComponent("cpdb-ref-test-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // NSURL.fileReferenceURL() auto-bridges to Swift URL, which eagerly
        // resolves the reference back to a path — defeating the test. Go
        // through the ObjC runtime to keep the genuine NSURL.
        guard let ref = (fileURL as NSURL)
            .perform(#selector(NSURL.fileReferenceURL))?
            .takeUnretainedValue() as? NSURL,
            let refString = ref.absoluteString
        else {
            Issue.record("could not obtain a file-reference URL for the fixture"); return
        }
        #expect(refString.hasPrefix("file:///.file/id="))
        let resolved = PasteboardSnapshot.resolveFileReferenceURL(Data(refString.utf8))
        let s = String(decoding: resolved, as: UTF8.self)
        #expect(s.hasPrefix("file:///"))
        #expect(!s.contains("/.file/id="))
        #expect(s.contains("cpdb-ref-test-"))
    }

    @Test("Non-reference URLs and undecodable bytes pass through unchanged")
    func passThrough() {
        let plain = Data("file:///Users/pfh/report.pdf".utf8)
        #expect(PasteboardSnapshot.resolveFileReferenceURL(plain) == plain)
        let garbage = Data([0x80, 0xFF])
        #expect(PasteboardSnapshot.resolveFileReferenceURL(garbage) == garbage)
        // Dead reference (file long gone) keeps original bytes.
        let dead = Data("file:///.file/id=999999999.999999999".utf8)
        #expect(PasteboardSnapshot.resolveFileReferenceURL(dead) == dead)
    }
}
#endif
