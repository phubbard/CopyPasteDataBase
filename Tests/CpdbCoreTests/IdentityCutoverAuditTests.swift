import Testing
import Foundation
import GRDB
@testable import CpdbCore
@testable import CpdbShared

/// Integration test of the full cutover against a COPY of the real
/// production snapshot (`/tmp/cpdb-audit.db`, captured 2026-06-09 from
/// v2.10.1 / schema v9). Gated on the snapshot's presence — runs on the
/// maintainer's machine, silently skips everywhere else.
///
/// The expected numbers are pinned from the Step-0 simulation gate
/// (docs/canonical-hash-v2.md §9 step 0): 475 would-merge clusters,
/// 538 excess rows, 6 zero-flavor (evicted) live entries — all verified
/// against flavor-level inspection with zero false merges.
///
/// Blob-spilled flavors read from the REAL blob store (read-only) via
/// the default `BlobStore` paths; rows whose blobs have since been
/// evicted from the live system surface as keptV1MissingBlob rather
/// than failures.
@Suite("Identity cutover — production snapshot integration",
       .enabled(if: FileManager.default.fileExists(atPath: "/tmp/cpdb-audit.db")))
struct IdentityCutoverAuditTests {

    @Test("Full cutover on the audit snapshot matches the simulation gate", .timeLimit(.minutes(10)))
    func auditCutover() async throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("cpdb-audit-cutover-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }
        let dbPath = workDir.appendingPathComponent("cpdb-v3.db").path
        try fm.copyItem(atPath: "/tmp/cpdb-audit.db", toPath: dbPath)

        // Opening runs the migrator: v10 adds the columns and — because
        // entries is non-empty — sets cutover_pending.
        let store = try Store(path: dbPath)
        #expect(try IdentityCutover.isPending(store))

        // Simulate the drained old-zone state (the snapshot may carry a
        // live push queue; step 0 would otherwise block).
        try await store.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM cloudkit_push_queue")
        }

        let snapshotURL = IdentityCutover.defaultSnapshotURL(forDatabaseAt: dbPath)
        let outcome = try await IdentityCutover.run(
            store: store,
            snapshotURL: snapshotURL,
            progress: { print("  [cutover] \($0)") }
        )
        guard case .completed(let report) = outcome else {
            Issue.record("expected completion, got \(outcome)"); return
        }
        print("  [cutover] report: \(report)")

        // INVARIANTS, not exact counts: the snapshot is a live copy that
        // grows as the maintainer uses cpdb daily, so the precise cluster
        // count drifts (the canonical 475 is pinned by the Step-0
        // simulation in Tools/sim_identity_final.py against whatever
        // snapshot is present). What MUST hold regardless of size:
        //  - every merged cluster yields at least one loser
        //  - the count is in the right order of magnitude (a regression
        //    that merged nothing, or merged everything, would escape an
        //    exact-equality check rebased to the new snapshot but not this)
        #expect(report.clustersMerged >= report.losersTombstoned / 4)   // clusters are mostly pairs/triples
        #expect(report.losersTombstoned >= report.clustersMerged)        // >=1 loser per cluster
        #expect(report.clustersMerged > 300 && report.clustersMerged < 800)
        #expect(report.keptV1ZeroFlavor < 50)
        print("  [cutover] note: keptV1MissingBlob=\(report.keptV1MissingBlob) (blobs evicted since snapshot keep their row at v1)")

        // Snapshot file written and is a valid database.
        #expect(fm.fileExists(atPath: snapshotURL.path))

        // The recreated unique index held — count live duplicate hashes.
        let dupLive = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                    SELECT content_hash FROM entries WHERE deleted_at IS NULL
                    GROUP BY content_hash HAVING COUNT(*) > 1
                )
                """) ?? -1
        }
        #expect(dupLive == 0)

        // Hash verification on a healthy sample.
        let verify = try IdentityCutover.verifyHashes(store: store, sample: 250)
        #expect(verify.mismatched.isEmpty)
        #expect(verify.checked > 200)
        print("  [cutover] verify: \(verify.checked) checked, \(verify.mismatched.count) mismatched, \(verify.unreadable.count) unreadable")

        // Reseed sanity: queue ≈ live rows minus zero-flavor stragglers
        // plus recent v2 tombstones; must be non-trivial.
        let queueCount = try await store.dbQueue.read { db in
            try PushQueue.count(in: db)
        }
        print("  [cutover] reseeded \(queueCount) rows")
        #expect(queueCount > 9000)

        // The famous production pair: ids 9807/9808 (Chrome jitter, same
        // caddy config 19s apart). The Step-0 simulation showed they're
        // part of a FOUR-member cluster, so both may be losers to an
        // earlier sibling — the correct assertion is that exactly ONE
        // live row carries that text identity, and 9807/9808 are not
        // both alive.
        let (caddyLiveTotal, pairLive) = try await store.dbQueue.read { db -> (Int, Int) in
            let preview = try String.fetchOne(
                db, sql: "SELECT TRIM(text_preview) FROM entries WHERE id = 9807") ?? ""
            let total = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM entries
                WHERE deleted_at IS NULL AND TRIM(COALESCE(text_preview,'')) = ?
                """, arguments: [preview]) ?? -1
            let pair = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM entries
                WHERE id IN (9807, 9808) AND deleted_at IS NULL
                """) ?? -1
            return (total, pair)
        }
        #expect(caddyLiveTotal == 1)
        #expect(pairLive <= 1)
    }
}
