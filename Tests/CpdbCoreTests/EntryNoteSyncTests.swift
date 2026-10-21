import Testing
import Foundation
import CloudKit
import GRDB
@testable import CpdbShared

/// The CloudKit wire contract for the user's sticky note (schema v15).
///
/// Absent and empty-string mean DIFFERENT things on the wire:
///   - ABSENT  → the sender predates notes. Preserve the local note even
///               when that record wins last-writer-wins on `modified_at`
///               (otherwise a pin toggled on a not-yet-updated iPhone
///               silently wipes notes — the historical OCR-empty-overwrite
///               failure class);
///   - ""      → deliberate clear. Clear the local note.
/// Locally no-note is NULL; the mapper translates at the boundary.
@Suite("Sticky note wire semantics")
struct EntryNoteSyncTests {

    private static let zone = CKRecordZone.ID(zoneName: CKSchema.zoneName, ownerName: CKCurrentUserDefaultName)

    // MARK: - Mapper

    private func entry(note: String?) -> Entry {
        Entry(
            uuid: Data(repeating: 1, count: 16), createdAt: 100, capturedAt: 100, kind: .text,
            sourceDeviceId: 1, textPreview: "body", contentHash: Data(repeating: 2, count: 32),
            totalSize: 1, hashVersion: 2, identityTag: "text", modifiedAt: 100, note: note)
    }

    private func record(for entry: Entry) -> CKRecord {
        let id = EntryRecordMapper.recordID(forContentHash: entry.contentHash, in: Self.zone)
        let record = CKRecord(recordType: CKSchema.RecordType.entry, recordID: id)
        EntryRecordMapper.populate(
            record: record, entry: entry,
            source: .init(deviceIdentifier: "HW", deviceName: "Mac"))
        return record
    }

    @Test("round-trip: note text survives the wire trip")
    func noteRoundTrip() throws {
        let decoded = try EntryRecordMapper.decode(record(for: entry(note: "pay by Friday\nsecond line")))
        #expect(decoded.note == "pay by Friday\nsecond line")
    }

    @Test("a local NULL note ships as an explicit empty string, not an absent field")
    func nilNoteEncodesAsEmptyString() throws {
        let rec = record(for: entry(note: nil))
        #expect(rec[CKSchema.EntryField.note] as? String == "")
        #expect(try EntryRecordMapper.decode(rec).note == "")
    }

    @Test("decode: a pre-v15 record (no note field) decodes as nil, distinct from \"\"")
    func absentNoteDecodesNil() throws {
        let rec = record(for: entry(note: "gone from the wire"))
        rec[CKSchema.EntryField.note] = nil   // what a not-yet-updated sender's record looks like
        let decoded = try EntryRecordMapper.decode(rec)
        #expect(decoded.note == nil)
        #expect(decoded.note != "")
    }

    // MARK: - Pull: existing-row branch

    private func store() throws -> (Store, Int64) {
        let s = try Store.inMemory()
        let dev = try s.dbQueue.write { db -> Int64 in
            var d = Device(identifier: "dev", name: "Dev", kind: "mac"); try d.insert(db); return d.id!
        }
        return (s, dev)
    }

    @discardableResult
    private func insertLocal(
        _ store: Store, dev: Int64, hash: UInt8, modifiedAt: Double, note: String?,
        pinned: Bool = false, embedded: Bool = false
    ) throws -> Int64 {
        try store.dbQueue.write { db in
            var e = Entry(
                uuid: Data(repeating: hash, count: 16), createdAt: 100, capturedAt: 100,
                kind: .text, sourceDeviceId: dev, textPreview: "body",
                contentHash: Data(repeating: hash, count: 32), totalSize: 1, pinned: pinned,
                hashVersion: 2, identityTag: "text", modifiedAt: modifiedAt, note: note)
            try e.insert(db)
            try FtsIndex.indexEntry(db: db, entryId: e.id!, title: nil, text: "body", appName: nil, note: note)
            if embedded {
                try EntryRepository.saveEmbedding(
                    entryId: e.id!, modelId: "nl-v1", revision: 1, dims: 1, vector: Data([1]), in: db)
            }
            return e.id!
        }
    }

    /// A pulled record for the same content as `insertLocal(hash:)`.
    /// `note: nil` is the ABSENT wire field; `""` is the explicit clear.
    private func decoded(
        hash: UInt8, modifiedAt: Double, note: String?, pinned: Bool = false
    ) -> EntryRecordMapper.Decoded {
        EntryRecordMapper.Decoded(
            uuid: Data(repeating: hash, count: 16), createdAt: 100, capturedAt: 100,
            kind: .text, textPreview: "body", contentHash: Data(repeating: hash, count: 32),
            totalSize: 1, source: .init(deviceIdentifier: "remote", deviceName: "Remote"),
            pinned: pinned, hashVersion: 2, identityTag: "text", modifiedAt: modifiedAt, note: note)
    }

    private func applyPull(_ store: Store, _ d: EntryRecordMapper.Decoded) throws -> CloudKitSyncer.UpsertOutcome {
        try store.dbQueue.write { db in
            try CloudKitSyncer.upsert(decoded: d, in: db, fallbackDeviceID: "dev", fallbackDeviceName: "Dev")
        }
    }

    private func row(_ store: Store, _ id: Int64) throws -> Row {
        try #require(try store.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM entries WHERE id = ?", arguments: [id])
        })
    }

    private func ftsFinds(_ store: Store, _ query: String, _ id: Int64) throws -> Bool {
        try store.dbQueue.read { db in try FtsIndex.search(db: db, query: query).contains { $0.entryId == id } }
    }

    private func queued(_ store: Store, _ id: Int64) throws -> Bool {
        try store.dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cloudkit_push_queue WHERE entry_id = ?)", arguments: [id]) ?? false
        }
    }

    @Test("ABSENT note field: a winning remote record applies its pin but PRESERVES the local note")
    func absentNotePreservedWhenRemoteWins() throws {
        let (store, dev) = try store()
        let id = try insertLocal(store, dev: dev, hash: 1, modifiedAt: 100, note: "keep me", embedded: true)

        // A not-yet-updated iPhone toggled the pin: newer modified_at, no note field.
        _ = try applyPull(store, decoded(hash: 1, modifiedAt: 200, note: nil, pinned: true))

        let r = try row(store, id)
        #expect(r["pinned"] as Int64 == 1)              // the remote won…
        #expect(r["modified_at"] as Double == 200)
        #expect(r["note"] as String? == "keep me")      // …but the note survived
        #expect(try ftsFinds(store, "keep", id))
        #expect(try EntryRepository(store: store).embedding(entryId: id) != nil)
    }

    @Test("ABSENT note field with a surviving local note re-enqueues a push to restore it on the server")
    func absentNoteTriggersRepush() throws {
        let (store, dev) = try store()
        let withNote = try insertLocal(store, dev: dev, hash: 2, modifiedAt: 100, note: "heal")
        let bare = try insertLocal(store, dev: dev, hash: 3, modifiedAt: 100, note: nil)
        _ = try applyPull(store, decoded(hash: 2, modifiedAt: 200, note: nil))
        _ = try applyPull(store, decoded(hash: 3, modifiedAt: 200, note: nil))
        // A pre-notes push overwrote the server record without the field,
        // so only the row that actually holds a note has anything to restore.
        #expect(try queued(store, withNote))
        #expect(!(try queued(store, bare)))
    }

    @Test("EMPTY note field: a winning remote record clears the local note, its search entry, and its embedding")
    func emptyNoteClearsWhenRemoteWins() throws {
        let (store, dev) = try store()
        let id = try insertLocal(store, dev: dev, hash: 4, modifiedAt: 100, note: "delete me", embedded: true)

        _ = try applyPull(store, decoded(hash: 4, modifiedAt: 200, note: ""))

        let r = try row(store, id)
        #expect(r["note"] as String? == nil)            // NULL locally, never ""
        #expect(!(try ftsFinds(store, "delete", id)))
        #expect(try EntryRepository(store: store).embedding(entryId: id) == nil)
        #expect(!(try queued(store, id)))               // a deliberate clear isn't re-pushed back
    }

    @Test("a winning remote note replaces the local one and invalidates the stale embedding")
    func remoteNoteReplacesLocal() throws {
        let (store, dev) = try store()
        let id = try insertLocal(store, dev: dev, hash: 5, modifiedAt: 100, note: "old words", embedded: true)

        _ = try applyPull(store, decoded(hash: 5, modifiedAt: 200, note: "fresh words"))

        #expect(try row(store, id)["note"] as String? == "fresh words")
        #expect(try ftsFinds(store, "fresh", id))
        #expect(!(try ftsFinds(store, "old", id)))
        #expect(try EntryRepository(store: store).embedding(entryId: id) == nil)
    }

    @Test("an identical remote note leaves the embedding alone")
    func unchangedRemoteNoteKeepsEmbedding() throws {
        let (store, dev) = try store()
        let id = try insertLocal(store, dev: dev, hash: 6, modifiedAt: 100, note: "same", embedded: true)
        _ = try applyPull(store, decoded(hash: 6, modifiedAt: 200, note: "same"))
        #expect(try EntryRepository(store: store).embedding(entryId: id) != nil)
    }

    @Test("a blank remote note (whitespace-only) is treated as a clear, never stored")
    func blankRemoteNoteClears() throws {
        let (store, dev) = try store()
        let id = try insertLocal(store, dev: dev, hash: 7, modifiedAt: 100, note: "x")
        _ = try applyPull(store, decoded(hash: 7, modifiedAt: 200, note: "  \n"))
        #expect(try row(store, id)["note"] as String? == nil)
    }

    @Test("last-writer-wins: an OLDER remote record can neither set nor clear a newer local note")
    func localNewerKeepsNote() throws {
        for remoteNote in ["stale remote note", ""] {
            let (store, dev) = try store()
            let id = try insertLocal(store, dev: dev, hash: 8, modifiedAt: 300, note: "mine, newer", embedded: true)
            _ = try applyPull(store, decoded(hash: 8, modifiedAt: 200, note: remoteNote))
            #expect(try row(store, id)["note"] as String? == "mine, newer")
            #expect(try row(store, id)["modified_at"] as Double == 300)
            #expect(try ftsFinds(store, "newer", id))
            #expect(try EntryRepository(store: store).embedding(entryId: id) != nil)
        }
    }

    @Test("a modified_at tie goes to the remote, like every other mutable field")
    func tieGoesToRemote() throws {
        let (store, dev) = try store()
        let id = try insertLocal(store, dev: dev, hash: 9, modifiedAt: 200, note: "local")
        _ = try applyPull(store, decoded(hash: 9, modifiedAt: 200, note: "remote"))
        #expect(try row(store, id)["note"] as String? == "remote")
    }

    @Test("a local row with no note adopts a winning remote note")
    func bareLocalAdoptsRemoteNote() throws {
        let (store, dev) = try store()
        let id = try insertLocal(store, dev: dev, hash: 10, modifiedAt: 100, note: nil)
        _ = try applyPull(store, decoded(hash: 10, modifiedAt: 200, note: "from another Mac"))
        #expect(try row(store, id)["note"] as String? == "from another Mac")
        #expect(try ftsFinds(store, "another", id))
    }

    @Test("a tombstoned local row keeps its note across an undo that wins")
    func undoDeleteKeepsPreservedNote() throws {
        let (store, dev) = try store()
        let id = try store.dbQueue.write { db -> Int64 in
            var e = Entry(
                uuid: Data(repeating: 11, count: 16), createdAt: 100, capturedAt: 100, kind: .text,
                sourceDeviceId: dev, textPreview: "body", contentHash: Data(repeating: 11, count: 32),
                totalSize: 1, deletedAt: 150, hashVersion: 2, identityTag: "text", modifiedAt: 150,
                note: "survives the delete")
            try e.insert(db)
            return e.id!
        }
        // A not-yet-updated device undoes the delete: live record, newer, no note field.
        _ = try applyPull(store, decoded(hash: 11, modifiedAt: 250, note: nil))
        #expect(try row(store, id)["deleted_at"] as Double? == nil)
        #expect(try row(store, id)["note"] as String? == "survives the delete")
        #expect(try ftsFinds(store, "survives", id))
    }

    // MARK: - Pull: insert branch

    @Test("a never-seen entry inserts with its note; \"\" and absent both mean none")
    func insertBranch() throws {
        let (store, _) = try store()
        for (hash, wire, expected) in [
            (UInt8(20), "hello there" as String?, "hello there" as String?),
            (UInt8(21), "", nil),
            (UInt8(22), nil, nil),
        ] {
            #expect(try applyPull(store, decoded(hash: hash, modifiedAt: 100, note: wire)) == .inserted)
            let id = try #require(try store.dbQueue.read { db in
                try Int64.fetchOne(db, sql: "SELECT id FROM entries WHERE content_hash = ?", arguments: [Data(repeating: hash, count: 32)])
            })
            #expect(try row(store, id)["note"] as String? == expected)
            #expect(try ftsFinds(store, "hello", id) == (expected != nil))
        }
    }

    // MARK: - Pull: uuid-conflict branch

    private func resolveConflict(
        _ store: Store, dev: Int64, localId: Int64, note: String?
    ) throws -> CloudKitSyncer.UpsertOutcome {
        // Local is a v1 straggler; the remote is the same uuid at v2 and wins by version.
        let d = EntryRecordMapper.Decoded(
            uuid: Data(repeating: 30, count: 16), createdAt: 200, capturedAt: 200, kind: .text,
            textPreview: "body", contentHash: Data(repeating: 0x77, count: 32), totalSize: 1,
            source: .init(deviceIdentifier: "remote", deviceName: "Remote"),
            hashVersion: 2, identityTag: "text", note: note)
        return try store.dbQueue.write { db in
            let local = try Entry.fetchOne(db, key: localId)!
            return try CloudKitSyncer.resolveUuidConflict(
                decoded: d, local: local, appId: nil, devId: dev, blobs: BlobStore(), in: db)
        }
    }

    private func insertStraggler(_ store: Store, dev: Int64, note: String?) throws -> Int64 {
        try store.dbQueue.write { db in
            var e = Entry(
                uuid: Data(repeating: 30, count: 16), createdAt: 100, capturedAt: 100, kind: .text,
                sourceDeviceId: dev, textPreview: "body", contentHash: Data(repeating: 0x66, count: 32),
                totalSize: 1, hashVersion: 1, note: note)
            try e.insert(db)
            try FtsIndex.indexEntry(db: db, entryId: e.id!, title: nil, text: "body", appName: nil, note: note)
            return e.id!
        }
    }

    @Test("uuid-conflict re-key never clears or overwrites a local note — it can only adopt one")
    func uuidConflictOnlyAdoptsNotes() throws {
        // Local has a note: a remote "" or different text must not touch it.
        for remote in [nil, "", "other text"] as [String?] {
            let (store, dev) = try store()
            let id = try insertStraggler(store, dev: dev, note: "local note")
            #expect(try resolveConflict(store, dev: dev, localId: id, note: remote) == .updated)
            #expect(try row(store, id)["note"] as String? == "local note")
            #expect(try ftsFinds(store, "local", id))
        }
        // Local has none: a real remote note is adopted, an empty/absent one is not.
        do {
            let (store, dev) = try store()
            let id = try insertStraggler(store, dev: dev, note: nil)
            _ = try resolveConflict(store, dev: dev, localId: id, note: "adopted")
            #expect(try row(store, id)["note"] as String? == "adopted")
            #expect(try ftsFinds(store, "adopted", id))
        }
        do {
            let (store, dev) = try store()
            let id = try insertStraggler(store, dev: dev, note: nil)
            _ = try resolveConflict(store, dev: dev, localId: id, note: "")
            #expect(try row(store, id)["note"] as String? == nil)
        }
    }

    // MARK: - Pure resolution

    @Test("resolvedNote: absent keeps local, empty clears, text replaces")
    func resolvedNoteTable() {
        #expect(CloudKitSyncer.resolvedNote(local: "kept", remote: nil) == "kept")
        #expect(CloudKitSyncer.resolvedNote(local: nil, remote: nil) == nil)
        #expect(CloudKitSyncer.resolvedNote(local: "gone", remote: "") == nil)
        #expect(CloudKitSyncer.resolvedNote(local: "gone", remote: "  ") == nil)
        #expect(CloudKitSyncer.resolvedNote(local: nil, remote: "new") == "new")
        #expect(CloudKitSyncer.resolvedNote(local: "old", remote: "new") == "new")
    }
}
