import Testing
import Foundation
import GRDB
@testable import CpdbCore
@testable import CpdbShared

/// Tests for `Ingestor`'s secondary text-preview dedup — the
/// safety net that catches duplicates when the same logical
/// content gets written to the pasteboard twice with a slightly
/// different flavor set (Chrome jitter, Xcode console rewrite, etc.).
///
/// The primary dedup is content_hash unique index — these tests
/// exercise what happens when that misses (different hash) but
/// the human-visible content is the same.
@Suite("Ingestor — secondary text-preview dedup")
struct IngestorDedupTests {

    /// The behaviour contract. If you change this value, audit the
    /// rationale block in `Ingestor.doIngest` and update CHANGELOG.
    @Test("Window is 30 s (the post-audit value)")
    func windowConstantPinned() {
        #expect(Ingestor.secondaryDedupWindowSeconds == 30.0)
    }

    /// Build a minimal text snapshot with a unique content_hash.
    /// Different `noise` values → different canonical hash, even
    /// for identical plain text — that's exactly the failure mode
    /// the secondary dedup exists to catch.
    private func snapshot(
        plain: String,
        capturedAt: Date,
        noise: UInt8 = 0
    ) -> PasteboardSnapshot {
        let item = PasteboardSnapshot.Item(
            flavors: [
                CanonicalHash.Flavor(uti: "public.utf8-plain-text", data: Data(plain.utf8)),
                // Simulates Chrome's jittery internal token UTI — same
                // content, hash flips with a single different byte.
                CanonicalHash.Flavor(uti: "org.chromium.internal.source-rfh-token", data: Data([noise])),
            ]
        )
        return PasteboardSnapshot(items: [item], capturedAt: capturedAt)
    }

    /// End-to-end: two captures within 30 s with same plain text but
    /// different content_hash → second is BUMPED, not inserted.
    @Test("Within window: same text, diff hash → bump")
    func bumpsWithinWindow() throws {
        let store = try Store.inMemory()
        let ingestor = Ingestor(store: store)
        let dev = try DeviceIdentity.ensureLocalDevice(in: store)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let s1 = snapshot(plain: "hello world", capturedAt: t0, noise: 0)
        let s2 = snapshot(plain: "hello world", capturedAt: t0.addingTimeInterval(15), noise: 1)
        let r1 = try ingestor.ingest(s1, sourceApp: nil, deviceId: dev)
        let r2 = try ingestor.ingest(s2, sourceApp: nil, deviceId: dev)
        guard case .inserted = r1 else { Issue.record("expected first to insert"); return }
        guard case .bumped = r2 else { Issue.record("expected second to bump (got \(r2))"); return }
        // And we have exactly one live entry afterwards.
        let count = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL") ?? -1
        }
        #expect(count == 1)
    }

    /// Beyond the 30 s window the secondary dedup correctly steps
    /// aside — two genuine entries.
    @Test("Beyond window: same text, diff hash → insert")
    func insertsBeyondWindow() throws {
        let store = try Store.inMemory()
        let ingestor = Ingestor(store: store)
        let dev = try DeviceIdentity.ensureLocalDevice(in: store)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let s1 = snapshot(plain: "hello world", capturedAt: t0, noise: 0)
        // 31 s later — outside the 30 s window by design.
        let s2 = snapshot(plain: "hello world", capturedAt: t0.addingTimeInterval(31), noise: 1)
        _ = try ingestor.ingest(s1, sourceApp: nil, deviceId: dev)
        let r2 = try ingestor.ingest(s2, sourceApp: nil, deviceId: dev)
        guard case .inserted = r2 else { Issue.record("expected second to insert (got \(r2))"); return }
        let count = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL") ?? -1
        }
        #expect(count == 2)
    }

    /// The exact Chrome / Chromium pattern that motivated widening
    /// the window in v2.10.1: same text+HTML, only the `source-url`
    /// length differs by one byte. Should bump.
    @Test("Chromium source-url 1-byte jitter is caught")
    func chromiumSourceUrlJitter() throws {
        let store = try Store.inMemory()
        let ingestor = Ingestor(store: store)
        let dev = try DeviceIdentity.ensureLocalDevice(in: store)
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        let plain = "{\n  header_up X-Real-IP {remote_host}\n}"
        let html = "<pre>\(plain)</pre>"

        func chromeSnap(_ urlLen: Int, at: Date) -> PasteboardSnapshot {
            let item = PasteboardSnapshot.Item(flavors: [
                CanonicalHash.Flavor(uti: "public.utf8-plain-text", data: Data(plain.utf8)),
                CanonicalHash.Flavor(uti: "public.html", data: Data(html.utf8)),
                // The volatile UTI — different byte-length between captures.
                CanonicalHash.Flavor(uti: "org.chromium.source-url",
                                     data: Data(String(repeating: "x", count: urlLen).utf8)),
            ])
            return PasteboardSnapshot(items: [item], capturedAt: at)
        }

        // 19 s apart — the exact gap from the production 9807/9808
        // pair that exposed this bug.
        _ = try ingestor.ingest(chromeSnap(67, at: t0), sourceApp: nil, deviceId: dev)
        let second = try ingestor.ingest(chromeSnap(68, at: t0.addingTimeInterval(19)),
                                         sourceApp: nil, deviceId: dev)
        guard case .bumped = second else { Issue.record("Chrome jitter dupe slipped through: \(second)"); return }
    }
}
