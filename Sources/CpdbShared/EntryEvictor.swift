import Foundation
import GRDB

/// Tier-2 eviction policy executor.
///
/// Discards flavor body bytes (entry_flavors rows + on-disk blobs
/// under the BlobStore) for entries that match the policy's
/// criteria, leaving metadata + thumbnails intact. Pinned and
/// already-evicted rows are skipped.
///
/// Two callers today:
///
///   - The Mac daemon's daily task — runs the configured policy
///     on a wall-clock schedule.
///   - The `cpdb evict` CLI — manual, with `--dry-run` for
///     pre-check and explicit `--before-days N` to override the
///     stored preference.
///
/// Future:
///   - Size-budget LRU policy (v2.6.3) shares the same workhorse
///     `evict(entryIds:)` method — the policy decides which ids,
///     the evictor does the work.
public struct EntryEvictor {
    public let store: Store
    public let blobs: BlobStore

    public init(store: Store, blobs: BlobStore = BlobStore()) {
        self.store = store
        self.blobs = blobs
    }

    /// What `evict` did. Surfaced to the caller for logging and
    /// CLI display ("evicted N entries, freed X MB").
    public struct Report: Sendable, Equatable {
        public var entryCount: Int
        public var inlineFlavorBytesFreed: Int64
        public var blobBytesFreed: Int64
        public var blobsRemoved: Int

        public var totalBytesFreed: Int64 {
            inlineFlavorBytesFreed + blobBytesFreed
        }

        public init(
            entryCount: Int = 0,
            inlineFlavorBytesFreed: Int64 = 0,
            blobBytesFreed: Int64 = 0,
            blobsRemoved: Int = 0
        ) {
            self.entryCount = entryCount
            self.inlineFlavorBytesFreed = inlineFlavorBytesFreed
            self.blobBytesFreed = blobBytesFreed
            self.blobsRemoved = blobsRemoved
        }
    }

    /// Find entries older than `days`, with bodies still present,
    /// not pinned, not tombstoned. Returns ids only — `evict()`
    /// turns ids into actual deletion.
    public func candidatesOlderThan(days: Int) throws -> [Int64] {
        let cutoff = Date().timeIntervalSince1970 - Double(days) * 86_400
        return try store.dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT id FROM entries
                    WHERE deleted_at IS NULL
                      AND pinned = 0
                      AND body_evicted_at IS NULL
                      AND created_at < ?
                """,
                arguments: [cutoff]
            )
        }
    }

    /// Convenience wrapper for the time-window policy. Picks
    /// candidates and evicts in one shot. Idempotent — entries that
    /// have already been body-evicted are skipped by
    /// `candidatesOlderThan`.
    @discardableResult
    public func evictOlderThan(days: Int) throws -> Report {
        let ids = try candidatesOlderThan(days: days)
        return try evict(entryIds: ids)
    }

    /// Workhorse: discard bodies for the given entry ids.
    ///
    /// Sequence:
    ///   1. Inside one write txn: collect blob_keys to remove,
    ///      delete entry_flavors rows, set body_evicted_at on
    ///      entries, enqueue for CloudKit push so siblings learn.
    ///   2. After txn commits, unlink the on-disk blob files.
    ///      Doing this AFTER the commit is intentional: if the
    ///      txn rolled back partway, we'd have unrecoverable
    ///      bytes loss. Doing it after means a crash between (1)
    ///      and (2) leaves an orphan blob — `cpdb gc` cleans
    ///      those up.
    @discardableResult
    public func evict(entryIds ids: [Int64]) throws -> Report {
        guard !ids.isEmpty else { return Report() }
        let now = Date().timeIntervalSince1970

        struct PerTxnResult {
            var inlineBytes: Int64
            var blobKeysToRemove: [String]
        }
        let result = try store.dbQueue.write { db -> PerTxnResult in
            // Build the IN-list once. SQLite supports limited list
            // length; for tens of thousands chunk this loop, but we
            // expect time-window eviction to surface ~tens to ~few
            // thousand at a time, well under the 32k argument cap.
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let args = StatementArguments(ids)

            // Sum inline bytes that are about to vanish (for the
            // Report).
            let inlineBytes = try Int64.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(IFNULL(LENGTH(data), 0)), 0)
                    FROM entry_flavors
                    WHERE entry_id IN (\(placeholders))
                """,
                arguments: args
            ) ?? 0

            // Collect blob keys (DISTINCT — content-addressed
            // dedup means many entries can reference one blob).
            let blobKeys = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT blob_key FROM entry_flavors
                    WHERE entry_id IN (\(placeholders))
                      AND blob_key IS NOT NULL
                """,
                arguments: args
            )

            // Drop the flavor rows.
            try db.execute(
                sql: "DELETE FROM entry_flavors WHERE entry_id IN (\(placeholders))",
                arguments: args
            )

            // Mark the entries body-evicted so future pulls don't
            // re-hydrate them, and enqueue for CloudKit push so
            // siblings learn the new state.
            try db.execute(
                sql: """
                    UPDATE entries
                    SET body_evicted_at = ?
                    WHERE id IN (\(placeholders))
                """,
                arguments: StatementArguments([now]) + args
            )
            for id in ids {
                try PushQueue.enqueue(entryId: id, in: db, now: now)
            }

            return PerTxnResult(inlineBytes: inlineBytes, blobKeysToRemove: blobKeys)
        }

        // Now delete the on-disk blobs. Each was deduplicated by
        // SHA-256 — if any other entry STILL references the same
        // blob (legitimate, content-hashed dedup), don't unlink.
        // We re-check inside the loop because the txn already
        // closed and the answer is now cheap.
        var blobBytesFreed: Int64 = 0
        var blobsRemoved = 0
        let fm = FileManager.default
        for key in result.blobKeysToRemove {
            // Re-check: is anyone else still pointing at this key?
            let stillReferenced: Bool = try store.dbQueue.read { db in
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM entry_flavors WHERE blob_key = ?",
                    arguments: [key]
                ) ?? 0
                return count > 0
            }
            if stillReferenced { continue }

            let url = Paths.blobPath(forSHA256Hex: key)
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64
            {
                blobBytesFreed += size
            }
            do {
                try fm.removeItem(at: url)
                blobsRemoved += 1
            } catch CocoaError.fileNoSuchFile {
                // Already gone (cpdb gc beat us, or partial run).
                // Counts as success for our purposes.
                blobsRemoved += 1
            } catch {
                // Log-and-continue: a stuck blob isn't worth
                // failing the whole eviction. cpdb gc can sweep
                // later.
                Log.cli.error(
                    "evict: failed to remove blob \(key, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }

        return Report(
            entryCount: ids.count,
            inlineFlavorBytesFreed: result.inlineBytes,
            blobBytesFreed: blobBytesFreed,
            blobsRemoved: blobsRemoved
        )
    }
}
