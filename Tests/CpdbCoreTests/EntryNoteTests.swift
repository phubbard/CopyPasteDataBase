import Testing
import Foundation
import GRDB
@testable import CpdbShared

/// Local-side behavior of the user's sticky note (schema v15):
/// `EntryRepository.setNote` / `note(id:)`, FTS participation and match
/// attribution, the embedding lifecycle, and that no other FTS re-index
/// path drops a note. Wire/sync semantics live in `EntryNoteSyncTests`.
@Suite("Entry sticky notes")
struct EntryNoteTests {

    private func store() throws -> (Store, Int64) {
        let s = try Store.inMemory()
        let dev = try s.dbQueue.write { db -> Int64 in
            var d = Device(identifier: "dev", name: "Dev", kind: "mac"); try d.insert(db); return d.id!
        }
        return (s, dev)
    }

    @discardableResult
    private func insert(
        _ store: Store, dev: Int64, hash: UInt8, kind: EntryKind = .text,
        textPreview: String? = "body", modifiedAt: Double = 100, deletedAt: Double? = nil,
        note: String? = nil
    ) throws -> Int64 {
        try store.dbQueue.write { db in
            var e = Entry(
                uuid: Data(repeating: hash, count: 16), createdAt: 100, capturedAt: 100,
                kind: kind, sourceDeviceId: dev, textPreview: textPreview,
                contentHash: Data(repeating: hash, count: 32), totalSize: 1,
                deletedAt: deletedAt, hashVersion: 2, identityTag: "text",
                modifiedAt: modifiedAt, note: note
            )
            try e.insert(db)
            if deletedAt == nil {
                try FtsIndex.indexEntry(
                    db: db, entryId: e.id!, title: nil, text: textPreview, appName: nil, note: note)
            }
            return e.id!
        }
    }

    private func row(_ store: Store, _ id: Int64) throws -> Row {
        try #require(try store.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM entries WHERE id = ?", arguments: [id])
        })
    }

    private func queued(_ store: Store) throws -> Int {
        try store.dbQueue.read { db in try PushQueue.count(in: db) }
    }

    private func search(_ store: Store, _ query: String) throws -> [FtsIndex.Hit] {
        try store.dbQueue.read { db in try FtsIndex.search(db: db, query: query) }
    }

    private func saveEmbedding(_ store: Store, _ id: Int64) throws {
        try store.dbQueue.write { db in
            try EntryRepository.saveEmbedding(
                entryId: id, modelId: "nl-v1", revision: 1, dims: 1, vector: Data([1]), in: db)
        }
    }

    // MARK: - setNote / note(id:)

    @Test("setNote round-trips through note(id:) and the Entry record")
    func setNoteRoundTrips() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 1)
        let repo = EntryRepository(store: store)
        #expect(try repo.note(id: id) == nil)

        try repo.setNote(id: id, note: "pay by Friday")
        #expect(try repo.note(id: id) == "pay by Friday")
        #expect(try repo.fetch(id: id)?.note == "pay by Friday")

        try repo.setNote(id: id, note: "paid")
        #expect(try repo.note(id: id) == "paid")
    }

    @Test("non-blank text is stored verbatim, surrounding whitespace included")
    func setNoteStoresVerbatim() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 2)
        let repo = EntryRepository(store: store)
        try repo.setNote(id: id, note: "  two\nlines  \n")
        #expect(try repo.note(id: id) == "  two\nlines  \n")
    }

    @Test("setNote bumps modified_at (user data, like pin)")
    func setNoteBumpsModifiedAt() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 3, modifiedAt: 100)
        let before = Date().timeIntervalSince1970
        try EntryRepository(store: store).setNote(id: id, note: "x")
        #expect(try row(store, id)["modified_at"] as Double >= before)
    }

    @Test("setNote enqueues exactly one push row, however many edits coalesce")
    func setNoteEnqueuesOnePush() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 4)
        let repo = EntryRepository(store: store)
        #expect(try queued(store) == 0)

        try repo.setNote(id: id, note: "first")
        #expect(try queued(store) == 1)
        try repo.setNote(id: id, note: "second")
        #expect(try queued(store) == 1)
        let queuedId = try store.dbQueue.read { db in try Int64.fetchOne(db, sql: "SELECT entry_id FROM cloudkit_push_queue") }
        #expect(queuedId == id)
    }

    @Test("setNote deletes the entry's embedding so the sweep re-embeds it")
    func setNoteClearsEmbedding() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 5)
        try saveEmbedding(store, id)
        let repo = EntryRepository(store: store)
        #expect(try repo.embedding(entryId: id) != nil)

        try repo.setNote(id: id, note: "now with a note")
        #expect(try repo.embedding(entryId: id) == nil)
        #expect(try repo.entriesNeedingEmbedding(modelId: "nl-v1", revision: 1, limit: 10).contains(id))
    }

    @Test("blank input (nil, empty, whitespace-only) normalizes to NULL and clears the note")
    func blankNoteNormalizesToNull() throws {
        let (store, dev) = try store()
        let repo = EntryRepository(store: store)
        for (i, blank) in [nil, "", "   ", " \n\t "].enumerated() {
            let id = try insert(store, dev: dev, hash: UInt8(10 + i), note: "to be cleared")
            try repo.setNote(id: id, note: blank)
            #expect(try repo.note(id: id) == nil)
            // NULL, never "" — the wire encoding is the mapper's job.
            #expect(try row(store, id)["note"] as String? == nil)
            #expect(try search(store, "cleared").isEmpty)
        }
    }

    @Test("clearing bumps modified_at, enqueues a push, and drops the embedding like any other edit")
    func clearIsAFullEdit() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 20, modifiedAt: 100, note: "old")
        try saveEmbedding(store, id)
        let repo = EntryRepository(store: store)
        try repo.setNote(id: id, note: "   ")
        #expect(try queued(store) == 1)
        #expect(try repo.embedding(entryId: id) == nil)
        #expect(try row(store, id)["modified_at"] as Double > 100)
    }

    @Test("writing the note the row already has is a no-op: no bump, no push, embedding kept")
    func unchangedNoteIsNoOp() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 21, modifiedAt: 100, note: "same")
        try saveEmbedding(store, id)
        let repo = EntryRepository(store: store)

        try repo.setNote(id: id, note: "same")
        #expect(try row(store, id)["modified_at"] as Double == 100)
        #expect(try queued(store) == 0)
        #expect(try repo.embedding(entryId: id) != nil)

        // Clearing an already-absent note is likewise a no-op.
        let bare = try insert(store, dev: dev, hash: 22, modifiedAt: 100)
        try repo.setNote(id: bare, note: nil)
        #expect(try row(store, bare)["modified_at"] as Double == 100)
        #expect(try queued(store) == 0)
    }

    @Test("a tombstoned entry's note can't be edited")
    func tombstonedEntryIsUntouched() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 23, deletedAt: 150)
        let repo = EntryRepository(store: store)
        try repo.setNote(id: id, note: "ghost")
        #expect(try row(store, id)["note"] as String? == nil)
        #expect(try queued(store) == 0)
        #expect(try repo.note(id: id) == nil)
    }

    @Test("note(id:) hides the note of a tombstoned entry")
    func noteReaderHonoursTombstones() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 24, note: "visible while live")
        let repo = EntryRepository(store: store)
        #expect(try repo.note(id: id) == "visible while live")
        try repo.tombstone(id: id)
        #expect(try repo.note(id: id) == nil)
        // …but the column survives, so an undo brings it back.
        try repo.restore(id: id)
        #expect(try repo.note(id: id) == "visible while live")
    }

    // MARK: - Search

    @Test("FTS finds an entry by a keyword that appears only in its note")
    func ftsFindsNoteByKeyword() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 30, kind: .image, textPreview: nil)
        try EntryRepository(store: store).setNote(id: id, note: "receipt for the Lisbon trip")

        let hit = try #require(try search(store, "lisbon").first { $0.entryId == id })
        #expect(hit.source == .note)
        // Prefix matching applies to notes like every other column.
        #expect(try search(store, "lisb").contains { $0.entryId == id })
    }

    @Test("setNote rewrites the FTS row without dropping the entry's other columns")
    func setNoteKeepsOtherFtsColumns() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 31, textPreview: "quarterly budget")
        let repo = EntryRepository(store: store)
        try repo.setNote(id: id, note: "ask finance")
        #expect(try search(store, "budget").contains { $0.entryId == id })
        #expect(try search(store, "finance").contains { $0.entryId == id })
        // Replacing the note retires the old words.
        try repo.setNote(id: id, note: "approved")
        #expect(try search(store, "finance").isEmpty)
        #expect(try search(store, "approved").contains { $0.entryId == id })
        #expect(try search(store, "budget").contains { $0.entryId == id })
    }

    // MARK: - Other re-index paths must not drop the note

    @Test("a fetched link title doesn't drop the note from search")
    func linkMetadataKeepsNote() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 40, kind: .link, textPreview: "https://example.com")
        let repo = EntryRepository(store: store)
        try repo.setNote(id: id, note: "read on the train")
        try repo.setLinkMetadata(entryId: id, title: "Example Domain")
        #expect(try search(store, "train").contains { $0.entryId == id })
        #expect(try search(store, "domain").contains { $0.entryId == id })
    }

    @Test("tombstone then restore keeps the note searchable")
    func restoreKeepsNote() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 41)
        let repo = EntryRepository(store: store)
        try repo.setNote(id: id, note: "keepsake")
        try repo.tombstone(id: id)
        #expect(try search(store, "keepsake").isEmpty)
        try repo.restore(id: id)
        #expect(try search(store, "keepsake").contains { $0.entryId == id })
    }

    // MARK: - Coalesce

    @Test("EntryCoalesce adopts a donor's note only when the survivor has none")
    func coalesceAdoptsNoteIntoBareSurvivor() throws {
        let (store, dev) = try store()
        let survivor = try insert(store, dev: dev, hash: 50)
        let loser = try insert(store, dev: dev, hash: 51, modifiedAt: 200, note: "from the duplicate")
        try saveEmbedding(store, survivor)
        try store.dbQueue.write { db in
            try EntryCoalesce.merge(db: db, survivorId: survivor, loserIds: [loser], now: 300)
        }
        let repo = EntryRepository(store: store)
        #expect(try repo.note(id: survivor) == "from the duplicate")
        #expect(try search(store, "duplicate").contains { $0.entryId == survivor })
        #expect(try repo.embedding(entryId: survivor) == nil)
    }

    @Test("EntryCoalesce never overwrites a survivor's own note")
    func coalesceKeepsSurvivorNote() throws {
        let (store, dev) = try store()
        let survivor = try insert(store, dev: dev, hash: 52, note: "mine")
        let loser = try insert(store, dev: dev, hash: 53, modifiedAt: 999, note: "theirs")
        try saveEmbedding(store, survivor)
        try store.dbQueue.write { db in
            try EntryCoalesce.merge(db: db, survivorId: survivor, loserIds: [loser], now: 300)
        }
        let repo = EntryRepository(store: store)
        #expect(try repo.note(id: survivor) == "mine")
        #expect(try search(store, "mine").contains { $0.entryId == survivor })
        #expect(try repo.embedding(entryId: survivor) != nil)
    }

    // MARK: - Embedding input

    @Test("EmbeddingService.inputText appends the note to the preview, dropping blank parts")
    func embeddingInputText() {
        #expect(EmbeddingService.inputText(textPreview: "body", note: nil) == "body")
        #expect(EmbeddingService.inputText(textPreview: "body", note: "  ") == "body")
        #expect(EmbeddingService.inputText(textPreview: "body", note: "a note") == "body\n\na note")
        // An annotated screenshot has no preview: the note is the input.
        #expect(EmbeddingService.inputText(textPreview: nil, note: "a note") == "a note")
        #expect(EmbeddingService.inputText(textPreview: "  ", note: "a note") == "a note")
        #expect(EmbeddingService.inputText(textPreview: nil, note: nil) == nil)
        #expect(EmbeddingService.inputText(textPreview: " \n", note: "") == nil)
    }

    @Test("a noted entry of any kind is an embedding candidate; clearing the note withdraws it")
    func notedImageIsEmbeddingCandidate() throws {
        let (store, dev) = try store()
        let image = try insert(store, dev: dev, hash: 60, kind: .image, textPreview: nil)
        let bareImage = try insert(store, dev: dev, hash: 61, kind: .image, textPreview: nil)
        let repo = EntryRepository(store: store)
        func candidates() throws -> Set<Int64> {
            Set(try repo.entriesNeedingEmbedding(modelId: "nl-v1", revision: 1, limit: 10))
        }
        #expect(try candidates().isEmpty)

        try repo.setNote(id: image, note: "whiteboard from the kickoff")
        #expect(try candidates() == [image])
        #expect(!(try candidates()).contains(bareImage))

        try repo.setNote(id: image, note: nil)
        #expect(try candidates().isEmpty)
    }

    @Test("a noted tombstone is not an embedding candidate")
    func notedTombstoneIsNotCandidate() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 62, kind: .image, textPreview: nil, note: "gone")
        try EntryRepository(store: store).tombstone(id: id)
        #expect(try EntryRepository(store: store).entriesNeedingEmbedding(modelId: "nl-v1", revision: 1, limit: 10).isEmpty)
    }
}
