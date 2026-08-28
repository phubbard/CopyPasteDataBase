import Testing
import Foundation
import GRDB
@testable import CpdbShared

/// Tests for `EntryRepository.liveEntries(sinceId:kinds:limit:)` — the
/// paging primitive `SpotlightDonationService`'s catch-up sweep walks
/// so a large history isn't permanently capped at whatever fit in a
/// single fixed-size, pinned-first `recent()` fetch.
@Suite("Entry repository — liveEntries paging query")
struct EntryRepositoryLiveEntriesTests {

    @discardableResult
    private func insert(
        _ store: Store,
        kind: EntryKind = .text,
        pinned: Bool = false,
        deleted: Bool = false
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
            let t = Date().timeIntervalSince1970
            var entry = Entry(
                uuid: Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
                createdAt: t,
                capturedAt: t,
                kind: kind,
                sourceDeviceId: devId,
                textPreview: "row",
                contentHash: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                totalSize: 4,
                deletedAt: deleted ? t : nil,
                pinned: pinned
            )
            try entry.insert(db)
            return entry.id!
        }
    }

    @Test("Ascending id order, ignoring pin status")
    func ascendingIgnoresPinned() throws {
        let store = try Store.inMemory()
        // A pinned row lands first chronologically but must NOT sort
        // ahead of later unpinned rows — unlike `recent()`'s default,
        // there's no "pinned-first" concept for a donation walk.
        let a = try insert(store, pinned: true)
        let b = try insert(store)
        let c = try insert(store)
        let repo = EntryRepository(store: store)
        let rows = try repo.liveEntries(sinceId: 0, kinds: [.text], limit: 10)
        #expect(rows.map(\.entry.id) == [a, b, c])
    }

    @Test("sinceId excludes everything at or before the cursor")
    func sinceIdCursors() throws {
        let store = try Store.inMemory()
        let a = try insert(store)
        let b = try insert(store)
        let c = try insert(store)
        let repo = EntryRepository(store: store)
        let rows = try repo.liveEntries(sinceId: a, kinds: [.text], limit: 10)
        #expect(rows.map(\.entry.id) == [b, c])
    }

    @Test("limit caps the page so a caller can advance the cursor and page again")
    func limitCapsPage() throws {
        let store = try Store.inMemory()
        let ids = try (0..<5).map { _ in try insert(store) }
        let repo = EntryRepository(store: store)
        let firstPage = try repo.liveEntries(sinceId: 0, kinds: [.text], limit: 2)
        #expect(firstPage.map(\.entry.id) == [ids[0], ids[1]])
        let secondPage = try repo.liveEntries(sinceId: firstPage.last!.entry.id!, kinds: [.text], limit: 2)
        #expect(secondPage.map(\.entry.id) == [ids[2], ids[3]])
    }

    @Test("Excludes tombstoned rows and kinds outside the filter")
    func excludesDeletedAndOtherKinds() throws {
        let store = try Store.inMemory()
        let text = try insert(store, kind: .text)
        try insert(store, kind: .image)
        try insert(store, kind: .text, deleted: true)
        let repo = EntryRepository(store: store)
        let rows = try repo.liveEntries(sinceId: 0, kinds: [.text], limit: 10)
        #expect(rows.map(\.entry.id) == [text])
    }

    @Test("Empty kinds set returns nothing rather than matching everything")
    func emptyKindsReturnsEmpty() throws {
        let store = try Store.inMemory()
        try insert(store)
        let repo = EntryRepository(store: store)
        let rows = try repo.liveEntries(sinceId: 0, kinds: [], limit: 10)
        #expect(rows.isEmpty)
    }
}
