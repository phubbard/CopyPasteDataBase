import Testing
import Foundation
import GRDB
@testable import CpdbShared

/// Tests for the `PushQueue.remove(entryId:peekedEnqueuedAt:)` race guard
/// (hash-v2 Step 4c): a push spends seconds-to-minutes round-tripping
/// CloudKit; any edit to an in-flight entry re-enqueues it (bumping
/// enqueued_at). The success-path removal must NOT drop that re-enqueue.
@Suite("PushQueue — remove vs concurrent re-enqueue")
struct PushQueueRaceTests {

    private func store() throws -> Store { try Store.inMemory() }

    private func makeEntry(_ store: Store, id seed: UInt8) throws -> Int64 {
        try store.dbQueue.write { db in
            var dev = try Device.filter(Column("identifier") == "d").fetchOne(db)
            if dev == nil { var d = Device(identifier: "d", name: "D", kind: "mac"); try d.insert(db); dev = d }
            var e = Entry(uuid: Data(repeating: seed, count: 16), createdAt: 1, capturedAt: 1,
                          kind: .text, sourceDeviceId: dev!.id!, textPreview: "x",
                          contentHash: Data(repeating: seed, count: 32), totalSize: 1)
            try e.insert(db)
            return e.id!
        }
    }

    @Test("Re-enqueue during the in-flight window survives the success removal")
    func reEnqueueSurvives() throws {
        let store = try store()
        let id = try makeEntry(store, id: 1)
        // Peek at t=100.
        let peeked = try store.dbQueue.write { db -> PushQueue.Pending in
            try PushQueue.enqueue(entryId: id, in: db, now: 100)
            return try PushQueue.peek(limit: 10, in: db).first!
        }
        #expect(peeked.enqueuedAt == 100)
        // While the push is in flight, the user pins the entry → re-enqueue
        // at t=150 (newer).
        try store.dbQueue.write { db in
            try PushQueue.enqueue(entryId: id, in: db, now: 150)
        }
        // Push succeeds; remove qualified by the PEEKED enqueued_at.
        try store.dbQueue.write { db in
            try PushQueue.remove(entryId: id, peekedEnqueuedAt: peeked.enqueuedAt, in: db)
        }
        // The re-enqueue survived → still queued, will push next tick.
        let remaining = try store.dbQueue.read { db in try PushQueue.count(in: db) }
        #expect(remaining == 1)
    }

    @Test("No concurrent edit: the success removal clears the row")
    func cleanRemoval() throws {
        let store = try store()
        let id = try makeEntry(store, id: 2)
        let peeked = try store.dbQueue.write { db -> PushQueue.Pending in
            try PushQueue.enqueue(entryId: id, in: db, now: 100)
            return try PushQueue.peek(limit: 10, in: db).first!
        }
        try store.dbQueue.write { db in
            try PushQueue.remove(entryId: id, peekedEnqueuedAt: peeked.enqueuedAt, in: db)
        }
        let remaining = try store.dbQueue.read { db in try PushQueue.count(in: db) }
        #expect(remaining == 0)
    }

    @Test("Unconditional remove still drops the row regardless of enqueued_at")
    func unconditionalRemove() throws {
        let store = try store()
        let id = try makeEntry(store, id: 3)
        try store.dbQueue.write { db in
            try PushQueue.enqueue(entryId: id, in: db, now: 100)
            try PushQueue.enqueue(entryId: id, in: db, now: 999)   // bump
            try PushQueue.remove(entryId: id, in: db)              // unconditional
        }
        let remaining = try store.dbQueue.read { db in try PushQueue.count(in: db) }
        #expect(remaining == 0)
    }
}
