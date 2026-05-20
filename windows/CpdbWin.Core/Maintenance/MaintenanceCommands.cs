using CpdbWin.Core.Capture;
using CpdbWin.Core.Ingest;
using Microsoft.Data.Sqlite;

namespace CpdbWin.Core.Maintenance;

/// <summary>
/// One-shot data-cleanup operations exposed to the CLI. Each method
/// runs synchronously inside a single SQLite transaction, returns a
/// <see cref="MaintenanceResult"/> with row counts the caller can
/// report, and is safe to invoke against a database that the GUI app
/// is also using (WAL mode handles concurrent reads + a single writer).
///
/// Mirrors the macOS CLI subcommands documented in
/// <c>docs/parity.md</c>: <c>reclassify-kinds</c>,
/// <c>backfill-titles --retry-empty</c>, <c>dedupe --links-all-time</c>.
/// </summary>
public static class MaintenanceCommands
{
    /// <summary>
    /// Walk every live entry and apply the current
    /// <see cref="KindClassifier"/> to each row's flavor set. When the
    /// new classification differs from the stored kind, update the row
    /// in place. On <c>text → link</c> drift, also clear
    /// <c>link_title</c> / <c>link_fetched_at</c> /
    /// <c>link_retry_count</c> / <c>link_retry_after</c> so the row
    /// re-enters the metadata backfill candidate pool. Mirrors macOS
    /// <c>cpdb reclassify-kinds</c> (v2.7.14).
    /// </summary>
    public static MaintenanceResult ReclassifyKinds(SqliteConnection db)
    {
        int scanned = 0;
        int reclassified = 0;
        int linkStateReset = 0;

        using var tx = db.BeginTransaction();

        // Pull the candidate set first so we can iterate without holding
        // a reader open while we issue UPDATEs (Microsoft.Data.Sqlite
        // disallows nested commands on the same connection while a
        // reader is active).
        var ids = new List<long>();
        using (var cmd = db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "SELECT id FROM entries WHERE deleted_at IS NULL";
            using var r = cmd.ExecuteReader();
            while (r.Read()) ids.Add(r.GetInt64(0));
        }

        foreach (var id in ids)
        {
            scanned++;

            // Fetch flavors for the row and re-run the classifier. Same
            // shape as Ingestor.Ingest's classify call, but pulled from
            // the DB rather than a snapshot.
            var flavors = LoadFlavors(db, tx, id);
            if (flavors.Count == 0) continue;
            var newKind = KindClassifier.Classify(flavors);

            string? oldKind = LookupKind(db, tx, id);
            if (oldKind is null || oldKind == newKind) continue;

            // Update kind + reset link state on text→link drift.
            using (var upd = db.CreateCommand())
            {
                upd.Transaction = tx;
                upd.CommandText = "UPDATE entries SET kind = $k WHERE id = $id";
                upd.Parameters.AddWithValue("$k", newKind);
                upd.Parameters.AddWithValue("$id", id);
                upd.ExecuteNonQuery();
            }
            reclassified++;

            if (newKind == "link")
            {
                using (var upd = db.CreateCommand())
                {
                    upd.Transaction = tx;
                    upd.CommandText = """
                        UPDATE entries
                        SET link_title = NULL,
                            link_fetched_at = NULL,
                            link_retry_count = 0,
                            link_retry_after = NULL
                        WHERE id = $id
                        """;
                    upd.Parameters.AddWithValue("$id", id);
                    upd.ExecuteNonQuery();
                }
                linkStateReset++;
            }
        }

        tx.Commit();
        return new MaintenanceResult(scanned, reclassified, linkStateReset);
    }

    /// <summary>
    /// Clear <c>link_fetched_at</c> + retry state for kind=link rows
    /// whose <c>link_title</c> is null or empty, putting them back in
    /// the candidate pool for the next backfill cycle. The candidate
    /// query also gates on <c>link_retry_count &lt; MAX_RETRIES</c>, so
    /// we reset that too — a user invoking this command is explicitly
    /// asking for "try these again." Mirrors macOS
    /// <c>cpdb backfill-titles --retry-empty</c> (v2.7.8).
    /// </summary>
    public static MaintenanceResult RetryEmptyLinks(SqliteConnection db)
    {
        using var cmd = db.CreateCommand();
        cmd.CommandText = """
            UPDATE entries
            SET link_fetched_at = NULL,
                link_retry_count = 0,
                link_retry_after = NULL
            WHERE kind = 'link'
              AND deleted_at IS NULL
              AND (link_title IS NULL OR link_title = '')
              AND link_fetched_at IS NOT NULL
            """;
        var n = cmd.ExecuteNonQuery();
        return new MaintenanceResult(Scanned:n, Reclassified:0, LinkStateReset:n);
    }

    /// <summary>
    /// Clear <c>link_fetched_at</c>, <c>link_title</c>, and retry state
    /// on every live kind=link row so the backfill loop re-fetches
    /// every title from scratch. Used to re-apply newer fetcher logic
    /// (e.g. the WordPress-aware precedence added in v1.30.0) to rows
    /// that already settled under older rules. Stronger than
    /// <see cref="RetryEmptyLinks"/> — that one only re-arms titles
    /// that came back blank; this one wipes successful settlements
    /// too. The actual fetch happens afterwards via the running
    /// <c>LinkBackfillService</c> or the CLI's drain loop; this just
    /// re-arms the candidate set. Mirrors the macOS Preferences
    /// "Refetch all" action.
    /// </summary>
    public static MaintenanceResult RefetchAllLinks(SqliteConnection db)
    {
        using var tx = db.BeginTransaction();

        // Clear the persisted title on entries first, then rebuild
        // the FTS row's link_title shadow column the same way
        // EntryRepository.SettleLink does for a single row — kept in
        // one transaction so search index and storage agree.
        int n;
        using (var cmd = db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                UPDATE entries
                SET link_fetched_at = NULL,
                    link_title       = NULL,
                    link_retry_count = 0,
                    link_retry_after = NULL
                WHERE kind = 'link' AND deleted_at IS NULL
                """;
            n = cmd.ExecuteNonQuery();
        }
        using (var cmd = db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                UPDATE entries_fts
                SET link_title = ''
                WHERE rowid IN (
                    SELECT id FROM entries
                    WHERE kind = 'link' AND deleted_at IS NULL
                )
                """;
            cmd.ExecuteNonQuery();
        }
        tx.Commit();
        return new MaintenanceResult(Scanned: n, Reclassified: 0, LinkStateReset: n);
    }

    /// <summary>
    /// Clear the OCR-pass sentinel (<c>ocr_at</c>) on every live image
    /// entry so the analyzer re-runs OCR for each. Does not touch
    /// <c>tags_at</c> — the classifier-tags pass is independently
    /// gated. Used by Preferences "Re-OCR images". Actual OCR is done
    /// by <see cref="ImageAnalysisService"/> (running app) or the
    /// CLI's drain loop; this just re-arms the OCR candidate set.
    /// </summary>
    public static MaintenanceResult ResetImageOcr(SqliteConnection db)
    {
        using var cmd = db.CreateCommand();
        cmd.CommandText = """
            UPDATE entries
            SET ocr_at = NULL
            WHERE kind = 'image' AND deleted_at IS NULL
            """;
        var n = cmd.ExecuteNonQuery();
        return new MaintenanceResult(Scanned: n, Reclassified: 0, LinkStateReset: n);
    }

    /// <summary>
    /// Clear the classifier-pass sentinel (<c>tags_at</c>) on every
    /// live image so the analyzer re-runs classification. Does not
    /// touch <c>ocr_at</c>. Used by Preferences "Re-tag images".
    /// </summary>
    public static MaintenanceResult ResetImageTags(SqliteConnection db)
    {
        using var cmd = db.CreateCommand();
        cmd.CommandText = """
            UPDATE entries
            SET tags_at = NULL
            WHERE kind = 'image' AND deleted_at IS NULL
            """;
        var n = cmd.ExecuteNonQuery();
        return new MaintenanceResult(Scanned: n, Reclassified: 0, LinkStateReset: n);
    }

    /// <summary>
    /// Combined: clear both passes' sentinels (<c>ocr_at</c> +
    /// <c>tags_at</c> + the unified <c>analyzed_at</c>) so the
    /// analyzer re-runs both. Used by the CLI's <c>analyze-images
    /// --force</c>. The Preferences pane prefers the per-pass
    /// <see cref="ResetImageOcr"/> / <see cref="ResetImageTags"/>.
    /// </summary>
    public static MaintenanceResult ResetImageAnalysis(SqliteConnection db)
    {
        using var cmd = db.CreateCommand();
        cmd.CommandText = """
            UPDATE entries
            SET ocr_at = NULL,
                tags_at = NULL,
                analyzed_at = NULL
            WHERE kind = 'image' AND deleted_at IS NULL
            """;
        var n = cmd.ExecuteNonQuery();
        return new MaintenanceResult(Scanned: n, Reclassified: 0, LinkStateReset: n);
    }

    /// <summary>
    /// Cross-time link collapse: for each text_preview URL with multiple
    /// live kind=link rows, keep one survivor (newest <c>created_at</c>)
    /// and tombstone the rest. Before tombstoning, salvage the survivor's
    /// missing <c>link_title</c> from any sibling that has one — covers
    /// the case where an earlier capture got the title and a later one
    /// hit a transient that never recovered. Mirrors macOS
    /// <c>cpdb dedupe --links-all-time</c> (v2.7.9).
    /// </summary>
    public static MaintenanceResult DedupeLinksAllTime(SqliteConnection db)
    {
        int salvaged = 0;
        int tombstoned = 0;

        using var tx = db.BeginTransaction();

        // Find URL groups with more than one live kind=link row. For
        // each group, return (canonical url, count, newest_id). We use
        // text_preview as the URL key since the candidate query gates
        // on the same column.
        var groups = new List<(string Url, long SurvivorId)>();
        using (var cmd = db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                SELECT text_preview, COUNT(*),
                       (SELECT id FROM entries e2
                        WHERE e2.kind = 'link'
                          AND e2.deleted_at IS NULL
                          AND e2.text_preview = e.text_preview
                        ORDER BY e2.created_at DESC LIMIT 1) AS survivor
                FROM entries e
                WHERE e.kind = 'link'
                  AND e.deleted_at IS NULL
                  AND e.text_preview IS NOT NULL
                GROUP BY text_preview
                HAVING COUNT(*) > 1
                """;
            using var r = cmd.ExecuteReader();
            while (r.Read())
            {
                groups.Add((r.GetString(0), r.GetInt64(2)));
            }
        }

        var nowSec = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

        foreach (var (url, survivorId) in groups)
        {
            // Salvage step: if the survivor lacks link_title, look for
            // any sibling that has one and copy it over. Same for
            // link_fetched_at sentinels (a settled sibling means we've
            // already paid the fetch cost).
            var (survivorTitle, survivorFetchedAt) = LookupLinkState(db, tx, survivorId);
            if (string.IsNullOrEmpty(survivorTitle))
            {
                using var sel = db.CreateCommand();
                sel.Transaction = tx;
                sel.CommandText = """
                    SELECT link_title, link_fetched_at FROM entries
                    WHERE kind = 'link' AND deleted_at IS NULL
                      AND text_preview = $u
                      AND id <> $survivor
                      AND link_title IS NOT NULL AND link_title <> ''
                    ORDER BY link_fetched_at DESC LIMIT 1
                    """;
                sel.Parameters.AddWithValue("$u", url);
                sel.Parameters.AddWithValue("$survivor", survivorId);
                using var sr = sel.ExecuteReader();
                if (sr.Read())
                {
                    var donorTitle = sr.GetString(0);
                    var donorFetchedAt = sr.IsDBNull(1) ? (double?)null : sr.GetDouble(1);
                    sr.Close();

                    using var upd = db.CreateCommand();
                    upd.Transaction = tx;
                    upd.CommandText = """
                        UPDATE entries
                        SET link_title = $t,
                            link_fetched_at = COALESCE($f, link_fetched_at)
                        WHERE id = $id
                        """;
                    upd.Parameters.AddWithValue("$t", donorTitle);
                    upd.Parameters.AddWithValue("$f", (object?)donorFetchedAt ?? DBNull.Value);
                    upd.Parameters.AddWithValue("$id", survivorId);
                    upd.ExecuteNonQuery();
                    salvaged++;
                }
            }

            // Tombstone every sibling. Schema-style soft delete.
            using (var upd = db.CreateCommand())
            {
                upd.Transaction = tx;
                upd.CommandText = """
                    UPDATE entries
                    SET deleted_at = $now
                    WHERE kind = 'link' AND deleted_at IS NULL
                      AND text_preview = $u
                      AND id <> $survivor
                    """;
                upd.Parameters.AddWithValue("$now", nowSec);
                upd.Parameters.AddWithValue("$u", url);
                upd.Parameters.AddWithValue("$survivor", survivorId);
                tombstoned += upd.ExecuteNonQuery();
            }

            // Pull the FTS rows for the tombstoned siblings so search
            // doesn't surface them. Note: we delete by URL match rather
            // than tracking per-id since INSERT INTO entries_fts is
            // keyed on rowid = entries.id and Tombstone(...) elsewhere
            // does the same delete. This is per-survivor cleanup.
            using (var cmd = db.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = """
                    DELETE FROM entries_fts
                    WHERE rowid IN (
                        SELECT id FROM entries
                        WHERE kind = 'link' AND deleted_at = $now
                          AND text_preview = $u
                          AND id <> $survivor
                    )
                    """;
                cmd.Parameters.AddWithValue("$now", nowSec);
                cmd.Parameters.AddWithValue("$u", url);
                cmd.Parameters.AddWithValue("$survivor", survivorId);
                cmd.ExecuteNonQuery();
            }
        }

        tx.Commit();
        return new MaintenanceResult(Scanned:groups.Count, Reclassified:salvaged, LinkStateReset:tombstoned);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    private static List<CanonicalHash.Flavor> LoadFlavors(SqliteConnection db, SqliteTransaction tx, long entryId)
    {
        var list = new List<CanonicalHash.Flavor>();
        using var cmd = db.CreateCommand();
        cmd.Transaction = tx;
        // Inline-only — we don't need blob-spillover bytes for kind
        // classification (KindClassifier checks UTI strings + image
        // size, both available without the actual bytes). For UTIs
        // that need bytes (image substantive check uses Data.Length),
        // pull `size` from the entry_flavors row and build a
        // zero-filled buffer of that length so the >= 1024 check
        // sees the right magnitude.
        cmd.CommandText = """
            SELECT uti, size, data FROM entry_flavors WHERE entry_id = $id
            """;
        cmd.Parameters.AddWithValue("$id", entryId);
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            var uti = r.GetString(0);
            var size = r.GetInt64(1);
            byte[] bytes;
            if (!r.IsDBNull(2))
            {
                bytes = (byte[])r.GetValue(2);
            }
            else
            {
                // Blob-spilled flavor: substitute a same-length zero
                // buffer. KindClassifier only inspects byte length on
                // image flavors and reads UTF-8 for plain text. The
                // text flavor is unlikely to be > 256 KB (the inline
                // threshold), so this branch primarily fires for
                // image flavors where length is the only thing that
                // matters.
                bytes = new byte[size];
            }
            list.Add(new CanonicalHash.Flavor(uti, bytes));
        }
        return list;
    }

    private static string? LookupKind(SqliteConnection db, SqliteTransaction tx, long id)
    {
        using var cmd = db.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = "SELECT kind FROM entries WHERE id = $id";
        cmd.Parameters.AddWithValue("$id", id);
        var v = cmd.ExecuteScalar();
        return v is null or DBNull ? null : (string)v;
    }

    private static (string? title, double? fetchedAt) LookupLinkState(
        SqliteConnection db, SqliteTransaction tx, long id)
    {
        using var cmd = db.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = "SELECT link_title, link_fetched_at FROM entries WHERE id = $id";
        cmd.Parameters.AddWithValue("$id", id);
        using var r = cmd.ExecuteReader();
        if (!r.Read()) return (null, null);
        var title = r.IsDBNull(0) ? null : r.GetString(0);
        var fetchedAt = r.IsDBNull(1) ? (double?)null : r.GetDouble(1);
        return (title, fetchedAt);
    }
}

/// <summary>
/// Counts returned by each maintenance command. The interpretation of
/// the field names is per-command:
/// <list type="bullet">
/// <item><b>ReclassifyKinds</b>: <c>scanned</c> = live rows examined,
///       <c>reclassified</c> = rows whose kind changed,
///       <c>linkStateReset</c> = rows whose link_* fields were cleared
///       (subset of reclassified — only text→link drift).</item>
/// <item><b>RetryEmptyLinks</b>: <c>scanned</c> + <c>linkStateReset</c>
///       are the same value (matched + reset rows). <c>reclassified</c>
///       is unused (always 0).</item>
/// <item><b>DedupeLinksAllTime</b>: <c>scanned</c> = duplicate URL
///       groups found, <c>reclassified</c> = survivors that received a
///       salvaged title from a sibling, <c>linkStateReset</c> =
///       sibling rows tombstoned.</item>
/// </list>
/// </summary>
public readonly record struct MaintenanceResult(int Scanned, int Reclassified, int LinkStateReset);
