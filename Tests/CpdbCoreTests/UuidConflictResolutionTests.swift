import Testing
import Foundation
import CloudKit
import GRDB
@testable import CpdbShared

/// Tests for `CloudKitSyncer.resolveUuidConflict` — the §5.3 pull-side
/// logic that fires on a content_hash miss + uuid match (the same logical
/// entry arriving under a different hash). Tested directly: build a local
/// row + a decoded record, call the helper inside a write transaction,
/// assert convergence.
@Suite("Pull-side uuid-conflict resolution (hash-v2 §5.3)")
struct UuidConflictResolutionTests {

    private func store() throws -> (Store, Int64) {
        let s = try Store.inMemory()
        let dev = try s.dbQueue.write { db -> Int64 in
            var d = Device(identifier: "local-dev", name: "Local", kind: "mac")
            try d.insert(db)
            return d.id!
        }
        return (s, dev)
    }

    @discardableResult
    private func insertLocal(
        _ store: Store, dev: Int64, uuid: UInt8, hash: Data,
        version: Int, tag: String?, prev: Data? = nil,
        createdAt: Double = 100, pinned: Bool = false, deleted: Double? = nil,
        text: String = "body"
    ) throws -> Int64 {
        try store.dbQueue.write { db in
            var e = Entry(
                uuid: Data(repeating: uuid, count: 16), createdAt: createdAt, capturedAt: createdAt,
                kind: .text, sourceDeviceId: dev, title: text, textPreview: text,
                contentHash: hash, totalSize: 10, deletedAt: deleted, pinned: pinned,
                hashVersion: version, prevContentHash: prev, identityTag: tag)
            try e.insert(db)
            try FtsIndex.indexEntry(db: db, entryId: e.id!, title: text, text: text, appName: nil)
            return e.id!
        }
    }

    private func decoded(
        uuid: UInt8, hash: Data, version: Int, tag: String?,
        createdAt: Double = 200, pinned: Bool = false, deletedAt: Double? = nil,
        text: String = "body"
    ) -> EntryRecordMapper.Decoded {
        EntryRecordMapper.Decoded(
            uuid: Data(repeating: uuid, count: 16), createdAt: createdAt, capturedAt: createdAt,
            kind: .text, title: text, textPreview: text, contentHash: hash, totalSize: 10,
            deletedAt: deletedAt, source: .init(deviceIdentifier: "remote-dev", deviceName: "Remote"),
            pinned: pinned, hashVersion: version, identityTag: tag)
    }

    private func resolve(_ store: Store, dev: Int64, _ d: EntryRecordMapper.Decoded, localId: Int64) throws -> CloudKitSyncer.UpsertOutcome {
        try store.dbQueue.write { db in
            let local = try Entry.fetchOne(db, key: localId)!
            return try CloudKitSyncer.resolveUuidConflict(decoded: d, local: local, appId: nil, devId: dev, blobs: BlobStore(), in: db)
        }
    }

    private func row(_ store: Store, _ id: Int64) throws -> Row? {
        try store.dbQueue.read { db in try Row.fetchOne(db, sql: "SELECT * FROM entries WHERE id = ?", arguments: [id]) }
    }

    let hashV1 = Data(repeating: 0x11, count: 32)
    let hashV2 = Data(repeating: 0x22, count: 32)
    let hashV2b = Data(repeating: 0x33, count: 32)

    // MARK: - Version-based

    @Test("Straggler upgrade: remote v2 > local v1 → adopt remote hash + tag")
    func upgradeStraggler() throws {
        let (store, dev) = try store()
        let id = try insertLocal(store, dev: dev, uuid: 1, hash: hashV1, version: 1, tag: nil)
        let d = decoded(uuid: 1, hash: hashV2, version: 2, tag: "text")
        let oc1 = try resolve(store, dev: dev, d, localId: id)
        #expect(oc1 == .updated)
        let r = try row(store, id)
        #expect(r?["content_hash"] as Data? == hashV2)
        #expect(r?["hash_version"] as Int? == 2)
        #expect(r?["identity_tag"] as String? == "text")
        #expect(r?["prev_content_hash"] as Data? == hashV1)   // lineage kept
    }

    @Test("Downgrade refused: remote v1 < local v2 → unchanged")
    func refuseDowngrade() throws {
        let (store, dev) = try store()
        let id = try insertLocal(store, dev: dev, uuid: 1, hash: hashV2, version: 2, tag: "text", prev: hashV1)
        let d = decoded(uuid: 1, hash: hashV1, version: 1, tag: nil)
        let oc2 = try resolve(store, dev: dev, d, localId: id)
        #expect(oc2 == .unchanged)
        let rr1 = try row(store, id)
        #expect(rr1?["content_hash"] as Data? == hashV2) // unchanged
    }

    @Test("Upgrade with collision: a live row already holds the remote hash → merge + retire uuid-row")
    func upgradeWithCollision() throws {
        let (store, dev) = try store()
        // Survivor already at the v2 hash (pinned, with FTS), and our
        // straggler uuid-row at v1 that will upgrade INTO it.
        let survivor = try insertLocal(store, dev: dev, uuid: 9, hash: hashV2, version: 2, tag: "text",
                                       prev: Data(repeating: 0xAA, count: 32), createdAt: 50, pinned: true)
        let straggler = try insertLocal(store, dev: dev, uuid: 1, hash: hashV1, version: 1, tag: nil, createdAt: 100)
        let d = decoded(uuid: 1, hash: hashV2, version: 2, tag: "text")
        let oc3 = try resolve(store, dev: dev, d, localId: straggler)
        #expect(oc3 == .updated)
        // Straggler retired (tombstoned, reverted to its own v1 hash —
        // inert), survivor still live and pinned.
        let rr2 = try row(store, straggler)
        #expect((rr2?["deleted_at"] as Double?) != nil)
        let sv = try row(store, survivor)
        #expect(sv?["deleted_at"] as Double? == nil)
        #expect((sv?["pinned"] as Int64? ?? 0) == 1)
        // Exactly one live row holds the v2 hash.
        let liveAtHash = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE content_hash = ? AND deleted_at IS NULL", arguments: [hashV2]) ?? -1
        }
        #expect(liveAtHash == 1)
    }

    // MARK: - Equal-version rung priority

    @Test("Equal version, remote lower rung (image<text) → remote wins, re-key")
    func equalVersionRemoteLowerRung() throws {
        let (store, dev) = try store()
        // local rung = text (4); remote rung = image (1) → remote wins.
        let id = try insertLocal(store, dev: dev, uuid: 1, hash: hashV2, version: 2, tag: "text")
        let d = decoded(uuid: 1, hash: hashV2b, version: 2, tag: "image")
        let oc1 = try resolve(store, dev: dev, d, localId: id)
        #expect(oc1 == .updated)
        let rr3 = try row(store, id)
        #expect(rr3?["content_hash"] as Data? == hashV2b)
        let rr4 = try row(store, id)
        #expect(rr4?["identity_tag"] as String? == "image")
    }

    @Test("Equal version, local lower rung → local wins, unchanged")
    func equalVersionLocalLowerRung() throws {
        let (store, dev) = try store()
        // local rung = image (1); remote rung = text (4) → local wins.
        let id = try insertLocal(store, dev: dev, uuid: 1, hash: hashV2, version: 2, tag: "image")
        let d = decoded(uuid: 1, hash: hashV2b, version: 2, tag: "text")
        let oc2 = try resolve(store, dev: dev, d, localId: id)
        #expect(oc2 == .unchanged)
        let rr5 = try row(store, id)
        #expect(rr5?["content_hash"] as Data? == hashV2)
    }

    @Test("Equal version + equal rung → smaller hash bytes win (both directions)")
    func equalVersionTieBreak() throws {
        // Remote hash smaller → remote wins.
        do {
            let (store, dev) = try store()
            let id = try insertLocal(store, dev: dev, uuid: 1, hash: hashV2b, version: 2, tag: "fallback")
            let d = decoded(uuid: 1, hash: hashV2, version: 2, tag: "fallback")   // 0x22 < 0x33
            let oc1 = try resolve(store, dev: dev, d, localId: id)
        #expect(oc1 == .updated)
            let rr6 = try row(store, id)
            #expect(rr6?["content_hash"] as Data? == hashV2)
        }
        // Remote hash larger → local wins.
        do {
            let (store, dev) = try store()
            let id = try insertLocal(store, dev: dev, uuid: 1, hash: hashV2, version: 2, tag: "fallback")
            let d = decoded(uuid: 1, hash: hashV2b, version: 2, tag: "fallback")
            let oc2 = try resolve(store, dev: dev, d, localId: id)
        #expect(oc2 == .unchanged)
            let rr7 = try row(store, id)
            #expect(rr7?["content_hash"] as Data? == hashV2)
        }
    }

    @Test("Symmetric convergence: A pulling B and B pulling A pick the SAME winner")
    func symmetricConvergence() throws {
        // Device A holds (uuid1, hashV2, text). Device B holds (uuid1,
        // hashV2b, image). Each pulls the other's record. Both must end on
        // the image hash (lower rung), with no oscillation.
        let (storeA, devA) = try store()
        let idA = try insertLocal(storeA, dev: devA, uuid: 1, hash: hashV2, version: 2, tag: "text")
        let bIntoA = decoded(uuid: 1, hash: hashV2b, version: 2, tag: "image")
        _ = try resolve(storeA, dev: devA, bIntoA, localId: idA)

        let (storeB, devB) = try store()
        let idB = try insertLocal(storeB, dev: devB, uuid: 1, hash: hashV2b, version: 2, tag: "image")
        let aIntoB = decoded(uuid: 1, hash: hashV2, version: 2, tag: "text")
        _ = try resolve(storeB, dev: devB, aIntoB, localId: idB)

        let rr8 = try row(storeA, idA)
        #expect(rr8?["content_hash"] as Data? == hashV2b) // A adopted image
        let rr9 = try row(storeB, idB)
        #expect(rr9?["content_hash"] as Data? == hashV2b) // B kept image
        let rr10 = try row(storeA, idA)
        #expect(rr10?["identity_tag"] as String? == "image")
        let rr11 = try row(storeB, idB)
        #expect(rr11?["identity_tag"] as String? == "image")
    }

    @Test("rungIndex ordering: known tags ranked, nil/unknown sort last")
    func rungIndexOrdering() {
        #expect(CloudKitSyncer.rungIndex("image") < CloudKitSyncer.rungIndex("text"))
        #expect(CloudKitSyncer.rungIndex("text") < CloudKitSyncer.rungIndex("fallback"))
        #expect(CloudKitSyncer.rungIndex(nil) == Int.max)
        #expect(CloudKitSyncer.rungIndex("bogus") == Int.max)
    }
}
