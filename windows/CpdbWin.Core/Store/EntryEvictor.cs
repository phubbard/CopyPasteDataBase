using Microsoft.Data.Sqlite;

namespace CpdbWin.Core.Store;

/// <summary>
/// Time-window <b>body eviction</b> for cold entries. Windows port of
/// macOS v2.6.2 <c>Sources/CpdbShared/EntryEvictor.swift</c>.
///
/// <para>
/// <b>Body-only, NOT a full tombstone.</b> An evicted row survives with
/// its metadata (title, text_preview, chips, thumbnails, FTS index),
/// so it stays searchable and browseable — only the raw flavor bytes
/// go. The <c>body_evicted_at</c> sentinel (v7 column, unused until
/// now) records the eviction moment; <see cref="HistoryExporter"/>
/// filters on it (<c>--include-evicted</c> exposes evicted rows).
/// This is deliberately different from <see cref="EntryRepository.TombstoneMany"/>,
/// which soft-deletes the whole row and drops it from FTS.
/// </para>
///
/// <para>
/// <b>Contract</b>:
/// <list type="bullet">
///   <item><description><b>Anchor</b> = <c>created_at</c> (dedup bumps
///     it; a re-copy legitimately refreshes the entry's clock).
///     Matches Mac's predicate byte-for-byte. Not <c>captured_at</c>
///     (would evict frequently-re-copied things too eagerly) and
///     not <c>modified_at</c> (pin/unpin would refresh the age).</description></item>
///   <item><description><b>Pinned rows always skipped</b>, no override
///     flag. Pinning is the user's escape valve — <c>docs/schema.md
///     §Pinning</c> says every eviction policy must honor it.</description></item>
///   <item><description><b>Already-evicted rows skipped</b>
///     (<c>body_evicted_at IS NULL</c> in the predicate), so
///     <see cref="EvictOlderThan"/> is idempotent: two calls with the
///     same cutoff evict the same rows once.</description></item>
/// </list>
/// </para>
///
/// <para>
/// <b>Two-phase blob cleanup</b> mirrors Mac's ordering:
/// <list type="number">
///   <item><description>Inside one transaction: sum inline flavor
///     bytes, collect DISTINCT blob_keys the doomed flavors reference,
///     <c>DELETE FROM entry_flavors</c>, stamp
///     <c>body_evicted_at</c>. Committed as a unit — a crash mid-txn
///     rolls back the flavor delete, so no row is left in a
///     "metadata-only but body_evicted_at unset" limbo.</description></item>
///   <item><description>Post-commit: for each candidate blob key, re-
///     check whether any surviving flavor still references it; if
///     not, <see cref="BlobStore.Delete"/>. Missed files (permission,
///     race, "already gone" from a concurrent GC) are safe — the
///     periodic <see cref="Gc.CleanOrphanBlobs"/> sweep will mop
///     them up on its next pass.</description></item>
/// </list>
/// Deliberately post-commit rather than pre-delete: a rollback of
/// phase 1 must not have already lost bytes.
/// </para>
/// </summary>
public sealed class EntryEvictor
{
    /// <summary>Mac's default via <c>EvictionPrefs.timeWindowDaysDefault</c>.
    /// UI/daemon should use the same for policy runs; this constant
    /// mirrors it so a future Windows daemon has one place to
    /// configure.</summary>
    public const int DefaultDays = 90;

    /// <summary>Below-clamp reject (matches Mac's
    /// <c>timeWindowDaysMin</c>). Anything shorter is almost certainly
    /// a fat-fingered CLI arg; refuse rather than silently wipe the
    /// user's recent clipboard.</summary>
    public const int MinDays = 7;

    /// <summary>Above-clamp reject (Mac's <c>timeWindowDaysMax</c>,
    /// ~10 years). Not policy-motivated, just a sanity fence.</summary>
    public const int MaxDays = 3650;

    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;

    public EntryEvictor(SqliteConnection db, BlobStore blobs)
    {
        _db    = db;
        _blobs = blobs;
    }

    /// <summary>Structured outcome. <c>EntryCount</c> counts rows whose
    /// bodies were dropped (not tombstoned — the rows survive).
    /// <c>InlineFlavorBytesFreed</c> covers the &lt;256 KB inline path;
    /// <c>BlobBytesFreed</c> covers the out-of-line path.
    /// <c>BlobsRemoved</c> is the number of blob files actually
    /// unlinked (a subset of the DISTINCT blob keys — some may still
    /// be referenced by other flavors and stay).</summary>
    public readonly record struct Report(
        int  EntryCount,
        long InlineFlavorBytesFreed,
        long BlobBytesFreed,
        int  BlobsRemoved);

    /// <summary>Ids of live, unpinned, un-evicted entries whose
    /// <c>created_at</c> is older than <c>now - days*86400</c>. Used
    /// both as the dry-run preview source and as input to
    /// <see cref="Evict"/>. Callers of the CLI pass this to a formatter
    /// and print the count before deciding to run.</summary>
    public IReadOnlyList<long> CandidatesOlderThan(int days, DateTimeOffset? now = null)
    {
        ValidateDays(days);
        var cutoff = ((now ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0)
                   - (days * 86_400.0);

        var ids = new List<long>();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            SELECT id
            FROM entries
            WHERE deleted_at IS NULL
              AND pinned = 0
              AND body_evicted_at IS NULL
              AND created_at < $cutoff
            """;
        cmd.Parameters.AddWithValue("$cutoff", cutoff);
        using var r = cmd.ExecuteReader();
        while (r.Read()) ids.Add(r.GetInt64(0));
        return ids;
    }

    /// <summary>One-shot: find candidates, evict, return the report.
    /// Idempotent — a second call with the same cutoff finds nothing.</summary>
    public Report EvictOlderThan(int days, DateTimeOffset? now = null)
    {
        var ids = CandidatesOlderThan(days, now);
        return ids.Count == 0
            ? new Report(0, 0, 0, 0)
            : Evict(ids, now);
    }

    /// <summary>Body-evict the given entry ids. Two-phase: SQL work
    /// in one transaction, blob unlinks post-commit. Ids not matching
    /// the candidate predicate (already evicted, pinned, tombstoned,
    /// unknown id) are silently skipped — safer than throwing when a
    /// concurrent mutation stole a row from under us.</summary>
    public Report Evict(IReadOnlyList<long> entryIds, DateTimeOffset? now = null)
    {
        if (entryIds.Count == 0) return new Report(0, 0, 0, 0);
        var ts = (now ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;
        var idList = string.Join(",", entryIds);  // caller-supplied longs — no injection risk

        long inlineBytes = 0;
        int  entryCount  = 0;
        var  candidateBlobKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        using (var tx = _db.BeginTransaction())
        {
            // Sum inline bytes about to disappear. `data` is the BLOB
            // column for &lt;256 KB flavors; length() returns bytes.
            using (var cmd = _db.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = $"""
                    SELECT COALESCE(SUM(length(data)), 0)
                    FROM entry_flavors
                    WHERE entry_id IN ({idList}) AND data IS NOT NULL
                    """;
                inlineBytes = Convert.ToInt64(cmd.ExecuteScalar() ?? 0L);
            }

            // Snapshot DISTINCT blob keys the doomed flavors reference —
            // must happen before the flavor delete strips them.
            using (var cmd = _db.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = $"""
                    SELECT DISTINCT blob_key
                    FROM entry_flavors
                    WHERE entry_id IN ({idList}) AND blob_key IS NOT NULL
                    """;
                using var r = cmd.ExecuteReader();
                while (r.Read()) candidateBlobKeys.Add(r.GetString(0));
            }

            // Drop the flavor bytes. ON DELETE not needed — this is a
            // scoped WHERE, not a cascade — but the effect is identical:
            // rows in entry_flavors for these entries go away.
            using (var cmd = _db.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = $"DELETE FROM entry_flavors WHERE entry_id IN ({idList})";
                cmd.ExecuteNonQuery();
            }

            // Stamp body_evicted_at on the surviving entries. Same
            // predicate as CandidatesOlderThan so we don't accidentally
            // over-mark tombstoned / pinned / already-evicted rows a
            // caller passed us — silent per-row skip.
            using (var cmd = _db.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = $"""
                    UPDATE entries
                    SET body_evicted_at = $t
                    WHERE id IN ({idList})
                      AND deleted_at IS NULL
                      AND pinned = 0
                      AND body_evicted_at IS NULL
                    """;
                cmd.Parameters.AddWithValue("$t", ts);
                entryCount = cmd.ExecuteNonQuery();
            }

            tx.Commit();
        }

        // Post-commit blob unlink. Per-key re-check: only delete when no
        // surviving flavor references the key any more. Missed unlinks
        // fall through to the periodic Gc.CleanOrphanBlobs sweep.
        long blobBytes = 0;
        int  blobsRemoved = 0;
        foreach (var key in candidateBlobKeys)
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = "SELECT 1 FROM entry_flavors WHERE blob_key = $k LIMIT 1";
            cmd.Parameters.AddWithValue("$k", key);
            var stillReferenced = cmd.ExecuteScalar() is not null;
            if (stillReferenced) continue;

            var path = _blobs.PathFor(key);
            long size = 0;
            try { size = new FileInfo(path).Length; } catch { /* stat may fail; keep going */ }

            try
            {
                _blobs.Delete(key);
                blobsRemoved++;
                blobBytes += size;
            }
            catch
            {
                // Locked / permissions / already-gone from a concurrent
                // GC — safe to ignore; next Gc.CleanOrphanBlobs picks it
                // up on the next sweep.
            }
        }

        return new Report(entryCount, inlineBytes, blobBytes, blobsRemoved);
    }

    private static void ValidateDays(int days)
    {
        if (days < MinDays || days > MaxDays)
            throw new ArgumentOutOfRangeException(nameof(days),
                $"days must be in [{MinDays}, {MaxDays}]; got {days}");
    }
}
