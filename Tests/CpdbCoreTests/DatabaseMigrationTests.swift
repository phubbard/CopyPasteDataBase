import Testing
import Foundation
import GRDB
@testable import CpdbCore
@testable import CpdbShared

@Suite("Database migrations")
struct DatabaseMigrationTests {
    @Test("Fresh migration creates every expected table")
    func freshMigrationCreatesAllTables() throws {
        let store = try Store.inMemory()
        let expected: Set<String> = [
            "entries",
            "entry_flavors",
            "apps",
            "devices",
            "pinboards",
            "pinboard_entries",
            "previews",
            "entries_fts",
            "cloudkit_push_queue",
            "cloudkit_state",
            "entry_embeddings",
        ]
        try store.dbQueue.read { db in
            for name in expected {
                let exists = try db.tableExists(name)
                #expect(exists, "expected table \(name) to exist")
            }
        }
    }

    @Test("Insert and read back an entry")
    func insertAndReadbackEntry() throws {
        let store = try Store.inMemory()
        try store.dbQueue.write { db in
            var device = Device(identifier: "TEST-UUID", name: "Test Mac", kind: "mac")
            try device.insert(db)

            var entry = Entry(
                uuid: Data(repeating: 0xAB, count: 16),
                createdAt: 1_700_000_000,
                capturedAt: 1_700_000_000,
                kind: .text,
                sourceAppId: nil,
                sourceDeviceId: device.id!,
                title: "hello",
                textPreview: "hello world",
                contentHash: Data(repeating: 0xCD, count: 32),
                totalSize: 11
            )
            try entry.insert(db)
            #expect(entry.id != nil)

            let fetched = try Entry.fetchOne(db, key: entry.id!)
            #expect(fetched?.title == "hello")
            #expect(fetched?.kind == .text)
        }
    }

    @Test("v2 adds ocr_text, image_tags, analyzed_at columns")
    func v2AddsAnalysisColumns() throws {
        let store = try Store.inMemory()
        try store.dbQueue.read { db in
            let info = try Row.fetchAll(db, sql: "PRAGMA table_info(entries)")
                .map { $0["name"] as String }
            #expect(info.contains("ocr_text"))
            #expect(info.contains("image_tags"))
            #expect(info.contains("analyzed_at"))
        }
    }

    @Test("entries_fts has the v8 column layout (title + 5 content cols + link_title)")
    func ftsLatestColumnLayout() throws {
        let store = try Store.inMemory()
        try store.dbQueue.read { db in
            // fts5 virtual tables expose columns via normal pragma.
            // v2 brought the table to 5 cols (added ocr_text +
            // image_tags); v8 added link_title for fetched page
            // titles. Update this list when the schema grows.
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(entries_fts)")
                .map { $0["name"] as String }
            #expect(cols == ["title", "text", "app_name", "ocr_text", "image_tags", "link_title"])
        }
    }

    @Test("v2 reindexes existing rows into the new fts table")
    func v2Reindexes() throws {
        let store = try Store.inMemory()
        try store.dbQueue.write { db in
            var device = Device(identifier: "D", name: "M", kind: "mac")
            try device.insert(db)
            var entry = Entry(
                uuid: Data(repeating: 0x11, count: 16),
                createdAt: 1, capturedAt: 1, kind: .text,
                sourceDeviceId: device.id!,
                title: "searchable headline",
                textPreview: "payload body phrase",
                contentHash: Data(repeating: 0x22, count: 32), totalSize: 10
            )
            try entry.insert(db)
            // Force-index into the v2 FTS (normally Ingestor does this).
            try FtsIndex.indexEntry(
                db: db,
                entryId: entry.id!,
                title: entry.title,
                text: entry.textPreview,
                appName: nil,
                ocrText: nil,
                imageTags: nil
            )
        }
        try store.dbQueue.read { db in
            let ids = try Int64.fetchAll(
                db,
                sql: "SELECT rowid FROM entries_fts WHERE entries_fts MATCH 'payload'"
            )
            #expect(ids.count == 1)
        }
    }

    @Test("content_hash unique constraint blocks duplicate live rows")
    func dedupUniqueIndexBlocksDuplicateLiveHash() throws {
        let store = try Store.inMemory()
        try store.dbQueue.write { db in
            var device = Device(identifier: "D1", name: "M", kind: "mac")
            try device.insert(db)

            let hash = Data(repeating: 0x42, count: 32)
            var e1 = Entry(
                uuid: Data(repeating: 0x01, count: 16),
                createdAt: 1, capturedAt: 1, kind: .text,
                sourceDeviceId: device.id!, title: nil, textPreview: nil,
                contentHash: hash, totalSize: 0
            )
            try e1.insert(db)

            var e2 = Entry(
                uuid: Data(repeating: 0x02, count: 16),
                createdAt: 2, capturedAt: 2, kind: .text,
                sourceDeviceId: device.id!, title: nil, textPreview: nil,
                contentHash: hash, totalSize: 0
            )
            #expect(throws: (any Error).self) { try e2.insert(db) }

            // Tombstoning the first one must allow a new live row with the same hash.
            try db.execute(sql: "UPDATE entries SET deleted_at = 100 WHERE id = ?", arguments: [e1.id])
            var e3 = Entry(
                uuid: Data(repeating: 0x03, count: 16),
                createdAt: 3, capturedAt: 3, kind: .text,
                sourceDeviceId: device.id!, title: nil, textPreview: nil,
                contentHash: hash, totalSize: 0
            )
            try e3.insert(db)
        }
    }

    // MARK: - v12 semantic enrichment

    @Test("v12 creates entry_embeddings with the expected columns")
    func v12CreatesEntryEmbeddingsTable() throws {
        let store = try Store.inMemory()
        try store.dbQueue.read { db in
            let exists = try db.tableExists("entry_embeddings")
            #expect(exists)
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(entry_embeddings)")
                .map { $0["name"] as String }
            #expect(Set(cols) == ["entry_id", "model_id", "revision", "dims", "vector", "embedded_at"])
        }
    }

    @Test("v12 adds chips_json, ai_title, ai_summary columns to entries")
    func v12AddsEnrichmentColumns() throws {
        let store = try Store.inMemory()
        try store.dbQueue.read { db in
            let info = try Row.fetchAll(db, sql: "PRAGMA table_info(entries)")
                .map { $0["name"] as String }
            #expect(info.contains("chips_json"))
            #expect(info.contains("ai_title"))
            #expect(info.contains("ai_summary"))
        }
    }

    @Test("v12 leaves the existing title column untouched")
    func v12DoesNotTouchTitleColumn() throws {
        // Guards against a regression where an enrichment column
        // accidentally collides with / replaces the pasteboard-derived
        // `title` column instead of adding new `ai_title`/`ai_summary`
        // columns alongside it.
        let store = try Store.inMemory()
        try store.dbQueue.read { db in
            let info = try Row.fetchAll(db, sql: "PRAGMA table_info(entries)")
                .map { $0["name"] as String }
            #expect(info.contains("title"))
            #expect(info.filter { $0 == "title" }.count == 1)
        }
    }

    @Test("entry_embeddings row is deleted when its entry is deleted (ON DELETE CASCADE)")
    func v12EmbeddingsCascadeOnEntryDelete() throws {
        let store = try Store.inMemory()
        try store.dbQueue.write { db in
            var device = Device(identifier: "D-EMB", name: "M", kind: "mac")
            try device.insert(db)
            var entry = Entry(
                uuid: Data(repeating: 0x30, count: 16),
                createdAt: 1, capturedAt: 1, kind: .text,
                sourceDeviceId: device.id!, title: nil, textPreview: "some text",
                contentHash: Data(repeating: 0x31, count: 32), totalSize: 9
            )
            try entry.insert(db)

            try EntryRepository.saveEmbedding(
                entryId: entry.id!, modelId: "nl-contextual-v1", revision: 1,
                dims: 3, vector: Data([0, 1, 2]), in: db
            )
            let countBefore = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry_embeddings")
            #expect(countBefore == 1)

            try db.execute(sql: "DELETE FROM entries WHERE id = ?", arguments: [entry.id])
            let countAfter = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry_embeddings")
            #expect(countAfter == 0)
        }
    }

    @Test("running migrations twice is a no-op (idempotent)")
    func migrationsAreIdempotent() throws {
        // Store.inMemory() already runs the full migrator once; opening a
        // second DatabaseQueue against the same migrator on a fresh file
        // and running it again must not throw (GRDB's migrator tracks
        // applied migrations in grdb_migrations and skips them).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpdb-migration-idempotent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("test.sqlite").path

        let store1 = try Store(path: dbPath)
        _ = store1
        let store2 = try Store(path: dbPath)
        try store2.dbQueue.read { db in
            let exists = try db.tableExists("entry_embeddings")
            #expect(exists)
        }
    }
}
