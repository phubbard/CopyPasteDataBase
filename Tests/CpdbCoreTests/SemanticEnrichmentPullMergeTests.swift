import Testing
import Foundation
import CloudKit
import GRDB
@testable import CpdbShared

/// Pull-side merge tests for the v12 semantic-enrichment fields
/// (chipsJson, aiTitle, aiSummary, embedding) applied by
/// `CloudKitSyncer.upsert`. These follow the adopt-once convention used
/// for `linkTitle`: nil locally means "not yet enriched", so an inbound
/// value is adopted; once local has a value, it's kept.
@Suite("Semantic enrichment adopt-once merge on pull")
struct SemanticEnrichmentPullMergeTests {

    private func store() throws -> (Store, Int64) {
        let s = try Store.inMemory()
        let dev = try s.dbQueue.write { db -> Int64 in
            var d = Device(identifier: "dev", name: "Dev", kind: "mac"); try d.insert(db); return d.id!
        }
        return (s, dev)
    }

    @discardableResult
    private func insert(
        _ store: Store, dev: Int64, hash: UInt8,
        chipsJson: String? = nil, aiTitle: String? = nil, aiSummary: String? = nil
    ) throws -> Int64 {
        try store.dbQueue.write { db in
            var e = Entry(
                uuid: Data(repeating: hash, count: 16), createdAt: 100, capturedAt: 100,
                kind: .text, sourceDeviceId: dev, textPreview: "body",
                contentHash: Data(repeating: hash, count: 32), totalSize: 1,
                hashVersion: 2, identityTag: "text", modifiedAt: 100,
                chipsJson: chipsJson, aiTitle: aiTitle, aiSummary: aiSummary
            )
            try e.insert(db)
            return e.id!
        }
    }

    private func decoded(
        hash: UInt8,
        chipsJson: String? = nil, aiTitle: String? = nil, aiSummary: String? = nil,
        embedding: EntryRecordMapper.EmbeddingInfo? = nil
    ) -> EntryRecordMapper.Decoded {
        EntryRecordMapper.Decoded(
            uuid: Data(repeating: hash, count: 16), createdAt: 100, capturedAt: 100,
            kind: .text, textPreview: "body", contentHash: Data(repeating: hash, count: 32),
            totalSize: 1, source: .init(deviceIdentifier: "remote", deviceName: "Remote"),
            hashVersion: 2, identityTag: "text", modifiedAt: 100,
            chipsJson: chipsJson, aiTitle: aiTitle, aiSummary: aiSummary, embedding: embedding
        )
    }

    private func applyPull(_ store: Store, _ d: EntryRecordMapper.Decoded) throws -> CloudKitSyncer.UpsertOutcome {
        try store.dbQueue.write { db in
            try CloudKitSyncer.upsert(decoded: d, in: db, fallbackDeviceID: "dev", fallbackDeviceName: "Dev")
        }
    }

    private func row(_ store: Store, _ id: Int64) throws -> Row? {
        try store.dbQueue.read { db in try Row.fetchOne(db, sql: "SELECT * FROM entries WHERE id = ?", arguments: [id]) }
    }

    // MARK: - Existing-entry branch: adopt when local nil

    @Test("Remote chipsJson is adopted when local is nil")
    func chipsAdoptedWhenLocalNil() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 1, chipsJson: nil)
        let remoteJson = #"[{"t":"date","v":"2026-08-26","s":"Aug 26"}]"#
        _ = try applyPull(store, decoded(hash: 1, chipsJson: remoteJson))
        #expect(try row(store, id)?["chips_json"] as String? == remoteJson)
    }

    @Test("Local chipsJson is kept when already non-nil")
    func chipsKeptWhenLocalNonNil() throws {
        let (store, dev) = try store()
        let localJson = #"[{"t":"phone","v":"555-1234","s":"555-1234"}]"#
        let id = try insert(store, dev: dev, hash: 2, chipsJson: localJson)
        _ = try applyPull(store, decoded(hash: 2, chipsJson: #"[{"t":"url","v":"x","s":"x"}]"#))
        #expect(try row(store, id)?["chips_json"] as String? == localJson)
    }

    @Test("Remote aiTitle/aiSummary adopted when local nil")
    func aiTitleSummaryAdoptedWhenLocalNil() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 3)
        _ = try applyPull(store, decoded(hash: 3, aiTitle: "Flight confirmation", aiSummary: "UA123 on Aug 30."))
        #expect(try row(store, id)?["ai_title"] as String? == "Flight confirmation")
        #expect(try row(store, id)?["ai_summary"] as String? == "UA123 on Aug 30.")
    }

    @Test("Local aiTitle/aiSummary kept when already non-nil")
    func aiTitleSummaryKeptWhenLocalNonNil() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 4, aiTitle: "local title", aiSummary: "local summary")
        _ = try applyPull(store, decoded(hash: 4, aiTitle: "remote title", aiSummary: "remote summary"))
        #expect(try row(store, id)?["ai_title"] as String? == "local title")
        #expect(try row(store, id)?["ai_summary"] as String? == "local summary")
    }

    @Test("aiTitle and aiSummary adopt independently — one can be nil locally while the other has a value")
    func aiTitleAndSummaryAdoptIndependently() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 5, aiTitle: "local title", aiSummary: nil)
        _ = try applyPull(store, decoded(hash: 5, aiTitle: "remote title", aiSummary: "remote summary"))
        #expect(try row(store, id)?["ai_title"] as String? == "local title")     // kept
        #expect(try row(store, id)?["ai_summary"] as String? == "remote summary") // adopted
    }

    // MARK: - Embedding: adopt only when local has no row

    @Test("Remote embedding is adopted when the local entry has none")
    func embeddingAdoptedWhenLocalAbsent() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 6)
        let embedding = EntryRecordMapper.EmbeddingInfo(modelId: "nl-v1", revision: 1, dims: 2, vector: Data([1, 2]))
        _ = try applyPull(store, decoded(hash: 6, embedding: embedding))
        let repo = EntryRepository(store: store)
        let saved = try repo.embedding(entryId: id)
        #expect(saved?.modelId == "nl-v1")
        #expect(saved?.revision == 1)
        #expect(saved?.dims == 2)
        #expect(saved?.vector == Data([1, 2]))
    }

    @Test("Local embedding is kept when one already exists")
    func embeddingKeptWhenLocalPresent() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 7)
        try store.dbQueue.write { db in
            try EntryRepository.saveEmbedding(
                entryId: id, modelId: "nl-local", revision: 5, dims: 1, vector: Data([9]), in: db)
        }
        let remote = EntryRecordMapper.EmbeddingInfo(modelId: "nl-remote", revision: 9, dims: 3, vector: Data([1, 2, 3]))
        _ = try applyPull(store, decoded(hash: 7, embedding: remote))
        let repo = EntryRepository(store: store)
        let saved = try repo.embedding(entryId: id)
        #expect(saved?.modelId == "nl-local")
        #expect(saved?.revision == 5)
    }

    @Test("No embedding on the wire leaves a nil local embedding nil")
    func embeddingAbsentStaysAbsent() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, hash: 8)
        _ = try applyPull(store, decoded(hash: 8, embedding: nil))
        let repo = EntryRepository(store: store)
        #expect(try repo.embedding(entryId: id) == nil)
    }

    // MARK: - Insert branch: brand-new local row just takes whatever the remote has

    @Test("A brand-new entry from pull adopts chipsJson/aiTitle/aiSummary/embedding directly")
    func freshInsertAdoptsAllFourDirectly() throws {
        let (store, _) = try store()
        let embedding = EntryRecordMapper.EmbeddingInfo(modelId: "nl-v1", revision: 1, dims: 2, vector: Data([4, 5]))
        let d = decoded(
            hash: 9, chipsJson: #"[{"t":"money","v":"$5","s":"$5"}]"#,
            aiTitle: "title", aiSummary: "summary", embedding: embedding
        )
        let outcome = try applyPull(store, d)
        #expect(outcome == .inserted)
        let id = try #require(try store.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM entries WHERE content_hash = ?", arguments: [Data(repeating: 9, count: 32)])
        })
        #expect(try row(store, id)?["chips_json"] as String? == d.chipsJson)
        #expect(try row(store, id)?["ai_title"] as String? == "title")
        #expect(try row(store, id)?["ai_summary"] as String? == "summary")
        let repo = EntryRepository(store: store)
        let saved = try repo.embedding(entryId: id)
        #expect(saved?.modelId == "nl-v1")
        #expect(saved?.vector == Data([4, 5]))
    }
}
