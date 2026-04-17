import Testing
import Foundation
import GRDB
@testable import CpdbCore

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
