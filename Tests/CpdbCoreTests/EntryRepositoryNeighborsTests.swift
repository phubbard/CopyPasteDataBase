import Testing
import Foundation
import GRDB
@testable import CpdbShared

/// Tests for `EntryRepository.neighbors(ofCapturedAt:windowSeconds:)`,
/// the primitive that powers the popup's time-pivot mode (⌘T).
@Suite("Entry repository — neighbors-in-time query")
struct EntryRepositoryNeighborsTests {

    /// Insert a synthetic entry at the given `captured_at`. Returns id.
    /// `kind` defaults to text so the body of the test stays focused
    /// on the time semantics — the query is intentionally
    /// kind-agnostic.
    @discardableResult
    private func insert(
        _ store: Store,
        capturedAt: Double,
        kind: EntryKind = .text,
        deleted: Bool = false,
        textPreview: String? = nil
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
                createdAt: capturedAt,
                capturedAt: capturedAt,
                kind: kind,
                sourceDeviceId: devId,
                title: nil,
                textPreview: textPreview ?? "@\(Int(capturedAt))",
                contentHash: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                totalSize: 4,
                deletedAt: deleted ? Date().timeIntervalSince1970 : nil
            )
            try entry.insert(db)
            return entry.id!
        }
    }

    @Test("Returns entries within ±window, oldest-first")
    func returnsWithinWindowChronological() throws {
        let store = try Store.inMemory()
        // Anchor at t=1000. Place entries at t-200, t-50, t (anchor),
        // t+50, t+200. Window=±100s should return 3 of the 5
        // (t-50, t, t+50), and they must come back in ascending
        // captured_at order so the strip reads left-to-right as time.
        let ids = try [800.0, 950.0, 1000.0, 1050.0, 1200.0].map { try insert(store, capturedAt: $0) }
        let repo = EntryRepository(store: store)
        let rows = try repo.neighbors(ofCapturedAt: 1000.0, windowSeconds: 100)
        #expect(rows.count == 3)
        #expect(rows.map(\.entry.id) == [ids[1], ids[2], ids[3]])
        // Strictly ascending — the contract the strip relies on.
        let times = rows.map(\.entry.capturedAt)
        #expect(times == times.sorted())
    }

    @Test("Window boundaries are inclusive")
    func boundariesInclusive() throws {
        let store = try Store.inMemory()
        // Entries land exactly on the lo and hi boundaries of a
        // ±60s window around t=1000.
        let lo = try insert(store, capturedAt: 940.0)
        let hi = try insert(store, capturedAt: 1060.0)
        // And one inside, one outside on each side.
        _ = try insert(store, capturedAt: 939.999)
        _ = try insert(store, capturedAt: 1060.001)
        let repo = EntryRepository(store: store)
        let rows = try repo.neighbors(ofCapturedAt: 1000.0, windowSeconds: 60)
        let returned = Set(rows.map(\.entry.id))
        #expect(returned.contains(lo))
        #expect(returned.contains(hi))
        #expect(rows.count == 2)
    }

    @Test("Tombstoned entries are excluded")
    func tombstoneFiltered() throws {
        let store = try Store.inMemory()
        let live = try insert(store, capturedAt: 1000.0)
        _ = try insert(store, capturedAt: 1010.0, deleted: true)
        let repo = EntryRepository(store: store)
        let rows = try repo.neighbors(ofCapturedAt: 1000.0, windowSeconds: 30)
        #expect(rows.count == 1)
        #expect(rows.first?.entry.id == live)
    }

    @Test("Kind-agnostic: returns all kinds within the window")
    func kindAgnostic() throws {
        let store = try Store.inMemory()
        // Time-pivot is explicitly kind-agnostic — the point is to
        // surface the *context* around a moment, including images,
        // links, and text together.
        _ = try insert(store, capturedAt: 1000.0, kind: .text)
        _ = try insert(store, capturedAt: 1010.0, kind: .link)
        _ = try insert(store, capturedAt: 1020.0, kind: .image)
        _ = try insert(store, capturedAt: 1030.0, kind: .file)
        let repo = EntryRepository(store: store)
        let rows = try repo.neighbors(ofCapturedAt: 1015.0, windowSeconds: 30)
        #expect(rows.count == 4)
        #expect(Set(rows.map(\.entry.kind)) == [.text, .link, .image, .file])
    }

    @Test("Empty window returns no rows (no crash, no anchor injection)")
    func emptyResult() throws {
        let store = try Store.inMemory()
        _ = try insert(store, capturedAt: 5000.0)
        let repo = EntryRepository(store: store)
        let rows = try repo.neighbors(ofCapturedAt: 1000.0, windowSeconds: 100)
        #expect(rows.isEmpty)
    }

    @Test("`limit` caps the result set")
    func limitRespected() throws {
        let store = try Store.inMemory()
        for i in 0..<20 {
            _ = try insert(store, capturedAt: 1000.0 + Double(i))
        }
        let repo = EntryRepository(store: store)
        let rows = try repo.neighbors(ofCapturedAt: 1000.0, windowSeconds: 100, limit: 5)
        #expect(rows.count == 5)
        // The 5 oldest within the window — the chronological order
        // means narrowing-by-limit naturally clips the most recent
        // tail. That's a known property worth pinning in case a
        // later "drop oldest" change inverts it.
        #expect(rows.map(\.entry.capturedAt) == [1000.0, 1001.0, 1002.0, 1003.0, 1004.0])
    }
}
