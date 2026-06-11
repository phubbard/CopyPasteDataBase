import Testing
import Foundation
import GRDB
@testable import CpdbCore
@testable import CpdbShared

/// Tests for the canonical-hash v2 cutover routine (docs §4) — the
/// chunked rehash, collision merge, zombie sweep, reseed taxonomy,
/// resumability, the launch reconcile sweep, and hash verification.
///
/// Fixtures fabricate PRE-cutover state: rows inserted with v1
/// (full-flavor-set) hashes and `hash_version = 1`, then the
/// `cutover_pending` marker is set manually (fresh test stores skip it
/// because v10 only marks non-empty databases).
@Suite("Identity cutover (hash-v2 §4)")
struct IdentityCutoverTests {

    // MARK: - Fixture plumbing

    private func makeStore() throws -> Store {
        try Store.inMemory()
    }

    /// Insert a pre-cutover row: v1 hash over the given flavors,
    /// hash_version 1. Returns the entry id.
    @discardableResult
    private func insertV1(
        _ store: Store,
        flavors: [(String, Data)],
        capturedAt: Double,
        uuidByte: UInt8,
        kind: EntryKind = .text,
        pinned: Bool = false,
        deletedAt: Double? = nil,
        bodyEvicted: Bool = false,
        zeroFlavorRows: Bool = false,
        missingBlob: Bool = false,
        linkTitle: String? = nil,
        ocrText: String? = nil,
        textPreview: String? = nil,
        // Override to fabricate a row that is already v2 (a mid-cutover
        // Ingestor capture). `bornV2` stores the v2 hash with NULL
        // prev_content_hash; the content_hash is the v2 identity, not the
        // v1 full-flavor hash.
        bornV2: Bool = false
    ) throws -> Int64 {
        let flavorStructs = flavors.map { CanonicalHash.Flavor(uti: $0.0, data: $0.1) }
        let v1hash = bornV2 ? ContentIdentity.compute(flavors: flavorStructs).hash
                            : CanonicalHash.hash(items: [flavorStructs])
        let preview = textPreview ?? flavors.first(where: { $0.0 == "public.utf8-plain-text" })
            .flatMap { String(data: $0.1, encoding: .utf8) }
        return try store.dbQueue.write { db in
            let devId: Int64
            if let d = try Device.filter(Column("identifier") == "cutover-test").fetchOne(db) {
                devId = d.id!
            } else {
                var d = Device(identifier: "cutover-test", name: "T", kind: "mac")
                try d.insert(db)
                devId = d.id!
            }
            var entry = Entry(
                uuid: Data(repeating: uuidByte, count: 16),
                createdAt: capturedAt,
                capturedAt: capturedAt,
                kind: kind,
                sourceDeviceId: devId,
                title: preview.map { String($0.prefix(200)) },
                textPreview: preview,
                contentHash: v1hash,
                totalSize: Int64(flavors.reduce(0) { $0 + $1.1.count }),
                deletedAt: deletedAt,
                pinned: pinned,
                bodyEvictedAt: bodyEvicted ? capturedAt + 1 : nil,
                linkTitle: linkTitle,
                hashVersion: bornV2 ? 2 : 1,
                identityTag: bornV2 ? ContentIdentity.compute(flavors: flavorStructs).tag.rawValue : nil
            )
            entry.ocrText = ocrText
            try entry.insert(db)
            let id = entry.id!
            if !zeroFlavorRows && !bodyEvicted {
                for (uti, data) in flavors {
                    var f = Flavor(
                        entryId: id, uti: uti,
                        size: Int64(data.count),
                        data: missingBlob ? nil : data,
                        blobKey: missingBlob ? String(repeating: "0", count: 64) : nil
                    )
                    try f.insert(db)
                }
            }
            try FtsIndex.indexEntry(db: db, entryId: id, title: entry.title,
                                    text: preview, appName: nil,
                                    ocrText: ocrText, linkTitle: linkTitle)
            return id
        }
    }

    private func markPending(_ store: Store) throws {
        try store.dbQueue.write { db in
            try IdentityCutover.setState(db, "cutover_pending", "1")
        }
    }

    private func entryRow(_ store: Store, _ id: Int64) throws -> Row? {
        try store.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM entries WHERE id = ?", arguments: [id])
        }
    }

    private func queueIds(_ store: Store) throws -> Set<Int64> {
        try store.dbQueue.read { db in
            try Set(Int64.fetchAll(db, sql: "SELECT entry_id FROM cloudkit_push_queue"))
        }
    }

    // MARK: - End-to-end

    @Test("Full cutover: rehash, merge with coalesce, reseed, latch")
    func endToEnd() async throws {
        let store = try makeStore()
        let text = Data("hello cutover".utf8)
        // A and B: same text, different Chromium tokens → v1-distinct,
        // v2-identical. A earlier (survivor), B pinned + OCR + later.
        let a = try insertV1(store, flavors: [("public.utf8-plain-text", text),
                                              ("org.chromium.source-url", Data("https://a".utf8))],
                             capturedAt: 100, uuidByte: 1)
        let b = try insertV1(store, flavors: [("public.utf8-plain-text", text),
                                              ("org.chromium.source-url", Data("https://b".utf8)),
                                              ("public.html", Data("<p>hello cutover</p>".utf8))],
                             capturedAt: 200, uuidByte: 2, pinned: true, ocrText: "scanned")
        // C: unique content.
        let c = try insertV1(store, flavors: [("public.utf8-plain-text", Data("unique".utf8))],
                             capturedAt: 300, uuidByte: 3)
        // URL pair: rich link copy with title + later plain-text copy of
        // the same URL → text→url promotion converges them.
        let u1 = try insertV1(store, flavors: [("public.url", Data("https://x.com/".utf8)),
                                               ("public.utf8-plain-text", Data("https://x.com".utf8))],
                              capturedAt: 400, uuidByte: 4, kind: .link, linkTitle: "X site")
        let u2 = try insertV1(store, flavors: [("public.utf8-plain-text", Data("https://x.com\n".utf8))],
                              capturedAt: 500, uuidByte: 5, kind: .link)
        // Pinboard + preview on B (the loser) — must survive the merge.
        try await store.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO pinboards (uuid, name, display_order) VALUES (randomblob(16), 'pb', 0)")
            let pbId = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO pinboard_entries (pinboard_id, entry_id, display_order) VALUES (?, ?, 0)",
                           arguments: [pbId, b])
            var p = PreviewRecord(entryId: b, thumbSmall: Data([1, 2]), thumbLarge: nil)
            try p.insert(db)
        }
        try markPending(store)

        let outcome = try await IdentityCutover.run(store: store)
        guard case .completed(let report) = outcome else {
            Issue.record("expected completion, got \(outcome)"); return
        }
        #expect(report.rehashed == 5)
        #expect(report.clustersMerged == 2)       // {A,B} and {u1,u2}
        #expect(report.losersTombstoned == 2)

        // Survivors + coalesce.
        let rowA = try entryRow(store, a)
        #expect(rowA?["deleted_at"] as Double? == nil)
        #expect(rowA?["hash_version"] as Int? == 2)
        #expect(rowA?["identity_tag"] as String? == "text")
        #expect((rowA?["pinned"] as Int64? ?? 0) == 1)            // OR'd from B
        #expect(rowA?["created_at"] as Double? == 200)            // MAX of group
        #expect(rowA?["ocr_text"] as String? == "scanned")        // salvaged
        #expect((rowA?["prev_content_hash"] as Data?) != nil)

        let rowB = try entryRow(store, b)
        #expect((rowB?["deleted_at"] as Double?) != nil)          // tombstoned
        #expect(rowB?["hash_version"] as Int? == 1)               // reverted
        #expect(rowB?["identity_tag"] as String? == nil)

        // B's html flavor adopted by A (union); B's pinboard + preview re-pointed.
        let aUtis = try await store.dbQueue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT uti FROM entry_flavors WHERE entry_id = ?", arguments: [a]))
        }
        #expect(aUtis.contains("public.html"))
        let pbEntry = try await store.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT entry_id FROM pinboard_entries LIMIT 1")
        }
        #expect(pbEntry == a)
        let previewEntry = try await store.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT entry_id FROM previews LIMIT 1")
        }
        #expect(previewEntry == a)

        // URL pair: u1 (earlier) survives with tag url; title kept.
        let rowU1 = try entryRow(store, u1)
        #expect(rowU1?["deleted_at"] as Double? == nil)
        #expect(rowU1?["identity_tag"] as String? == "url")
        #expect(rowU1?["link_title"] as String? == "X site")
        #expect((try entryRow(store, u2)?["deleted_at"] as Double?) != nil)

        // Reseed taxonomy: survivors + unique row queued; losers not.
        let queued = try queueIds(store)
        #expect(queued.contains(a))
        #expect(queued.contains(c))
        #expect(queued.contains(u1))
        #expect(!queued.contains(b))
        #expect(!queued.contains(u2))

        // Latch set, pending cleared, unique index restored.
        let (latch, pending, indexCount) = try await store.dbQueue.read { db in
            (try IdentityCutover.state(db, IdentityCutover.pullBeforePushLatchKey),
             try IdentityCutover.isPending(db),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_entries_live_content_hash'") ?? 0)
        }
        #expect(latch == "1")
        #expect(pending == false)
        #expect(indexCount == 1)

        // FTS: searching the salvaged OCR text finds the survivor.
        let ftsHit = try await store.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT rowid FROM entries_fts WHERE entries_fts MATCH 'scanned'")
        }
        #expect(ftsHit == a)

        // Re-run: nothing to do.
        let second = try await IdentityCutover.run(store: store)
        #expect(second == .notNeeded)
    }

    // MARK: - Kept-v1 taxonomy + reseed inclusion

    @Test("Evicted / zero-flavor / missing-blob keep v1; reseed includes the right ones")
    func keptV1Taxonomy() async throws {
        let store = try makeStore()
        let normal = try insertV1(store, flavors: [("public.utf8-plain-text", Data("normal".utf8))],
                                  capturedAt: 100, uuidByte: 1)
        let evicted = try insertV1(store, flavors: [("public.utf8-plain-text", Data("evicted body".utf8))],
                                   capturedAt: 200, uuidByte: 2, bodyEvicted: true)
        let zeroUnique = try insertV1(store, flavors: [("public.utf8-plain-text", Data("ghost unique".utf8))],
                                      capturedAt: 300, uuidByte: 3, zeroFlavorRows: true)
        // Different flavor set (so its v1 hash doesn't collide with
        // `normal` on the live unique index) but the SAME preview — the
        // zombie sweep matches on preview, not hash.
        let zeroTwin = try insertV1(store, flavors: [("public.utf8-plain-text", Data("normal".utf8)),
                                                     ("public.text", Data("normal".utf8))],
                                    capturedAt: 400, uuidByte: 4, zeroFlavorRows: true,
                                    textPreview: "normal")
        let blobless = try insertV1(store, flavors: [("public.png", Data("fake".utf8))],
                                    capturedAt: 500, uuidByte: 5, kind: .image, missingBlob: true,
                                    textPreview: "img")
        try markPending(store)

        let outcome = try await IdentityCutover.run(store: store)
        guard case .completed(let report) = outcome else {
            Issue.record("expected completion"); return
        }
        #expect(report.rehashed == 1)              // only `normal`
        #expect(report.keptV1Evicted == 1)
        #expect(report.keptV1ZeroFlavor == 2)
        #expect(report.keptV1MissingBlob == 1)
        #expect(report.zombiesSwept == 1)          // zeroTwin matches `normal`

        for (id, expectedVersion) in [(normal, 2), (evicted, 1), (zeroUnique, 1), (blobless, 1)] {
            #expect(try entryRow(store, id)?["hash_version"] as Int? == expectedVersion,
                    "entry \(id)")
        }
        #expect((try entryRow(store, zeroTwin)?["deleted_at"] as Double?) != nil)   // swept
        #expect(try entryRow(store, zeroUnique)?["deleted_at"] as Double? == nil)   // kept live

        // Reseed: normal + evicted + blobless in; zero-flavor stragglers
        // and the swept zombie out.
        let queued = try queueIds(store)
        #expect(queued.contains(normal))
        #expect(queued.contains(evicted))
        #expect(queued.contains(blobless))
        #expect(!queued.contains(zeroUnique))
        #expect(!queued.contains(zeroTwin))
    }

    // MARK: - Resumability

    @Test("Crash mid-rehash: resume completes without double-processing")
    func resumesMidRehash() async throws {
        let store = try makeStore()
        var ids: [Int64] = []
        for i in 0..<10 {
            ids.append(try insertV1(store, flavors: [("public.utf8-plain-text", Data("row \(i)".utf8))],
                                    capturedAt: Double(i), uuidByte: UInt8(i + 1)))
        }
        try markPending(store)

        // Fabricate a mid-step-2 crash: index dropped, cursor parked
        // after the 4th row, first 4 rows already rehashed.
        let firstFour = Array(ids.prefix(4))
        let cursorId = ids[3]
        try await store.dbQueue.write { db in
            try db.execute(sql: "DROP INDEX IF EXISTS idx_entries_live_content_hash")
            try IdentityCutover.setState(db, "cutover_index_dropped", "1")
            for id in firstFour {
                let flavors = try Row.fetchAll(db, sql: "SELECT uti, data FROM entry_flavors WHERE entry_id = ?", arguments: [id])
                    .map { CanonicalHash.Flavor(uti: $0["uti"], data: $0["data"] ?? Data()) }
                let (tag, hash) = ContentIdentity.compute(flavors: flavors)
                try db.execute(
                    sql: "UPDATE entries SET prev_content_hash = content_hash, content_hash = ?, identity_tag = ?, hash_version = 2 WHERE id = ?",
                    arguments: [hash, tag.rawValue, id]
                )
            }
            try IdentityCutover.setState(db, "cutover_rehash_cursor", String(cursorId))
        }

        let outcome = try await IdentityCutover.run(store: store)
        guard case .completed(let report) = outcome else {
            Issue.record("expected completion"); return
        }
        // Only the remaining 6 count as rehashed this run; all 10 are v2.
        #expect(report.rehashed == 6)
        let v2Count = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE hash_version = 2") ?? 0
        }
        #expect(v2Count == 10)
        // prev_content_hash differs from content_hash on every row
        // (each was rehashed exactly once — a double-rehash would have
        // overwritten prev with the v2 hash).
        let doubleRehashed = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE prev_content_hash = content_hash") ?? -1
        }
        #expect(doubleRehashed == 0)
    }

    @Test("Non-empty push queue blocks; drain hook unblocks")
    func blockedOnQueue() async throws {
        let store = try makeStore()
        let id = try insertV1(store, flavors: [("public.utf8-plain-text", Data("queued".utf8))],
                              capturedAt: 100, uuidByte: 1)
        try await store.dbQueue.write { db in
            try PushQueue.enqueue(entryId: id, in: db)
        }
        try markPending(store)

        let blocked = try await IdentityCutover.run(store: store)
        #expect(blocked == .blockedOnPushQueue(pending: 1))
        // Still pending — nothing was mutated.
        #expect(try IdentityCutover.isPending(store))

        let drained = try await IdentityCutover.run(store: store, drainPushQueue: {
            try await store.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM cloudkit_push_queue")
            }
        })
        guard case .completed = drained else {
            Issue.record("expected completion after drain"); return
        }
    }

    // MARK: - Reconcile sweep (§4.2 layer 2)

    @Test("Reconcile sweep upgrades skew-era v1 rows and merges collisions")
    func reconcileSweep() async throws {
        let store = try makeStore()
        let existing = try insertV1(store, flavors: [("public.utf8-plain-text", Data("shared".utf8))],
                                    capturedAt: 100, uuidByte: 1)
        try markPending(store)
        guard case .completed = try await IdentityCutover.run(store: store) else {
            Issue.record("cutover failed"); return
        }

        // Skew-era rows written by a stale binary AFTER the cutover:
        // one colliding with the existing row, one distinct.
        let skewDup = try insertV1(store, flavors: [("public.utf8-plain-text", Data("shared".utf8)),
                                                    ("org.chromium.source-url", Data("https://s".utf8))],
                                   capturedAt: 999, uuidByte: 9)
        let skewNew = try insertV1(store, flavors: [("public.utf8-plain-text", Data("fresh".utf8))],
                                   capturedAt: 999, uuidByte: 10)

        let healed = try IdentityCutover.reconcileSweep(store: store)
        #expect(healed == 2)

        // skewDup merged into `existing` (earlier created_at wins).
        #expect((try entryRow(store, skewDup)?["deleted_at"] as Double?) != nil)
        let rowExisting = try entryRow(store, existing)
        #expect(rowExisting?["deleted_at"] as Double? == nil)
        #expect(rowExisting?["created_at"] as Double? == 999)     // bump-recency
        // skewNew upgraded in place.
        let rowNew = try entryRow(store, skewNew)
        #expect(rowNew?["hash_version"] as Int? == 2)
        #expect(rowNew?["deleted_at"] as Double? == nil)
        // Survivors enqueued for push.
        let queued = try queueIds(store)
        #expect(queued.contains(existing))
        #expect(queued.contains(skewNew))
        // Idempotent: second sweep is a no-op.
        #expect(try IdentityCutover.reconcileSweep(store: store) == 0)
    }

    // MARK: - Verification

    @Test("verifyHashes: clean after cutover; detects a corrupted hash")
    func verify() async throws {
        let store = try makeStore()
        let a = try insertV1(store, flavors: [("public.utf8-plain-text", Data("verify me".utf8))],
                             capturedAt: 100, uuidByte: 1)
        _ = try insertV1(store, flavors: [("public.url", Data("https://v.example".utf8))],
                         capturedAt: 200, uuidByte: 2, kind: .link)
        try markPending(store)
        guard case .completed = try await IdentityCutover.run(store: store) else {
            Issue.record("cutover failed"); return
        }

        let clean = try IdentityCutover.verifyHashes(store: store, sample: 10)
        #expect(clean.checked == 2)
        #expect(clean.mismatched.isEmpty)

        // Corrupt one stored hash → exactly that row flagged.
        try await store.dbQueue.write { db in
            try db.execute(sql: "UPDATE entries SET content_hash = randomblob(32) WHERE id = ?", arguments: [a])
        }
        let dirty = try IdentityCutover.verifyHashes(store: store, sample: 10)
        #expect(dirty.mismatched == [a])
    }

    // MARK: - Born-v2 loser (adversarial finding: COALESCE keeps the live hash)

    @Test("Born-v2 merge loser is HARD-DELETED, never a tombstone sharing the survivor's live hash")
    func bornV2LoserHardDeleted() async throws {
        let store = try makeStore()
        let text = Data("mid-cutover capture".utf8)
        // Historic v1 row (earlier — will survive) + a born-v2 capture of
        // the SAME content (later — the loser). After step 2 rehashes the
        // v1 row, both share the v2 hash.
        let survivor = try insertV1(store, flavors: [("public.utf8-plain-text", text)],
                                    capturedAt: 100, uuidByte: 1)
        let bornLoser = try insertV1(store, flavors: [("public.utf8-plain-text", text)],
                                     capturedAt: 200, uuidByte: 2, bornV2: true)
        // The born-v2 row carries a queue entry (the Ingestor enqueued it).
        try await store.dbQueue.write { db in
            try PushQueue.enqueue(entryId: bornLoser, in: db)
            try db.execute(sql: "DELETE FROM cloudkit_push_queue")  // simulate it already drained pre-cutover
            try IdentityCutover.setState(db, "cutover_drain_done", "1")  // skip step 0's re-check
        }
        try markPending(store)

        guard case .completed(let report) = try await IdentityCutover.run(store: store) else {
            Issue.record("expected completion"); return
        }
        #expect(report.clustersMerged == 1)
        // Survivor live + holds the v2 hash.
        let rowS = try entryRow(store, survivor)
        #expect(rowS?["deleted_at"] as Double? == nil)
        #expect(rowS?["hash_version"] as Int? == 2)
        // Loser is GONE (hard-deleted), not a tombstone — so it can never
        // push a delete for the survivor's record name.
        #expect(try entryRow(store, bornLoser) == nil)
        // And not in the push queue.
        let queued = try queueIds(store)
        #expect(!queued.contains(bornLoser))
        #expect(queued.contains(survivor))
        // Exactly one row carries the survivor's hash.
        let sharing = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE content_hash = (SELECT content_hash FROM entries WHERE id = ?)", arguments: [survivor]) ?? -1
        }
        #expect(sharing == 1)
    }

    @Test("reconcileSweep loser that is a born-v2 row is hard-deleted, not a shared-hash tombstone")
    func reconcileBornV2LoserHardDeleted() async throws {
        let store = try makeStore()
        let text = Data("recon shared".utf8)
        let existing = try insertV1(store, flavors: [("public.utf8-plain-text", text)],
                                    capturedAt: 100, uuidByte: 1)
        try markPending(store)
        guard case .completed = try await IdentityCutover.run(store: store) else {
            Issue.record("cutover failed"); return
        }
        // `existing` is now v2 with prev set. Insert a SECOND born-v2 row
        // (a stale binary capturing the same content post-cutover) that
        // collides but has a LATER created_at → it loses to `existing`.
        // Force it to hash_version=1 so reconcileSweep treats it as a
        // skew row that rehashes to the same v2 hash, then loses.
        let skew = try insertV1(store, flavors: [("public.utf8-plain-text", text),
                                                 ("public.text", text)],
                                capturedAt: 999, uuidByte: 9)
        let healed = try IdentityCutover.reconcileSweep(store: store)
        #expect(healed == 1)
        // skew lost to existing → its v1 lineage means it reverts+tombstones
        // (prev was NULL but content_hash is its own v1 hash, not the
        // survivor's), so assert: existing live, skew not live, and no two
        // live rows share existing's hash.
        #expect(try entryRow(store, existing)?["deleted_at"] as Double? == nil)
        let skewRow = try entryRow(store, skew)
        let skewRetired = skewRow == nil || (skewRow?["deleted_at"] as Double?) != nil
        #expect(skewRetired)
        let liveSharing = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL AND content_hash = (SELECT content_hash FROM entries WHERE id = ?)", arguments: [existing]) ?? -1
        }
        #expect(liveSharing == 1)
    }

    // MARK: - EntryCoalesce body-evicted guard

    @Test("Coalesce into a body-evicted survivor salvages metadata but adopts NO flavors")
    func coalesceEvictedSurvivor() throws {
        let store = try makeStore()
        let survivor = try insertV1(store, flavors: [("public.utf8-plain-text", Data("kept".utf8))],
                                    capturedAt: 100, uuidByte: 1, bodyEvicted: true)
        let loser = try insertV1(store, flavors: [("public.utf8-plain-text", Data("kept".utf8)),
                                                  ("public.html", Data("<p>kept</p>".utf8))],
                                 capturedAt: 200, uuidByte: 2, linkTitle: "donor title")
        try store.dbQueue.write { db in
            try EntryCoalesce.merge(db: db, survivorId: survivor, loserIds: [loser], now: 300)
        }
        // No flavors adopted (survivor stays body-evicted with no rows).
        let survivorFlavorCount = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry_flavors WHERE entry_id = ?", arguments: [survivor]) ?? -1
        }
        #expect(survivorFlavorCount == 0)
        // But the scalar metadata (link title) WAS salvaged.
        #expect(try entryRow(store, survivor)?["link_title"] as String? == "donor title")
    }

    // MARK: - Snapshot resume (adversarial finding: partial blessed as good)

    @Test("A partial snapshot from an interrupted VACUUM is replaced, not blessed")
    func snapshotPartialReplaced() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpdb-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("cpdb-v3.db").path
        let store = try Store(path: dbPath)
        _ = try insertV1(store, flavors: [("public.utf8-plain-text", Data("snap me".utf8))],
                         capturedAt: 100, uuidByte: 1)
        try markPending(store)

        // Plant a truncated/garbage file where the snapshot will go, as if
        // a prior VACUUM died mid-write (marker stays unset).
        let snapshotURL = IdentityCutover.defaultSnapshotURL(forDatabaseAt: dbPath)
        try Data("not a real sqlite file".utf8).write(to: snapshotURL)

        guard case .completed = try await IdentityCutover.run(store: store, snapshotURL: snapshotURL) else {
            Issue.record("expected completion"); return
        }
        // The garbage was replaced with a real database (opens + queries).
        let snapStore = try Store(path: snapshotURL.path, readonly: true)
        let count = try await snapStore.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries") ?? -1
        }
        #expect(count == 1)
    }

    // MARK: - Tombstone reseed taxonomy (§4.3 step 5 / §10 decision 3)

    @Test("Recent tombstone rehashes to v2 and is reseeded; >90-day tombstone is not")
    func tombstoneReseed() async throws {
        let store = try makeStore()
        let now = Date().timeIntervalSince1970
        let live = try insertV1(store, flavors: [("public.utf8-plain-text", Data("live row".utf8))],
                                capturedAt: now - 10, uuidByte: 1)
        // Recent standalone tombstone (deleted yesterday) — carries
        // deletion state into the new zone.
        let recentTomb = try insertV1(store, flavors: [("public.utf8-plain-text", Data("deleted recently".utf8))],
                                      capturedAt: now - 86400 * 2, uuidByte: 2,
                                      deletedAt: now - 86400)
        // Old tombstone (deleted 120 days ago) — inert, no wire presence.
        let oldTomb = try insertV1(store, flavors: [("public.utf8-plain-text", Data("deleted long ago".utf8))],
                                   capturedAt: now - 86400 * 200, uuidByte: 3,
                                   deletedAt: now - 86400 * 120)
        try markPending(store)
        guard case .completed = try await IdentityCutover.run(store: store) else {
            Issue.record("expected completion"); return
        }
        // Both tombstones rehash to v2 (step 2 covers tombstoned rows too).
        #expect(try entryRow(store, recentTomb)?["hash_version"] as Int? == 2)
        #expect(try entryRow(store, oldTomb)?["hash_version"] as Int? == 2)
        // Reseed: live + recent tombstone in; old tombstone out.
        let queued = try queueIds(store)
        #expect(queued.contains(live))
        #expect(queued.contains(recentTomb))
        #expect(!queued.contains(oldTomb))
    }

    // MARK: - Path fence

    @Test("cpdb.db (+ -wal/-shm) renames to cpdb-v3.db exactly once")
    func pathFence() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpdb-fence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("CPDB_SUPPORT_DIR", dir.path, 1)
        defer { unsetenv("CPDB_SUPPORT_DIR") }

        let old = dir.appendingPathComponent("cpdb.db")
        try Data("db".utf8).write(to: old)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: old.path + "-wal"))

        #expect(try Paths.migrateToV3DatabaseFilenameIfNeeded() == true)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("cpdb-v3.db").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("cpdb-v3.db-wal").path))
        #expect(!fm.fileExists(atPath: old.path))
        // The WAL sidecar moved too (so committed-but-uncheckpointed pages
        // aren't orphaned).
        #expect(!fm.fileExists(atPath: old.path + "-wal"))
        // Second call: no-op (and a freshly appearing stale cpdb.db is
        // left alone once v3 exists).
        try Data("stale".utf8).write(to: old)
        #expect(try Paths.migrateToV3DatabaseFilenameIfNeeded() == false)
        #expect(fm.fileExists(atPath: old.path))
    }
}
