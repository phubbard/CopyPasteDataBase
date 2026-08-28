import Testing
import Foundation
import GRDB
@testable import CpdbShared

/// Round-trip tests for the v12 semantic-enrichment repository
/// accessors: `saveEmbedding`/`embedding`/`entriesNeedingEmbedding`,
/// `setChips`, and `setAITitleSummary`.
@Suite("Semantic enrichment (v12 schema) repository accessors")
struct SemanticEnrichmentTests {

    /// Insert a bare entry of the given kind. Returns id.
    private func insertEntry(
        in store: Store,
        kind: EntryKind,
        deletedAt: Double? = nil,
        modifiedAt: Double = 1_000
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
                createdAt: Date().timeIntervalSince1970,
                capturedAt: Date().timeIntervalSince1970,
                kind: kind,
                sourceDeviceId: devId,
                title: nil,
                textPreview: "some text",
                contentHash: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                totalSize: 10,
                deletedAt: deletedAt,
                modifiedAt: modifiedAt
            )
            try entry.insert(db)
            return entry.id!
        }
    }

    private func modifiedAt(_ store: Store, _ id: Int64) throws -> Double {
        try store.dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT modified_at FROM entries WHERE id = ?", arguments: [id]) ?? -1
        }
    }

    // MARK: - saveEmbedding / embedding

    @Test("saveEmbedding then embedding round-trips every field")
    func embeddingRoundTrip() throws {
        let store = try Store.inMemory()
        let id = try insertEntry(in: store, kind: .text)
        let vector = Data([0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0x00]) // two little-endian Float32s
        try store.dbQueue.write { db in
            try EntryRepository.saveEmbedding(
                entryId: id, modelId: "nl-contextual-v1", revision: 1, dims: 2, vector: vector, in: db)
        }
        let repo = EntryRepository(store: store)
        let row = try repo.embedding(entryId: id)
        #expect(row?.entryId == id)
        #expect(row?.modelId == "nl-contextual-v1")
        #expect(row?.revision == 1)
        #expect(row?.dims == 2)
        #expect(row?.vector == vector)
        #expect(row?.embeddedAt ?? 0 > 0)
    }

    @Test("embedding returns nil for an entry that hasn't been embedded")
    func embeddingNilWhenAbsent() throws {
        let store = try Store.inMemory()
        let id = try insertEntry(in: store, kind: .text)
        let repo = EntryRepository(store: store)
        #expect(try repo.embedding(entryId: id) == nil)
    }

    @Test("saveEmbedding is an upsert — a second call replaces the row, not duplicates it")
    func saveEmbeddingUpserts() throws {
        let store = try Store.inMemory()
        let id = try insertEntry(in: store, kind: .text)
        try store.dbQueue.write { db in
            try EntryRepository.saveEmbedding(
                entryId: id, modelId: "nl-contextual-v1", revision: 1, dims: 2, vector: Data([1, 2]), in: db)
            try EntryRepository.saveEmbedding(
                entryId: id, modelId: "nl-contextual-v2", revision: 2, dims: 3, vector: Data([3, 4, 5]), in: db)
        }
        let repo = EntryRepository(store: store)
        let row = try repo.embedding(entryId: id)
        #expect(row?.modelId == "nl-contextual-v2")
        #expect(row?.revision == 2)
        #expect(row?.dims == 3)
        #expect(row?.vector == Data([3, 4, 5]))
        let count = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry_embeddings WHERE entry_id = ?", arguments: [id])
        }
        #expect(count == 1)
    }

    @Test("saveEmbedding does not bump modified_at or enqueue a push")
    func saveEmbeddingIsPureEnrichment() throws {
        let store = try Store.inMemory()
        let id = try insertEntry(in: store, kind: .text, modifiedAt: 12_345)
        try store.dbQueue.write { db in
            try EntryRepository.saveEmbedding(
                entryId: id, modelId: "nl-contextual-v1", revision: 1, dims: 1, vector: Data([9]), in: db)
        }
        #expect(try modifiedAt(store, id) == 12_345)
        let queued = try store.dbQueue.read { db in try PushQueue.count(in: db) }
        #expect(queued == 0)
    }

    // MARK: - entriesNeedingEmbedding

    @Test("entriesNeedingEmbedding finds text/link entries with no embedding row")
    func needsEmbeddingFindsUnembedded() throws {
        let store = try Store.inMemory()
        let textId = try insertEntry(in: store, kind: .text)
        let linkId = try insertEntry(in: store, kind: .link)
        let imageId = try insertEntry(in: store, kind: .image)
        _ = imageId

        let repo = EntryRepository(store: store)
        let candidates = Set(try repo.entriesNeedingEmbedding(modelId: "nl-v1", revision: 1, limit: 10))
        #expect(candidates.contains(textId))
        #expect(candidates.contains(linkId))
        #expect(!candidates.contains(imageId), "image-kind entries should never be embedding candidates")
    }

    @Test("entriesNeedingEmbedding excludes deleted entries")
    func needsEmbeddingExcludesDeleted() throws {
        let store = try Store.inMemory()
        let deletedId = try insertEntry(in: store, kind: .text, deletedAt: 500)
        let repo = EntryRepository(store: store)
        let candidates = try repo.entriesNeedingEmbedding(modelId: "nl-v1", revision: 1, limit: 10)
        #expect(!candidates.contains(deletedId))
    }

    @Test("entriesNeedingEmbedding excludes entries whose embedding matches model+revision")
    func needsEmbeddingExcludesUpToDate() throws {
        let store = try Store.inMemory()
        let upToDateId = try insertEntry(in: store, kind: .text)
        try store.dbQueue.write { db in
            try EntryRepository.saveEmbedding(
                entryId: upToDateId, modelId: "nl-v1", revision: 3, dims: 1, vector: Data([1]), in: db)
        }
        let repo = EntryRepository(store: store)
        let candidates = try repo.entriesNeedingEmbedding(modelId: "nl-v1", revision: 3, limit: 10)
        #expect(!candidates.contains(upToDateId))
    }

    @Test("entriesNeedingEmbedding includes entries with a stale model or revision")
    func needsEmbeddingIncludesStale() throws {
        let store = try Store.inMemory()
        let staleModelId = try insertEntry(in: store, kind: .text)
        let staleRevisionId = try insertEntry(in: store, kind: .text)
        try store.dbQueue.write { db in
            try EntryRepository.saveEmbedding(
                entryId: staleModelId, modelId: "nl-old", revision: 1, dims: 1, vector: Data([1]), in: db)
            try EntryRepository.saveEmbedding(
                entryId: staleRevisionId, modelId: "nl-v1", revision: 1, dims: 1, vector: Data([1]), in: db)
        }
        let repo = EntryRepository(store: store)
        // Bumping the required revision to 2 should re-surface both rows:
        // one has the wrong model entirely, the other the right model but
        // an old revision.
        let candidates = Set(try repo.entriesNeedingEmbedding(modelId: "nl-v1", revision: 2, limit: 10))
        #expect(candidates.contains(staleModelId))
        #expect(candidates.contains(staleRevisionId))
    }

    @Test("entriesNeedingEmbedding orders newest-first")
    func needsEmbeddingNewestFirst() throws {
        let store = try Store.inMemory()
        let (olderId, newerId) = try store.dbQueue.write { db -> (Int64, Int64) in
            var device = Device(identifier: "D", name: "M", kind: "mac")
            try device.insert(db)
            var older = Entry(
                uuid: Data(repeating: 0x01, count: 16), createdAt: 100, capturedAt: 100, kind: .text,
                sourceDeviceId: device.id!, textPreview: "a", contentHash: Data(repeating: 0x02, count: 32), totalSize: 1)
            try older.insert(db)
            var newer = Entry(
                uuid: Data(repeating: 0x03, count: 16), createdAt: 200, capturedAt: 200, kind: .text,
                sourceDeviceId: device.id!, textPreview: "b", contentHash: Data(repeating: 0x04, count: 32), totalSize: 1)
            try newer.insert(db)
            return (older.id!, newer.id!)
        }
        let repo = EntryRepository(store: store)
        let candidates = try repo.entriesNeedingEmbedding(modelId: "nl-v1", revision: 1, limit: 10)
        let olderIdx = candidates.firstIndex(of: olderId)
        let newerIdx = candidates.firstIndex(of: newerId)
        #expect(newerIdx != nil && olderIdx != nil && newerIdx! < olderIdx!)
    }

    // MARK: - setChips

    @Test("setChips persists the JSON payload and enqueues a push")
    func setChipsPersistsAndQueues() throws {
        let store = try Store.inMemory()
        let id = try insertEntry(in: store, kind: .text)
        let repo = EntryRepository(store: store)
        let json = #"[{"t":"date","v":"2026-08-26","s":"Aug 26"}]"#
        try repo.setChips(entryId: id, json: json)

        let stored = try store.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT chips_json FROM entries WHERE id = ?", arguments: [id])
        }
        #expect(stored == json)
        let queued = try store.dbQueue.read { db in try PushQueue.count(in: db) }
        #expect(queued == 1)
    }

    @Test("setChips does not bump modified_at")
    func setChipsDoesNotBumpModifiedAt() throws {
        let store = try Store.inMemory()
        let id = try insertEntry(in: store, kind: .text, modifiedAt: 777)
        let repo = EntryRepository(store: store)
        try repo.setChips(entryId: id, json: "[]")
        #expect(try modifiedAt(store, id) == 777)
    }

    @Test("setChips no-ops on a deleted entry")
    func setChipsSkipsDeletedEntry() throws {
        let store = try Store.inMemory()
        let id = try insertEntry(in: store, kind: .text, deletedAt: 500)
        let repo = EntryRepository(store: store)
        try repo.setChips(entryId: id, json: "[]")
        let stored: String? = try store.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT chips_json FROM entries WHERE id = ?", arguments: [id])?["chips_json"]
        }
        #expect(stored == nil)
    }

    // MARK: - setAITitleSummary

    @Test("setAITitleSummary persists both fields and enqueues a push")
    func setAITitleSummaryPersistsAndQueues() throws {
        let store = try Store.inMemory()
        let id = try insertEntry(in: store, kind: .text)
        let repo = EntryRepository(store: store)
        try repo.setAITitleSummary(entryId: id, title: "Flight confirmation", summary: "UA123 on Aug 30.")

        let row = try store.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT ai_title, ai_summary FROM entries WHERE id = ?", arguments: [id])
        }
        #expect(row?["ai_title"] == "Flight confirmation")
        #expect(row?["ai_summary"] == "UA123 on Aug 30.")
        let queued = try store.dbQueue.read { db in try PushQueue.count(in: db) }
        #expect(queued == 1)
    }

    @Test("setAITitleSummary does not bump modified_at")
    func setAITitleSummaryDoesNotBumpModifiedAt() throws {
        let store = try Store.inMemory()
        let id = try insertEntry(in: store, kind: .text, modifiedAt: 42)
        let repo = EntryRepository(store: store)
        try repo.setAITitleSummary(entryId: id, title: "T", summary: "S")
        #expect(try modifiedAt(store, id) == 42)
    }

    @Test("setAITitleSummary leaves the existing title column untouched")
    func setAITitleSummaryDoesNotTouchTitle() throws {
        let store = try Store.inMemory()
        let id = try store.dbQueue.write { db -> Int64 in
            var device = Device(identifier: "D2", name: "M", kind: "mac")
            try device.insert(db)
            var entry = Entry(
                uuid: Data(repeating: 0x09, count: 16), createdAt: 1, capturedAt: 1, kind: .text,
                sourceDeviceId: device.id!, title: "pasteboard title", textPreview: "body",
                contentHash: Data(repeating: 0x0A, count: 32), totalSize: 4)
            try entry.insert(db)
            return entry.id!
        }
        let repo = EntryRepository(store: store)
        try repo.setAITitleSummary(entryId: id, title: "model title", summary: "model summary")
        let fetched = try repo.fetch(id: id)
        #expect(fetched?.title == "pasteboard title")
        #expect(fetched?.aiTitle == "model title")
        #expect(fetched?.aiSummary == "model summary")
    }
}
