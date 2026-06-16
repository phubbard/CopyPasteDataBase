import Testing
import Foundation
import GRDB
@testable import CpdbShared

@Suite("UndoCoordinator — multi-level undo/redo")
struct UndoCoordinatorTests {

    private func setup() throws -> (Store, EntryRepository, UndoCoordinator, Int64) {
        let store = try Store.inMemory()
        let dev = try store.dbQueue.write { db -> Int64 in
            var d = Device(identifier: "d", name: "D", kind: "mac"); try d.insert(db); return d.id!
        }
        let repo = EntryRepository(store: store)
        return (store, repo, UndoCoordinator(repo: repo), dev)
    }

    @discardableResult
    private func insert(_ store: Store, dev: Int64, byte: UInt8, pinned: Bool = false) throws -> Int64 {
        try store.dbQueue.write { db in
            var e = Entry(uuid: Data(repeating: byte, count: 16), createdAt: Double(byte), capturedAt: Double(byte),
                          kind: .text, sourceDeviceId: dev, textPreview: "e\(byte)",
                          contentHash: Data(repeating: byte, count: 32), totalSize: 1,
                          pinned: pinned, hashVersion: 2, identityTag: "text", modifiedAt: Double(byte))
            try e.insert(db)
            try FtsIndex.indexEntry(db: db, entryId: e.id!, title: nil, text: "e\(byte)", appName: nil)
            return e.id!
        }
    }

    private func isLive(_ store: Store, _ id: Int64) throws -> Bool {
        try store.dbQueue.read { db in
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE id = ? AND deleted_at IS NULL", arguments: [id]) ?? 0
            return n == 1
        }
    }

    @Test("Delete → undo restores → redo re-deletes")
    func deleteUndoRedo() throws {
        let (store, _, undo, dev) = try setup()
        let id = try insert(store, dev: dev, byte: 1)
        let desc = try undo.delete(id: id)
        #expect(desc.kind == .delete)
        #expect(desc.pastTense == "Deleted")
        #expect(try !isLive(store, id))
        #expect(undo.canUndo); #expect(!undo.canRedo)

        let undone = try undo.undo()
        #expect(undone?.kind == .restore)
        #expect(try isLive(store, id))
        #expect(!undo.canUndo); #expect(undo.canRedo)

        let redone = try undo.redo()
        #expect(redone?.kind == .delete)
        #expect(try !isLive(store, id))
        #expect(undo.canUndo); #expect(!undo.canRedo)
    }

    @Test("Pin → undo unpins → redo re-pins; no-op when already in state")
    func pinUndoRedo() throws {
        let (store, repo, undo, dev) = try setup()
        let id = try insert(store, dev: dev, byte: 2, pinned: false)
        let desc = try undo.setPinned(id: id, pinned: true)
        #expect(desc?.kind == .pin)
        #expect(try repo.pinnedState(id: id) == true)

        // Setting to the SAME state is a no-op (no stack entry).
        let noop = try undo.setPinned(id: id, pinned: true)
        #expect(noop == nil)

        _ = try undo.undo()
        #expect(try repo.pinnedState(id: id) == false)   // unpinned
        _ = try undo.redo()
        #expect(try repo.pinnedState(id: id) == true)    // re-pinned
    }

    @Test("Multi-level: three deletes, undo all in reverse order")
    func multiLevel() throws {
        let (store, _, undo, dev) = try setup()
        let ids = try (1...3).map { try insert(store, dev: dev, byte: UInt8($0)) }
        for id in ids { try undo.delete(id: id) }
        #expect(try ids.allSatisfy { try !isLive(store, $0) })

        // Undo pops in LIFO order: id3, id2, id1.
        for id in ids.reversed() {
            let r = try undo.undo()
            #expect(r?.entryId == id)
            #expect(try isLive(store, id))
        }
        #expect(!undo.canUndo)
    }

    @Test("A new action clears the redo timeline")
    func newActionClearsRedo() throws {
        let (store, _, undo, dev) = try setup()
        let a = try insert(store, dev: dev, byte: 4)
        let b = try insert(store, dev: dev, byte: 5)
        try undo.delete(id: a)
        _ = try undo.undo()            // a restored, redo available
        #expect(undo.canRedo)
        try undo.delete(id: b)         // new action
        #expect(!undo.canRedo)         // redo timeline gone
    }

    @Test("Stack is depth-bounded; oldest drops")
    func depthBound() throws {
        let (store, _, _, dev) = try setup()
        let repo = EntryRepository(store: store)
        let undo = UndoCoordinator(repo: repo, maxDepth: 2)
        let ids = try (1...4).map { try insert(store, dev: dev, byte: UInt8($0)) }
        for id in ids { try undo.delete(id: id) }
        // Only the last 2 deletes are undoable.
        var undoneCount = 0
        while undo.canUndo { _ = try undo.undo(); undoneCount += 1 }
        #expect(undoneCount == 2)
    }

    @Test("Menu titles reflect the next undo/redo")
    func menuTitles() throws {
        let (store, _, undo, dev) = try setup()
        let id = try insert(store, dev: dev, byte: 6)
        #expect(undo.undoMenuTitle == nil)
        try undo.delete(id: id)
        #expect(undo.undoMenuTitle == "Undo Delete")
        _ = try undo.undo()
        #expect(undo.redoMenuTitle == "Redo Delete")
    }
}
