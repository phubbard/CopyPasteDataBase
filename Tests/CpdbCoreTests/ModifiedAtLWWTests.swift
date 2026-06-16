import Testing
import Foundation
import CloudKit
import GRDB
@testable import CpdbShared

/// Tests for `modified_at` last-writer-wins on the pull path — the
/// correctness foundation for reversible delete/pin. The old
/// "tombstone always wins" guard permanently blocked undo-of-delete from
/// propagating; LWW by modified_at fixes that and makes concurrent
/// pin/unpin races converge.
@Suite("modified_at last-writer-wins (undo sync)")
struct ModifiedAtLWWTests {

    private func store() throws -> (Store, Int64) {
        let s = try Store.inMemory()
        let dev = try s.dbQueue.write { db -> Int64 in
            var d = Device(identifier: "dev", name: "Dev", kind: "mac"); try d.insert(db); return d.id!
        }
        return (s, dev)
    }

    @discardableResult
    private func insert(_ store: Store, dev: Int64, hash: UInt8, modifiedAt: Double,
                        deleted: Double? = nil, pinned: Bool = false) throws -> Int64 {
        try store.dbQueue.write { db in
            var e = Entry(uuid: Data(repeating: hash, count: 16), createdAt: 100, capturedAt: 100,
                          kind: .text, sourceDeviceId: dev, textPreview: "body",
                          contentHash: Data(repeating: hash, count: 32), totalSize: 1,
                          deletedAt: deleted, pinned: pinned, hashVersion: 2, identityTag: "text",
                          modifiedAt: modifiedAt)
            try e.insert(db)
            if deleted == nil {
                try FtsIndex.indexEntry(db: db, entryId: e.id!, title: nil, text: "body", appName: nil)
            }
            return e.id!
        }
    }

    /// A decoded record for the SAME content as a local row (same hash).
    private func decoded(hash: UInt8, modifiedAt: Double, deleted: Double? = nil, pinned: Bool = false)
        -> EntryRecordMapper.Decoded {
        EntryRecordMapper.Decoded(
            uuid: Data(repeating: hash, count: 16), createdAt: 100, capturedAt: 100,
            kind: .text, textPreview: "body", contentHash: Data(repeating: hash, count: 32),
            totalSize: 1, deletedAt: deleted,
            source: .init(deviceIdentifier: "remote", deviceName: "Remote"),
            pinned: pinned, hashVersion: 2, identityTag: "text", modifiedAt: modifiedAt)
    }

    private func applyPull(_ store: Store, dev: Int64, _ d: EntryRecordMapper.Decoded) throws -> CloudKitSyncer.UpsertOutcome {
        try store.dbQueue.write { db in
            try CloudKitSyncer.upsert(decoded: d, in: db, fallbackDeviceID: "dev", fallbackDeviceName: "Dev")
        }
    }

    private func row(_ store: Store, _ id: Int64) throws -> Row? {
        try store.dbQueue.read { db in try Row.fetchOne(db, sql: "SELECT * FROM entries WHERE id = ?", arguments: [id]) }
    }
    private func ftsCount(_ store: Store, _ id: Int64) throws -> Int {
        try store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries_fts WHERE rowid = ?", arguments: [id]) ?? -1 }
    }

    // MARK: - The headline: undo-of-delete propagates

    @Test("Undo-of-delete propagates: a newer un-delete beats a local tombstone")
    func undoDeletePropagates() throws {
        let (store, dev) = try store()
        // Local device has the row TOMBSTONED at t=200 (a delete that synced).
        let id = try insert(store, dev: dev, hash: 1, modifiedAt: 200, deleted: 200)
        #expect(try ftsCount(store, id) == 0)   // tombstoned → not in FTS

        // The origin device UNDID the delete at t=300 (newer) → live record.
        let outcome = try applyPull(store, dev: dev, decoded(hash: 1, modifiedAt: 300, deleted: nil))
        #expect(outcome == .updated)
        // Under the OLD "tombstone wins" guard this stayed deleted. Now it restores.
        #expect(try row(store, id)?["deleted_at"] as Double? == nil)
        #expect(try row(store, id)?["modified_at"] as Double? == 300)
        #expect(try ftsCount(store, id) == 1)   // live again → searchable
    }

    @Test("Stale live record does NOT resurrect a newer local delete")
    func staleLiveLosesToNewerDelete() throws {
        let (store, dev) = try store()
        // Local deleted at t=300 (newer).
        let id = try insert(store, dev: dev, hash: 2, modifiedAt: 300, deleted: 300)
        // An OLDER live record (t=200, e.g. pre-delete state still on the wire) arrives.
        _ = try applyPull(store, dev: dev, decoded(hash: 2, modifiedAt: 200, deleted: nil))
        // Local delete wins — the row stays tombstoned (this is what the old
        // guard protected, now done correctly via recency).
        #expect((try row(store, id)?["deleted_at"] as Double?) != nil)
        #expect(try ftsCount(store, id) == 0)
    }

    @Test("Inbound delete that wins drops a live local row from search")
    func inboundDeleteWins() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 3, modifiedAt: 100, deleted: nil)
        #expect(try ftsCount(store, id) == 1)
        _ = try applyPull(store, dev: dev, decoded(hash: 3, modifiedAt: 250, deleted: 250))
        #expect((try row(store, id)?["deleted_at"] as Double?) != nil)
        #expect(try ftsCount(store, id) == 0)
    }

    // MARK: - Pin LWW

    @Test("Concurrent pin/unpin: newer wins, both directions")
    func pinLWW() throws {
        // Remote newer → adopt remote's pin state.
        do {
            let (store, dev) = try store()
            let id = try insert(store, dev: dev, hash: 4, modifiedAt: 100, pinned: true)
            _ = try applyPull(store, dev: dev, decoded(hash: 4, modifiedAt: 200, pinned: false))
            #expect((try row(store, id)?["pinned"] as Int64? ?? -1) == 0)
            #expect(try row(store, id)?["modified_at"] as Double? == 200)
        }
        // Local newer → keep local pin state.
        do {
            let (store, dev) = try store()
            let id = try insert(store, dev: dev, hash: 5, modifiedAt: 300, pinned: true)
            _ = try applyPull(store, dev: dev, decoded(hash: 5, modifiedAt: 200, pinned: false))
            #expect((try row(store, id)?["pinned"] as Int64? ?? -1) == 1)   // local wins
            #expect(try row(store, id)?["modified_at"] as Double? == 300)
        }
    }

    // MARK: - Repository restore round-trip

    @Test("repo.tombstone then repo.restore brings the row back + re-indexes FTS")
    func restoreRoundTrip() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 6, modifiedAt: 100)
        let repo = EntryRepository(store: store)
        try repo.tombstone(id: id)
        #expect((try row(store, id)?["deleted_at"] as Double?) != nil)
        #expect(try ftsCount(store, id) == 0)
        let afterDelete = try #require(try row(store, id)?["modified_at"] as Double?)

        try repo.restore(id: id)
        #expect(try row(store, id)?["deleted_at"] as Double? == nil)
        #expect(try ftsCount(store, id) == 1)          // searchable again
        let afterRestore = try #require(try row(store, id)?["modified_at"] as Double?)
        #expect(afterRestore >= afterDelete)            // restore bumped modified_at past the delete
        // Both delete and restore enqueued for push.
        let queued = try store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloudkit_push_queue WHERE entry_id = ?", arguments: [id]) ?? 0 }
        #expect(queued == 1)
    }

    @Test("setPinned bumps modified_at; pinnedState reads it back")
    func pinBumpsModifiedAt() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 7, modifiedAt: 100, pinned: false)
        let repo = EntryRepository(store: store)
        #expect(try repo.pinnedState(id: id) == false)
        try repo.setPinned(id: id, pinned: true)
        #expect(try repo.pinnedState(id: id) == true)
        #expect((try row(store, id)?["modified_at"] as Double? ?? 0) > 100)
    }
}
