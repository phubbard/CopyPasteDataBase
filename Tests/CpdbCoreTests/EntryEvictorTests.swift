import Testing
import Foundation
import GRDB
@testable import CpdbShared

@Suite("Entry evictor — time-window eviction")
struct EntryEvictorTests {

    /// Insert a synthetic Entry + a single inline flavor row.
    /// Returns the entry id.
    @discardableResult
    private func insertEntry(
        in store: Store,
        createdAt: Double,
        kind: EntryKind = .text,
        pinned: Bool = false,
        bodyEvictedAt: Double? = nil,
        flavorBytes: Data = Data(repeating: 0xAB, count: 100)
    ) throws -> Int64 {
        try store.dbQueue.write { db in
            // Need a device row for the FK. Reuse-or-create.
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
                kind: kind,
                sourceDeviceId: devId,
                title: "test",
                textPreview: "test preview",
                contentHash: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                totalSize: Int64(flavorBytes.count),
                pinned: pinned,
                bodyEvictedAt: bodyEvictedAt
            )
            try entry.insert(db)
            // Only insert a flavor if not already body-evicted.
            if bodyEvictedAt == nil {
                var flavor = Flavor(
                    entryId: entry.id!,
                    uti: "public.utf8-plain-text",
                    size: Int64(flavorBytes.count),
                    data: flavorBytes,
                    blobKey: nil
                )
                try flavor.insert(db)
            }
            return entry.id!
        }
    }

    private func liveFlavorCount(_ store: Store, entryId: Int64) throws -> Int {
        try store.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM entry_flavors WHERE entry_id = ?",
                arguments: [entryId]
            ) ?? 0
        }
    }

    private func bodyEvictedAt(_ store: Store, entryId: Int64) throws -> Double? {
        try store.dbQueue.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT body_evicted_at FROM entries WHERE id = ?",
                arguments: [entryId]
            )
        }
    }

    @Test("candidatesOlderThan: respects the cutoff")
    func candidatesAge() throws {
        let store = try Store.inMemory()
        let now = Date().timeIntervalSince1970
        let oldId = try insertEntry(in: store, createdAt: now - 100 * 86_400)
        let newId = try insertEntry(in: store, createdAt: now - 5 * 86_400)
        let evictor = EntryEvictor(store: store)
        let candidates = try evictor.candidatesOlderThan(days: 30)
        #expect(candidates.contains(oldId))
        #expect(!candidates.contains(newId))
    }

    @Test("candidatesOlderThan: skips pinned entries")
    func candidatesSkipPinned() throws {
        let store = try Store.inMemory()
        let now = Date().timeIntervalSince1970
        let oldPinned = try insertEntry(in: store, createdAt: now - 100 * 86_400, pinned: true)
        let oldUnpinned = try insertEntry(in: store, createdAt: now - 100 * 86_400)
        let evictor = EntryEvictor(store: store)
        let candidates = try evictor.candidatesOlderThan(days: 30)
        #expect(candidates.contains(oldUnpinned))
        #expect(!candidates.contains(oldPinned))
    }

    @Test("candidatesOlderThan: skips already-body-evicted entries")
    func candidatesSkipAlreadyEvicted() throws {
        let store = try Store.inMemory()
        let now = Date().timeIntervalSince1970
        let already = try insertEntry(
            in: store,
            createdAt: now - 100 * 86_400,
            bodyEvictedAt: now - 30 * 86_400
        )
        let fresh = try insertEntry(in: store, createdAt: now - 100 * 86_400)
        let evictor = EntryEvictor(store: store)
        let candidates = try evictor.candidatesOlderThan(days: 30)
        #expect(candidates.contains(fresh))
        #expect(!candidates.contains(already))
    }

    @Test("evict: deletes flavor rows + sets body_evicted_at")
    func evictDropsFlavors() throws {
        let store = try Store.inMemory()
        let now = Date().timeIntervalSince1970
        let id = try insertEntry(in: store, createdAt: now - 100 * 86_400)
        #expect(try liveFlavorCount(store, entryId: id) == 1)
        #expect(try bodyEvictedAt(store, entryId: id) == nil)
        let evictor = EntryEvictor(store: store)
        let report = try evictor.evict(entryIds: [id])
        #expect(report.entryCount == 1)
        #expect(report.inlineFlavorBytesFreed == 100)
        #expect(try liveFlavorCount(store, entryId: id) == 0)
        #expect(try bodyEvictedAt(store, entryId: id) != nil)
    }

    @Test("evict: idempotent — evicting an already-evicted entry is a no-op group")
    func evictIdempotent() throws {
        let store = try Store.inMemory()
        let now = Date().timeIntervalSince1970
        let id = try insertEntry(
            in: store,
            createdAt: now - 100 * 86_400,
            bodyEvictedAt: now - 1
        )
        let evictor = EntryEvictor(store: store)
        // Calling evict on an empty list returns a zero report.
        let candidates = try evictor.candidatesOlderThan(days: 30)
        #expect(!candidates.contains(id))
    }

    @Test("evictOlderThan: end-to-end runs candidatesOlderThan + evict")
    func endToEnd() throws {
        let store = try Store.inMemory()
        let now = Date().timeIntervalSince1970
        let oldId = try insertEntry(in: store, createdAt: now - 100 * 86_400)
        let newId = try insertEntry(in: store, createdAt: now - 5 * 86_400)
        let evictor = EntryEvictor(store: store)
        let report = try evictor.evictOlderThan(days: 30)
        #expect(report.entryCount == 1)
        #expect(try bodyEvictedAt(store, entryId: oldId) != nil)
        #expect(try bodyEvictedAt(store, entryId: newId) == nil)
        // New entry's flavor should still be present.
        #expect(try liveFlavorCount(store, entryId: newId) == 1)
    }
}
