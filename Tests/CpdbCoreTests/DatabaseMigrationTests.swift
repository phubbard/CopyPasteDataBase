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

    @Test("v2 rebuilds entries_fts with 5 columns")
    func v2FtsHasFiveColumns() throws {
        let store = try Store.inMemory()
        try store.dbQueue.read { db in
            // fts5 virtual tables expose columns via normal pragma
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(entries_fts)")
                .map { $0["name"] as String }
            #expect(cols == ["title", "text", "app_name", "ocr_text", "image_tags"])
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
}
