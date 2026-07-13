import Foundation
import GRDB

/// Thin DB wrapper around the `cloudkit_push_queue` and `cloudkit_state`
/// tables introduced in schema v3.
///
/// Lives in `CpdbShared/Sync/` rather than `CpdbShared/Store/` because
/// nothing outside the syncer should touch these tables. The syncer
/// dequeues work, pushes to CloudKit, then removes rows on success or
/// updates attempt/error columns on failure.
///
/// All operations run on the caller's dispatch context — the GRDB write
/// pool serialises writes so there's no need for an actor here. Methods
/// take a `Database` so they can compose inside the caller's transaction
/// (e.g. `Ingestor.ingest` enqueues inside the same write that inserts
/// the entry, so the queue can't diverge from the entry table).
public enum PushQueue {

    // MARK: - Queue

    /// Enqueue or re-enqueue an entry. Using INSERT OR REPLACE means
    /// repeated enqueues (e.g. entry gets edited, then tombstoned, then
    /// bumped) collapse into a single row — the syncer will push the
    /// *current* state once, not three times. Attempt count resets on
    /// re-enqueue so a previously-failing row gets another clean run.
    public static func enqueue(entryId: Int64, in db: Database, now: Double = Date().timeIntervalSince1970) throws {
        try db.execute(
            sql: """
                INSERT INTO cloudkit_push_queue (entry_id, enqueued_at, attempt_count)
                VALUES (?, ?, 0)
                ON CONFLICT(entry_id) DO UPDATE SET
                    enqueued_at = excluded.enqueued_at,
                    attempt_count = 0,
                    last_error = NULL
            """,
            arguments: [entryId, now]
        )
    }

    /// Drain up to `limit` rows for the next push batch. Ordered by
    /// `enqueued_at ASC` so the oldest pending change goes first — fair
    /// queuing, and on a fresh v3 the seeded-from-history rows come out
    /// in insert order.
    public struct Pending: Sendable, Equatable {
        public var entryId: Int64
        public var attemptCount: Int
        /// The `enqueued_at` observed when this row was peeked. Passed
        /// back to `remove` so a concurrent re-enqueue (which bumps
        /// `enqueued_at`) survives the in-flight batch's success path —
        /// see `remove`.
        public var enqueuedAt: Double
    }

    public static func peek(limit: Int, in db: Database) throws -> [Pending] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT entry_id, attempt_count, enqueued_at
                FROM cloudkit_push_queue
                ORDER BY enqueued_at ASC
                LIMIT ?
            """,
            arguments: [limit]
        )
        return rows.map {
            Pending(entryId: $0["entry_id"], attemptCount: $0["attempt_count"], enqueuedAt: $0["enqueued_at"])
        }
    }

    /// Remove an entry from the queue after a successful push, BUT only if
    /// it hasn't been re-enqueued since it was peeked. A push spends
    /// seconds-to-minutes staging assets + round-tripping CloudKit; any
    /// mutation to the entry in that window (pin, tombstone, union-bump,
    /// reconcile) calls `enqueue`, bumping `enqueued_at`. Deleting
    /// unconditionally would drop that re-enqueue and lose the edit. The
    /// `enqueued_at <= peeked` guard keeps the newer enqueue so it pushes
    /// next tick. Pass the `enqueuedAt` from the `Pending` that was
    /// peeked; the legacy unqualified form is retained for callers that
    /// don't have it (e.g. retireLoser dequeuing a doomed row).
    public static func remove(entryId: Int64, peekedEnqueuedAt: Double, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM cloudkit_push_queue WHERE entry_id = ? AND enqueued_at <= ?",
            arguments: [entryId, peekedEnqueuedAt]
        )
    }

    /// Unconditional remove — for callers that genuinely want the row
    /// gone regardless of re-enqueue (e.g. a hard-deleted entry). Push
    /// success should use the `peekedEnqueuedAt:` overload.
    public static func remove(entryId: Int64, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM cloudkit_push_queue WHERE entry_id = ?",
            arguments: [entryId]
        )
    }

    /// The `enqueued_at` of the current queue row for `entryId`, or nil
    /// if the entry has no pending push. Used by the pull-side reseed
    /// prune (`CloudKitSyncer.shouldPrunePushQueueRow`) to tell "this
    /// row is still exactly the post-cutover reseed insert" apart from
    /// "this row was re-enqueued since by a genuine local write" — the
    /// two are indistinguishable by `modified_at` alone because several
    /// writers (link metadata/thumbnails, union-bump, body eviction)
    /// enqueue without bumping it.
    public static func enqueuedAt(entryId: Int64, in db: Database) throws -> Double? {
        try Double.fetchOne(
            db,
            sql: "SELECT enqueued_at FROM cloudkit_push_queue WHERE entry_id = ?",
            arguments: [entryId]
        )
    }

    /// Record a failed attempt. Keeps the row so the next drain retries
    /// it; the syncer is responsible for backoff (don't immediately re-
    /// drain a row that just failed).
    public static func markFailure(
        entryId: Int64,
        error: String,
        in db: Database,
        now: Double = Date().timeIntervalSince1970
    ) throws {
        try db.execute(
            sql: """
                UPDATE cloudkit_push_queue
                SET last_attempted_at = ?,
                    attempt_count = attempt_count + 1,
                    last_error = ?
                WHERE entry_id = ?
            """,
            arguments: [now, error, entryId]
        )
    }

    public static func count(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloudkit_push_queue") ?? 0
    }

    // MARK: - Key/value state

    /// Opaque state store for the syncer. Used for zone change tokens
    /// (NSSecureCoding blobs), last-successful-pull timestamps, etc.
    public enum State {
        public static func get(_ key: String, in db: Database) throws -> Data? {
            try Data.fetchOne(
                db,
                sql: "SELECT value FROM cloudkit_state WHERE key = ?",
                arguments: [key]
            )
        }

        public static func set(_ key: String, value: Data, in db: Database) throws {
            try db.execute(
                sql: """
                    INSERT INTO cloudkit_state (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, value]
            )
        }

        public static func delete(_ key: String, in db: Database) throws {
            try db.execute(
                sql: "DELETE FROM cloudkit_state WHERE key = ?",
                arguments: [key]
            )
        }
    }

    /// Well-known keys for the state table. Defined here so the syncer
    /// doesn't sprinkle magic strings through its logic.
    public enum StateKey {
        /// NSSecureCoding-archived `CKServerChangeToken`, namespaced by
        /// zone (canonical-hash v2 cutover to `cpdb-v3`). A bare
        /// un-namespaced key would risk a v3 fetch resuming against a
        /// token minted for the cpdb-v2 zone; the cutover's reseed wipes
        /// `cloudkit_state` regardless, but the explicit namespacing
        /// survives any future zone migration cleanly.
        public static let zoneChangeToken = "zoneChangeToken.cpdb-v3"
    }
}
