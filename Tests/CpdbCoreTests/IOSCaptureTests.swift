import Testing
import Foundation
import GRDB
@testable import CpdbCore
@testable import CpdbShared

/// Tests for the iOS clipboard-capture path.
///
/// The iOS-specific factory (`PasteboardSnapshot.makeSnapshot`) and the
/// `IOSClipboardCapture` controller are `#if os(iOS)`, so the parts of
/// these tests that touch them are likewise iOS-guarded — they run when
/// the iOS test bundle is built (Xcode / xcodebuild). The
/// platform-neutral assertions (hash convergence, `TransientGuard`, the
/// shared ingest-entry-point rejection) run on the macOS `swift test`
/// host too, because that's where they have the most value: they prove an
/// iOS-shaped capture dedups against a Mac capture of the same content.
@Suite("iOS clipboard capture")
struct IOSCaptureTests {

    // MARK: - Hash convergence (cross-platform: the whole point)

    /// An iOS capture of a plain string and a Mac capture of the same
    /// string must produce the *same* `content_hash`, so two devices that
    /// copy identical text converge on one entry. We model the iOS shape
    /// (the exact UTI the iOS factory emits) and the Mac shape and assert
    /// the canonical hashes match.
    @Test("iOS text shape hashes identically to Mac text shape")
    func textHashConverges() {
        let text = "the quick brown fox"
        // iOS factory emits public.utf8-plain-text (UTF-8, no BOM).
        let iosItem = [CanonicalHash.Flavor(uti: "public.utf8-plain-text",
                                            data: Data(text.utf8))]
        // A Mac plain-text copy publishes the same UTI + bytes.
        let macItem = [CanonicalHash.Flavor(uti: "public.utf8-plain-text",
                                            data: Data(text.utf8))]
        #expect(CanonicalHash.hash(items: [iosItem]) ==
                CanonicalHash.hash(items: [macItem]))
    }

    /// A URL copied on iOS (emitted as `public.url`) hashes identically to
    /// the same URL copied on a Mac via `public.url`. This is the
    /// cross-device convergence hash-v2 §5.5 is built around.
    @Test("iOS url shape hashes identically to Mac url shape")
    func urlHashConverges() {
        let url = "https://example.com/path?q=1"
        let ios = [CanonicalHash.Flavor(uti: "public.url", data: Data(url.utf8))]
        let mac = [CanonicalHash.Flavor(uti: "public.url", data: Data(url.utf8))]
        #expect(CanonicalHash.hash(items: [ios]) == CanonicalHash.hash(items: [mac]))
    }

    // MARK: - TransientGuard (cross-platform)

    @Test("TransientGuard rejects a concealed-marker snapshot")
    func transientGuardRejects() {
        let snap = PasteboardSnapshot(items: [
            .init(flavors: [
                .init(uti: "public.utf8-plain-text", data: Data("secret".utf8)),
                .init(uti: "org.nspasteboard.ConcealedType", data: Data()),
            ])
        ])
        #expect(TransientGuard.shouldReject(snap) == true)
    }

    @Test("TransientGuard passes ordinary text")
    func transientGuardPasses() {
        let snap = PasteboardSnapshot(items: [
            .init(flavors: [.init(uti: "public.utf8-plain-text", data: Data("hi".utf8))])
        ])
        #expect(TransientGuard.shouldReject(snap) == false)
    }

    /// The guard is enforced at the *ingest entry point*, so a concealed
    /// snapshot is skipped before any row is written — for every capture
    /// path, iOS included.
    @Test("Ingestor entry point skips concealed snapshots")
    func ingestRejectsConcealed() throws {
        let store = try Store.inMemory()
        let ingestor = Ingestor(store: store)
        let dev = try DeviceIdentity.ensureLocalDevice(in: store)
        let snap = PasteboardSnapshot(items: [
            .init(flavors: [
                .init(uti: "public.utf8-plain-text", data: Data("hunter2".utf8)),
                .init(uti: "org.nspasteboard.ConcealedType", data: Data()),
            ])
        ])
        let outcome = try ingestor.ingest(snap, sourceApp: .iosClipboard, deviceId: dev)
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected skip, got \(outcome)"); return
        }
        #expect(reason.contains("concealed"))
        let count = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries") ?? -1
        }
        #expect(count == 0)
    }

    /// An iOS-attributed capture lands as a normal entry and, captured
    /// again within the window with the SAME bytes, dedups to one row —
    /// proving iOS rides the same primary content-hash dedup the Mac uses.
    @Test("iOS-attributed capture inserts then dedups by content hash")
    func iosCaptureDedups() throws {
        let store = try Store.inMemory()
        let ingestor = Ingestor(store: store)
        let dev = try DeviceIdentity.ensureLocalDevice(in: store)
        let t0 = Date(timeIntervalSince1970: 5_000_000)
        let snap = PasteboardSnapshot(
            items: [.init(flavors: [
                .init(uti: "public.utf8-plain-text", data: Data("converge me".utf8)),
            ])],
            capturedAt: t0
        )
        let r1 = try ingestor.ingest(snap, sourceApp: .iosClipboard, deviceId: dev)
        guard case .inserted = r1 else { Issue.record("expected insert, got \(r1)"); return }
        // Same content again → identical content_hash → bump, not a 2nd row.
        let r2 = try ingestor.ingest(snap, sourceApp: .iosClipboard, deviceId: dev)
        guard case .bumped = r2 else { Issue.record("expected bump, got \(r2)"); return }
        let count = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL") ?? -1
        }
        #expect(count == 1)
    }

    #if os(iOS)
    // MARK: - iOS factory mapping (iOS-only — needs the UIKit-target file)

    @Test("makeSnapshot: text only → one utf8 flavor")
    func mapTextOnly() {
        let snap = PasteboardSnapshot.makeSnapshot(urlString: nil, text: "hello")
        #expect(snap != nil)
        let utis = snap!.items.flatMap { $0.flavors.map(\.uti) }
        #expect(utis == ["public.utf8-plain-text"])
        #expect(snap!.plainText == "hello")
    }

    @Test("makeSnapshot: url only → one public.url flavor")
    func mapUrlOnly() {
        let snap = PasteboardSnapshot.makeSnapshot(urlString: "https://a.example", text: nil)
        #expect(snap != nil)
        let utis = snap!.items.flatMap { $0.flavors.map(\.uti) }
        #expect(utis == ["public.url"])
    }

    @Test("makeSnapshot: url == text collapses to a single url flavor")
    func mapUrlEqualsText() {
        let u = "https://a.example"
        let snap = PasteboardSnapshot.makeSnapshot(urlString: u, text: u)
        #expect(snap != nil)
        let utis = snap!.items.flatMap { $0.flavors.map(\.uti) }
        #expect(utis == ["public.url"]) // text dropped because it equals the url
    }

    @Test("makeSnapshot: distinct url + text → both flavors, url first")
    func mapUrlAndText() {
        let snap = PasteboardSnapshot.makeSnapshot(
            urlString: "https://a.example", text: "see this link"
        )
        #expect(snap != nil)
        let utis = snap!.items.flatMap { $0.flavors.map(\.uti) }
        #expect(utis == ["public.url", "public.utf8-plain-text"])
    }

    @Test("makeSnapshot: empty / whitespace → nil")
    func mapEmpty() {
        #expect(PasteboardSnapshot.makeSnapshot(urlString: nil, text: nil) == nil)
        #expect(PasteboardSnapshot.makeSnapshot(urlString: "", text: "   ") == nil)
    }

    @Test("IOSClipboardCapture.isPushable distinguishes writes from skips")
    func pushableClassification() {
        #expect(IOSClipboardCapture.isPushable(.inserted(1)) == true)
        #expect(IOSClipboardCapture.isPushable(.bumped(1)) == true)
        #expect(IOSClipboardCapture.isPushable(.skipped(reason: "x")) == false)
    }
    #endif
}
