import Foundation
import GRDB

/// The canonical-hash v2 cutover routine (docs/canonical-hash-v2.md §4).
///
/// Runs once per database, AFTER `Store.open()` (which only applied the
/// thin `v10_semantic_identity` schema migration), off the main actor, on
/// foreground launches only. Sync must be disabled while
/// `cutover_pending` is set — `CloudKitSyncer` checks `isPending` at the
/// top of push and pull.
///
/// Steps (each records completion in `cutover_state`, so a crash anywhere
/// resumes cleanly):
///   0. enforced quiesce — refuse to proceed while the old-zone push
///      queue is non-empty (the caller-provided drain hook gets one shot)
///   1. snapshot via `VACUUM INTO` (WAL-consistent; a naive file copy
///      would silently drop up to 1000 uncheckpointed WAL pages)
///   2. chunked rehash, live AND tombstoned, ~200 rows per transaction,
///      resumable via an id cursor. The live-hash unique index is dropped
///      for the duration (two rows converging on one v2 hash would
///      otherwise abort the UPDATE mid-step).
///   3. collision merge — survivor = earliest created_at, tie smallest
///      uuid; coalesce via `EntryCoalesce`; losers tombstoned and
///      REVERTED to their v1 hash (so exactly one row holds each v2 hash
///      — re-keyed losers would shadow pull lookups). Recreating the
///      unique index doubles as the loud assertion that no duplicate
///      live hash survived.
///   4. zombie sweep — tombstone zero-flavor v1 live rows whose preview
///      matches another live row (body-less; their origin uuid may have
///      lost a merge, so "the origin re-delivers" would never fire)
///   5. sync-state cutover — wipe tokens + queue, reseed the push queue
///      per the §4.3 taxonomy, set the pull-before-push latch, clear
///      `cutover_pending`.
public enum IdentityCutover {

    // MARK: - cutover_state keys

    static let pendingKey = "cutover_pending"
    static let drainDoneKey = "cutover_drain_done"
    static let snapshotDoneKey = "cutover_snapshot_done"
    static let indexDroppedKey = "cutover_index_dropped"
    static let rehashCursorKey = "cutover_rehash_cursor"
    static let rehashDoneKey = "cutover_rehash_done"
    static let mergeDoneKey = "cutover_merge_done"
    static let zombieDoneKey = "cutover_zombie_done"
    static let completedAtKey = "cutover_completed_at"
    /// Read by the syncer (Step 4): push returns empty until one full
    /// successful pull has completed post-cutover.
    public static let pullBeforePushLatchKey = "pull_before_push_latch"

    /// Tombstones younger than this carry deletion state into the new
    /// zone (maintainer decision: 90 days).
    public static let tombstoneReseedWindowSeconds: Double = 90 * 86400

    static let rehashBatchSize = 200

    // MARK: - Public surface

    public struct Report: Sendable, Equatable {
        public var rehashed = 0
        public var keptV1Evicted = 0
        public var keptV1ZeroFlavor = 0
        public var keptV1MissingBlob = 0
        public var clustersMerged = 0
        public var losersTombstoned = 0
        public var zombiesSwept = 0
        public var reseeded = 0
        public init() {}
    }

    public enum Outcome: Sendable, Equatable {
        /// No cutover_pending marker — fresh install or already done.
        case notNeeded
        /// The push queue still holds old-zone mutations and the drain
        /// hook couldn't empty it (offline). Retry next launch; the
        /// cutover never proceeds past step 0 with pending pushes.
        case blockedOnPushQueue(pending: Int)
        case completed(Report)
    }

    /// True while the database needs (or is mid-way through) the cutover.
    /// The syncer gates push/pull on this.
    public static func isPending(_ db: Database) throws -> Bool {
        try state(db, pendingKey) != nil
    }

    public static func isPending(_ store: Store) throws -> Bool {
        try store.dbQueue.read { try isPending($0) }
    }

    /// Run the cutover to completion (or to a blocking condition).
    ///
    /// - Parameters:
    ///   - snapshotURL: where `VACUUM INTO` writes the pre-migration
    ///     snapshot. Pass nil to skip (tests; in-memory stores can't
    ///     VACUUM INTO anyway). Defaults to `<db-path>.pre-v10` when the
    ///     store is file-backed — derive it via `defaultSnapshotURL`.
    ///   - drainPushQueue: one chance to flush old-zone mutations before
    ///     the queue is wiped (the app passes the syncer's push; tests
    ///     pass nil or a spy).
    public static func run(
        store: Store,
        blobs: BlobStore = BlobStore(),
        snapshotURL: URL? = nil,
        drainPushQueue: (() async throws -> Void)? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Outcome {
        guard try isPending(store) else { return .notNeeded }

        // Step 0 — enforced quiesce. Runs ONCE: a completion marker stops
        // a resume from re-checking the queue, which by then may hold
        // mid-cutover v2 captures that step 5 wipes-and-reseeds anyway.
        // Re-running it would also dead-end against the cutover-gated push
        // (the drain hook must bypass that gate — Step 4 wiring; until
        // then `drainPushQueue` is nil and a non-empty queue simply
        // blocks, which is the correct conservative behavior).
        if try await store.dbQueue.read({ try state($0, drainDoneKey) == nil }) {
            var queued = try await store.dbQueue.read { db in try PushQueue.count(in: db) }
            if queued > 0 {
                progress?("draining \(queued) pending old-zone pushes")
                try await drainPushQueue?()
                queued = try await store.dbQueue.read { db in try PushQueue.count(in: db) }
                if queued > 0 {
                    progress?("still \(queued) pending — cutover blocked until the drain succeeds")
                    return .blockedOnPushQueue(pending: queued)
                }
            }
            try await store.dbQueue.write { db in try setState(db, drainDoneKey, "1") }
        }

        // Step 1 — snapshot (file-backed stores only). Trust the marker,
        // NOT file existence: an interrupted VACUUM INTO leaves a partial,
        // corrupt file, and blessing that as the recovery backup defeats
        // the snapshot's entire purpose. Marker unset ⇒ no known-good
        // snapshot ⇒ delete any partial and re-vacuum. Safe to redo: the
        // rehash hasn't started, so the source DB is byte-unchanged.
        if let snapshotURL, try await store.dbQueue.read({ try state($0, snapshotDoneKey) == nil }) {
            progress?("writing pre-migration snapshot")
            try? FileManager.default.removeItem(at: snapshotURL)
            try await store.dbQueue.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM INTO ?", arguments: [snapshotURL.path])
            }
            try await store.dbQueue.write { db in
                try setState(db, snapshotDoneKey, "1")
            }
        }

        var report = Report()

        // Step 2 — chunked rehash.
        if try await store.dbQueue.read({ try state($0, rehashDoneKey) == nil }) {
            try await store.dbQueue.write { db in
                guard try state(db, indexDroppedKey) == nil else { return }
                try db.execute(sql: "DROP INDEX IF EXISTS idx_entries_live_content_hash")
                try setState(db, indexDroppedKey, "1")
            }
            progress?("rehashing entries")
            try await rehashAll(store: store, blobs: blobs, report: &report)
            try await store.dbQueue.write { db in
                try setState(db, rehashDoneKey, "1")
            }
        }

        // Step 3 — collision merge + index restore.
        if try await store.dbQueue.read({ try state($0, mergeDoneKey) == nil }) {
            progress?("merging identity collisions")
            let (clusters, losers) = try await store.dbQueue.write { db -> (Int, Int) in
                let r = try mergeCollisions(db: db)
                // Recreating the partial unique index is the loud
                // assertion: any remaining duplicate live hash fails here,
                // inside the same transaction, rolling the merge back.
                try db.execute(sql: """
                    CREATE UNIQUE INDEX IF NOT EXISTS idx_entries_live_content_hash
                        ON entries(content_hash) WHERE deleted_at IS NULL
                    """)
                try clearState(db, indexDroppedKey)
                try setState(db, mergeDoneKey, "1")
                return r
            }
            report.clustersMerged = clusters
            report.losersTombstoned = losers
        }

        // Step 4 — zombie sweep.
        if try await store.dbQueue.read({ try state($0, zombieDoneKey) == nil }) {
            let swept = try await store.dbQueue.write { db -> Int in
                let n = try sweepZombies(db: db)
                try setState(db, zombieDoneKey, "1")
                return n
            }
            report.zombiesSwept = swept
        }

        // Step 5 — sync-state cutover + latch + un-pend.
        let reseeded = try await store.dbQueue.write { db -> Int in
            let now = Date().timeIntervalSince1970
            try db.execute(sql: "DELETE FROM cloudkit_state")
            try db.execute(sql: "DELETE FROM cloudkit_push_queue")
            try db.execute(
                sql: """
                    INSERT INTO cloudkit_push_queue (entry_id, enqueued_at, attempt_count)
                    SELECT e.id, ?, 0 FROM entries e
                    WHERE (e.deleted_at IS NULL
                             AND NOT (e.hash_version = 1
                                      AND e.body_evicted_at IS NULL
                                      AND NOT EXISTS (SELECT 1 FROM entry_flavors f WHERE f.entry_id = e.id)))
                       OR (e.deleted_at IS NOT NULL AND e.deleted_at >= ? AND e.hash_version = 2)
                    """,
                arguments: [now, now - tombstoneReseedWindowSeconds]
            )
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloudkit_push_queue") ?? 0
            try setState(db, pullBeforePushLatchKey, "1")
            try setState(db, completedAtKey, String(now))
            for key in [pendingKey, drainDoneKey, snapshotDoneKey, rehashCursorKey, rehashDoneKey, mergeDoneKey, zombieDoneKey] {
                try clearState(db, key)
            }
            return n
        }
        report.reseeded = reseeded
        progress?("cutover complete: \(report.rehashed) rehashed, \(report.clustersMerged) clusters merged, \(reseeded) reseeded")
        return .completed(report)
    }

    /// Default snapshot location for a file-backed store.
    public static func defaultSnapshotURL(forDatabaseAt path: String) -> URL {
        URL(fileURLWithPath: path + ".pre-v10")
    }

    // MARK: - Step 2 internals

    private static func rehashAll(
        store: Store,
        blobs: BlobStore,
        report: inout Report
    ) async throws {
        while true {
            let processed = try await store.dbQueue.write { db -> (Int, Report) in
                var batchReport = Report()
                let cursor = Int64(try state(db, rehashCursorKey) ?? "0") ?? 0
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, content_hash, hash_version, body_evicted_at, deleted_at
                        FROM entries WHERE id > ? ORDER BY id LIMIT ?
                        """,
                    arguments: [cursor, rehashBatchSize]
                )
                guard !rows.isEmpty else { return (0, batchReport) }
                for row in rows {
                    let id: Int64 = row["id"]
                    let isLive = (row["deleted_at"] as Double?) == nil
                    // Already v2 (resume after crash, or a row inserted by
                    // the new Ingestor mid-cutover): recompute is a no-op
                    // by definition — skip.
                    if (row["hash_version"] as Int? ?? 1) >= 2 { continue }
                    if (row["body_evicted_at"] as Double?) != nil {
                        if isLive { batchReport.keptV1Evicted += 1 }
                        continue
                    }
                    let flavorRows = try Row.fetchAll(
                        db,
                        sql: "SELECT uti, data, blob_key FROM entry_flavors WHERE entry_id = ?",
                        arguments: [id]
                    )
                    if flavorRows.isEmpty {
                        if isLive { batchReport.keptV1ZeroFlavor += 1 }
                        continue
                    }
                    var flavors: [CanonicalHash.Flavor] = []
                    var blobMissing = false
                    for f in flavorRows {
                        do {
                            let bytes = try blobs.load(inline: f["data"], blobKey: f["blob_key"])
                            flavors.append(.init(uti: f["uti"], data: bytes))
                        } catch {
                            blobMissing = true
                            Log.store.error("cutover: blob unreadable for entry \(id) uti \(f["uti"] as String? ?? "?", privacy: .public) — keeping v1 hash")
                            break
                        }
                    }
                    if blobMissing {
                        if isLive { batchReport.keptV1MissingBlob += 1 }
                        continue
                    }
                    let (tag, hash) = ContentIdentity.compute(flavors: flavors)
                    try db.execute(
                        sql: """
                            UPDATE entries SET prev_content_hash = content_hash,
                                content_hash = ?, identity_tag = ?, hash_version = 2
                            WHERE id = ?
                            """,
                        arguments: [hash, tag.rawValue, id]
                    )
                    batchReport.rehashed += 1
                }
                let lastId: Int64 = rows.last!["id"]
                try setState(db, rehashCursorKey, String(lastId))
                return (rows.count, batchReport)
            }
            report.rehashed += processed.1.rehashed
            report.keptV1Evicted += processed.1.keptV1Evicted
            report.keptV1ZeroFlavor += processed.1.keptV1ZeroFlavor
            report.keptV1MissingBlob += processed.1.keptV1MissingBlob
            if processed.0 == 0 { break }
        }
    }

    // MARK: - Step 3 internals

    /// Group live v2 rows by hash; merge each n>1 cluster. Returns
    /// (clusters, losersTombstoned). Caller wraps in a transaction.
    static func mergeCollisions(db: Database) throws -> (Int, Int) {
        let now = Date().timeIntervalSince1970
        let dupHashes = try Data.fetchAll(
            db,
            sql: """
                SELECT content_hash FROM entries
                WHERE deleted_at IS NULL AND hash_version = 2
                GROUP BY content_hash HAVING COUNT(*) > 1
                """
        )
        var losers = 0
        for hash in dupHashes {
            // Survivor: earliest created_at, tie-break smallest uuid —
            // both synced, so every device picks the same survivor.
            let ids = try Int64.fetchAll(
                db,
                sql: """
                    SELECT id FROM entries
                    WHERE content_hash = ? AND deleted_at IS NULL
                    ORDER BY created_at ASC, uuid ASC
                    """,
                arguments: [hash]
            )
            guard ids.count > 1 else { continue }
            let survivor = ids[0]
            let loserIds = Array(ids.dropFirst())
            try EntryCoalesce.merge(db: db, survivorId: survivor, loserIds: loserIds, now: now)
            for loser in loserIds {
                try retireLoser(db: db, loserId: loser, now: now)
            }
            losers += loserIds.count
        }
        return (dupHashes.count, losers)
    }

    /// Retire a collision-merge loser AFTER `EntryCoalesce.merge` has
    /// salvaged everything onto the survivor. The goal: no LIVE row other
    /// than the survivor ends up holding the survivor's content_hash.
    /// Three cases:
    ///
    ///   - **born-v2 (hash_version 2, prev_content_hash NULL)** — a
    ///     mid-cutover Ingestor capture of content whose historic twin
    ///     hadn't been rehashed yet. Its content_hash IS the survivor's
    ///     live v2 hash and there is no v1 hash to fall back to, so a
    ///     tombstone would keep sharing it — and `reconcileSweep` (push
    ///     open) could push that tombstone and delete the survivor's
    ///     record fleet-wide. Born-v2 rows were never pushed (push is
    ///     gated during cutover; reconcileSweep enqueues only survivors)
    ///     and are byte-identical to the survivor, so HARD-DELETE — FK
    ///     cascade cleans the flavor/preview/pinboard rows the survivor
    ///     already adopted. The survivor pushes under the shared record
    ///     name and converges.
    ///
    ///   - **rehashed (prev_content_hash present)** — revert to the v1
    ///     hash and tombstone. The v1 hash is unaddressable in cpdb-v3, so
    ///     the tombstone is inert; the reseed excludes it by hash_version.
    ///
    ///   - **untouched v1 (hash_version 1, prev NULL)** — a skew-era row
    ///     whose own content_hash is a v1 hash DISTINCT from the
    ///     survivor's. Keep that hash and tombstone: it's already inert
    ///     (its v1 record name addresses only itself, propagating the
    ///     skew row's own deletion if it was ever pushed).
    static func retireLoser(db: Database, loserId: Int64, now: Double) throws {
        let row = try Row.fetchOne(
            db, sql: "SELECT hash_version, prev_content_hash FROM entries WHERE id = ?",
            arguments: [loserId])
        let hashVersion = row?["hash_version"] as Int? ?? 1
        let prev = row?["prev_content_hash"] as Data?
        try FtsIndex.removeEntry(db: db, entryId: loserId)
        if hashVersion >= 2 && prev == nil {
            // born-v2: hard delete (its hash == the survivor's live hash)
            try PushQueue.remove(entryId: loserId, in: db)
            try db.execute(sql: "DELETE FROM entries WHERE id = ?", arguments: [loserId])
        } else {
            // rehashed → revert to prev v1 hash; untouched-v1 → keep its
            // own v1 hash. Either way tombstone with an inert v1 hash.
            try db.execute(
                sql: """
                    UPDATE entries SET deleted_at = ?,
                        content_hash = COALESCE(?, content_hash),
                        hash_version = 1, identity_tag = NULL
                    WHERE id = ?
                    """,
                arguments: [now, prev, loserId]
            )
        }
    }

    // MARK: - Step 4 internals

    /// Tombstone zero-flavor v1 LIVE rows whose trimmed preview (or title
    /// when previewless) matches another live row. Body-less by
    /// definition — nothing is lost — and it pre-empts permanent ghosts
    /// whose origin uuid lost a collision merge (losers are never pushed,
    /// so "the origin re-delivers" never fires for them). No enqueue.
    static func sweepZombies(db: Database) throws -> Int {
        let now = Date().timeIntervalSince1970
        let zombies = try Row.fetchAll(
            db,
            sql: """
                SELECT e.id, TRIM(COALESCE(e.text_preview, e.title, '')) AS k
                FROM entries e
                WHERE e.deleted_at IS NULL AND e.hash_version = 1
                  AND e.body_evicted_at IS NULL
                  AND NOT EXISTS (SELECT 1 FROM entry_flavors f WHERE f.entry_id = e.id)
                """
        )
        var swept = 0
        for z in zombies {
            let key: String = z["k"]
            guard !key.isEmpty else { continue }
            let id: Int64 = z["id"]
            let hasTwin = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM entries
                        WHERE deleted_at IS NULL AND id != ?
                          AND TRIM(COALESCE(text_preview, title, '')) = ?
                    )
                    """,
                arguments: [id, key]
            ) ?? false
            if hasTwin {
                try db.execute(sql: "UPDATE entries SET deleted_at = ? WHERE id = ?", arguments: [now, id])
                try FtsIndex.removeEntry(db: db, entryId: id)
                swept += 1
            }
        }
        return swept
    }

    // MARK: - Launch reconcile sweep (§4.2 layer 2)

    /// Heal binary-skew-era rows: any live v1 row with flavors and no
    /// body eviction gets rehashed (and merged if its v2 hash collides
    /// with a live row). Runs on every foreground launch post-cutover —
    /// normally a no-op since nothing writes v1 rows anymore. The unique
    /// index is LIVE here, so collisions are handled per-row: tombstone
    /// the loser first, then re-key the survivor.
    @discardableResult
    public static func reconcileSweep(
        store: Store,
        blobs: BlobStore = BlobStore(),
        limit: Int = 500
    ) throws -> Int {
        guard try !isPending(store) else { return 0 }
        let candidates = try store.dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT e.id FROM entries e
                    WHERE e.deleted_at IS NULL AND e.hash_version = 1
                      AND e.body_evicted_at IS NULL
                      AND EXISTS (SELECT 1 FROM entry_flavors f WHERE f.entry_id = e.id)
                    ORDER BY e.id LIMIT ?
                    """,
                arguments: [limit]
            )
        }
        var healed = 0
        for id in candidates {
            try store.dbQueue.write { db in
                let now = Date().timeIntervalSince1970
                // Re-check inside the transaction (the row may have been
                // merged away by an earlier iteration of this loop).
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT content_hash, created_at, uuid FROM entries WHERE id = ? AND deleted_at IS NULL AND hash_version = 1",
                    arguments: [id]
                ) else { return }
                let flavorRows = try Row.fetchAll(
                    db,
                    sql: "SELECT uti, data, blob_key FROM entry_flavors WHERE entry_id = ?",
                    arguments: [id]
                )
                var flavors: [CanonicalHash.Flavor] = []
                for f in flavorRows {
                    guard let bytes = try? blobs.load(inline: f["data"], blobKey: f["blob_key"]) else { return }
                    flavors.append(.init(uti: f["uti"], data: bytes))
                }
                guard !flavors.isEmpty else { return }
                let (tag, hash) = ContentIdentity.compute(flavors: flavors)

                if let twin = try Row.fetchOne(
                    db,
                    sql: "SELECT id, created_at, uuid FROM entries WHERE content_hash = ? AND deleted_at IS NULL",
                    arguments: [hash]
                ) {
                    // Collision: deterministic survivor (earliest
                    // created_at, tie smallest uuid).
                    let twinId: Int64 = twin["id"]
                    let rowWins = (row["created_at"] as Double, (row["uuid"] as Data).hexEncodedLowercase)
                        < (twin["created_at"] as Double, (twin["uuid"] as Data).hexEncodedLowercase)
                    let survivor = rowWins ? id : twinId
                    let loser = rowWins ? twinId : id
                    try EntryCoalesce.merge(db: db, survivorId: survivor, loserIds: [loser], now: now)
                    try retireLoser(db: db, loserId: loser, now: now)
                    if survivor == id {
                        // The v1 row won: re-key it now that the loser no
                        // longer holds the v2 hash live.
                        try db.execute(
                            sql: """
                                UPDATE entries SET prev_content_hash = content_hash,
                                    content_hash = ?, identity_tag = ?, hash_version = 2
                                WHERE id = ?
                                """,
                            arguments: [hash, tag.rawValue, id]
                        )
                    }
                    try PushQueue.enqueue(entryId: survivor, in: db, now: now)
                } else {
                    try db.execute(
                        sql: """
                            UPDATE entries SET prev_content_hash = content_hash,
                                content_hash = ?, identity_tag = ?, hash_version = 2
                            WHERE id = ?
                            """,
                        arguments: [hash, tag.rawValue, id]
                    )
                    try PushQueue.enqueue(entryId: id, in: db, now: now)
                }
                healed += 1
            }
        }
        if healed > 0 {
            Log.store.info("reconcile sweep healed \(healed) skew-era v1 rows")
        }
        return healed
    }

    // MARK: - Verification (§4.5)

    public struct VerifyResult: Sendable, Equatable {
        public var checked = 0
        public var mismatched: [Int64] = []
        public var unreadable: [Int64] = []
    }

    /// Recompute v2 identity for a random sample of live, flavored,
    /// hash_version=2 rows and compare against the stored hash.
    public static func verifyHashes(
        store: Store,
        blobs: BlobStore = BlobStore(),
        sample: Int = 200
    ) throws -> VerifyResult {
        let ids = try store.dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT e.id FROM entries e
                    WHERE e.deleted_at IS NULL AND e.hash_version = 2
                      AND e.body_evicted_at IS NULL
                      AND EXISTS (SELECT 1 FROM entry_flavors f WHERE f.entry_id = e.id)
                    ORDER BY RANDOM() LIMIT ?
                    """,
                arguments: [sample]
            )
        }
        var result = VerifyResult()
        for id in ids {
            let (stored, flavorRows) = try store.dbQueue.read { db -> (Data?, [Row]) in
                let h = try Data.fetchOne(db, sql: "SELECT content_hash FROM entries WHERE id = ?", arguments: [id])
                let f = try Row.fetchAll(db, sql: "SELECT uti, data, blob_key FROM entry_flavors WHERE entry_id = ?", arguments: [id])
                return (h, f)
            }
            var flavors: [CanonicalHash.Flavor] = []
            var unreadable = false
            for f in flavorRows {
                do {
                    flavors.append(.init(uti: f["uti"], data: try blobs.load(inline: f["data"], blobKey: f["blob_key"])))
                } catch {
                    unreadable = true
                    break
                }
            }
            if unreadable { result.unreadable.append(id); continue }
            let (_, hash) = ContentIdentity.compute(flavors: flavors)
            result.checked += 1
            if hash != stored { result.mismatched.append(id) }
        }
        return result
    }

    // MARK: - cutover_state plumbing

    static func state(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM cutover_state WHERE key = ?", arguments: [key])
    }

    static func setState(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute(
            sql: """
                INSERT INTO cutover_state (key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """,
            arguments: [key, value, Date().timeIntervalSince1970]
        )
    }

    static func clearState(_ db: Database, _ key: String) throws {
        try db.execute(sql: "DELETE FROM cutover_state WHERE key = ?", arguments: [key])
    }
}

private extension Data {
    /// Lowercase hex, used only for deterministic uuid tie-breaks (byte
    /// order == hex order, so comparing hex strings is comparing bytes).
    var hexEncodedLowercase: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
