using Microsoft.Data.Sqlite;

namespace CpdbWin.Core.Store;

/// <summary>
/// Read-side access for the UI: list / search / fetch a flavor's bytes,
/// tombstone an entry. Write-side ingest still goes through
/// <see cref="Ingest.Ingestor"/>.
/// </summary>
public sealed class EntryRepository
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;

    public EntryRepository(SqliteConnection db, BlobStore blobs)
    {
        _db = db;
        _blobs = blobs;
    }

    private const string SelectEntryColumns = """
        SELECT e.id, e.kind, e.title, e.text_preview,
               e.created_at, e.captured_at, e.total_size,
               a.bundle_id, a.name, p.thumb_small, e.pinned,
               e.link_title
        FROM entries e
        LEFT JOIN apps a ON a.id = e.source_app_id
        LEFT JOIN previews p ON p.entry_id = e.id
        """;

    /// <summary>
    /// Newest live entries first, with pinned rows floated to the top per
    /// docs/schema.md § Pinning. <paramref name="limit"/> caps the row count;
    /// <paramref name="kind"/> narrows to a single <c>entries.kind</c>.
    /// </summary>
    public IReadOnlyList<EntryRow> Recent(int limit = 100, string? kind = null)
    {
        var sql = SelectEntryColumns + """

            WHERE e.deleted_at IS NULL
              AND ($kind IS NULL OR e.kind = $kind)
            ORDER BY e.pinned DESC, e.created_at DESC
            LIMIT $limit
            """;
        return Query(sql, cmd =>
        {
            cmd.Parameters.AddWithValue("$limit", limit);
            cmd.Parameters.AddWithValue("$kind", (object?)kind ?? DBNull.Value);
        });
    }

    /// <summary>
    /// FTS5 MATCH against the <c>entries_fts</c> shadow table, optionally
    /// narrowed to a single <c>entries.kind</c>. Pinned rows float to the
    /// top of the matching set.
    /// </summary>
    public IReadOnlyList<EntryRow> Search(string ftsQuery, int limit = 100, string? kind = null)
    {
        var sql = SelectEntryColumns + """

            JOIN entries_fts f ON f.rowid = e.id
            WHERE entries_fts MATCH $q AND e.deleted_at IS NULL
              AND ($kind IS NULL OR e.kind = $kind)
            ORDER BY e.pinned DESC, e.created_at DESC
            LIMIT $limit
            """;
        return Query(sql, cmd =>
        {
            cmd.Parameters.AddWithValue("$q", ftsQuery);
            cmd.Parameters.AddWithValue("$limit", limit);
            cmd.Parameters.AddWithValue("$kind", (object?)kind ?? DBNull.Value);
        });
    }

    /// <summary>
    /// Toggle the <c>entries.pinned</c> bit for a single row. Per
    /// docs/schema.md § Pinning the column is INTEGER 0/1; the on-disk
    /// representation is just that single update — sort order and
    /// eviction-skip semantics fall out of the existing queries.
    /// </summary>
    public void SetPinned(long entryId, bool pinned)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "UPDATE entries SET pinned = $p WHERE id = $id AND deleted_at IS NULL";
        cmd.Parameters.AddWithValue("$p", pinned ? 1 : 0);
        cmd.Parameters.AddWithValue("$id", entryId);
        cmd.ExecuteNonQuery();
    }

    public IReadOnlyList<FlavorRow> Flavors(long entryId)
    {
        const string sql = """
            SELECT uti, size, data IS NOT NULL, blob_key
            FROM entry_flavors WHERE entry_id = $id
            ORDER BY uti
            """;
        var rows = new List<FlavorRow>();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.Parameters.AddWithValue("$id", entryId);
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            rows.Add(new FlavorRow(
                EntryId: entryId,
                Uti: reader.GetString(0),
                Size: reader.GetInt64(1),
                IsInline: reader.GetInt64(2) != 0,
                BlobKey: reader.IsDBNull(3) ? null : reader.GetString(3)
            ));
        }
        return rows;
    }

    /// <summary>
    /// Live entry count, optionally narrowed to a single kind. Used by the
    /// UI's "M of N" footer.
    /// </summary>
    public long LiveCount(string? kind = null)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            SELECT COUNT(*) FROM entries
            WHERE deleted_at IS NULL
              AND ($kind IS NULL OR kind = $kind)
            """;
        cmd.Parameters.AddWithValue("$kind", (object?)kind ?? DBNull.Value);
        return (long)cmd.ExecuteScalar()!;
    }

    /// <summary>Returns the large preview thumbnail (≤ 640 px JPEG) or null.</summary>
    public byte[]? GetThumbLarge(long entryId)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT thumb_large FROM previews WHERE entry_id = $id";
        cmd.Parameters.AddWithValue("$id", entryId);
        var v = cmd.ExecuteScalar();
        return v as byte[];
    }

    /// <summary>
    /// Upsert preview thumbnails for <paramref name="entryId"/>. Used by
    /// the link-metadata backfill loop to attach a fetched og:image /
    /// favicon thumbnail to a kind=link row, and (in principle) any other
    /// caller that wants to refresh thumbnails out-of-band from ingest.
    /// Either bytes parameter may be null to leave that side untouched is
    /// NOT supported here — both columns get rewritten to whatever was
    /// passed (matches the Ingestor's existing semantics).
    /// </summary>
    public void UpsertPreview(long entryId, byte[]? small, byte[]? large)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            INSERT INTO previews(entry_id, thumb_small, thumb_large)
            VALUES($id, $s, $l)
            ON CONFLICT(entry_id) DO UPDATE SET thumb_small=$s, thumb_large=$l
            """;
        cmd.Parameters.AddWithValue("$id", entryId);
        cmd.Parameters.AddWithValue("$s", (object?)small ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$l", (object?)large ?? DBNull.Value);
        cmd.ExecuteNonQuery();
    }

    /// <summary>
    /// Resolves a single flavor's bytes — either from the inline column or
    /// from the on-disk blob store. Returns null if the flavor doesn't exist.
    /// </summary>
    public byte[]? GetFlavorBytes(long entryId, string uti)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT data, blob_key FROM entry_flavors WHERE entry_id=$id AND uti=$u";
        cmd.Parameters.AddWithValue("$id", entryId);
        cmd.Parameters.AddWithValue("$u", uti);
        using var reader = cmd.ExecuteReader();
        if (!reader.Read()) return null;

        if (!reader.IsDBNull(0)) return (byte[])reader.GetValue(0);
        if (!reader.IsDBNull(1)) return _blobs.Get(reader.GetString(1));
        return null;
    }

    // ─── Link metadata backfill (docs/schema.md § Link metadata enrichment) ──

    /// <summary>
    /// Hard cap on transient-failure retries. After 6 transient failures the
    /// fetcher gives up via <see cref="SettleLink"/> with a null title, which
    /// stamps <c>link_fetched_at</c> permanently.
    /// </summary>
    public const int MaxLinkRetries = 6;

    /// <summary>
    /// Wait time before the next retry, given the transient-failure count just
    /// recorded. Contract: <c>60 · min(60, 2^count)</c> seconds, so the
    /// per-attempt schedule is 2 / 4 / 8 / 16 / 32 / 60 minutes (cap kicks in
    /// at count = 6, which is also the give-up threshold). Pure function for
    /// testability.
    /// </summary>
    public static double ComputeRetryBackoffSeconds(int newCount)
    {
        if (newCount < 1) newCount = 1;
        var pow = Math.Pow(2, newCount);
        return 60.0 * Math.Min(60.0, pow);
    }

    /// <summary>
    /// Rows the link-metadata fetcher should try next. Filters per the
    /// schema contract:
    /// <list type="bullet">
    /// <item><c>kind = 'link'</c> — only links get enriched.</item>
    /// <item><c>deleted_at IS NULL</c> — skip tombstones.</item>
    /// <item><c>link_fetched_at IS NULL</c> — skip already-settled rows
    ///       (success or permanent failure).</item>
    /// <item><c>text_preview LIKE 'http%'</c> — must look like a URL; rules
    ///       out kind=link rows we mis-classified.</item>
    /// <item><c>link_retry_count &lt; MaxLinkRetries</c> — stop trying once
    ///       we've burned through the budget.</item>
    /// <item><c>link_retry_after IS NULL OR &lt;= now</c> — backoff window
    ///       must have elapsed.</item>
    /// </list>
    /// Newest-first so freshly captured links surface immediately.
    /// </summary>
    public IReadOnlyList<LinkBackfillCandidate> NextLinkBackfillCandidates(
        int limit,
        DateTimeOffset? now = null)
    {
        var nowSec = (now ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;

        const string sql = """
            SELECT id, text_preview, link_retry_count
            FROM entries
            WHERE kind = 'link'
              AND deleted_at IS NULL
              AND link_fetched_at IS NULL
              AND text_preview IS NOT NULL
              AND text_preview LIKE 'http%'
              AND link_retry_count < $maxRetries
              AND (link_retry_after IS NULL OR link_retry_after <= $now)
            ORDER BY created_at DESC
            LIMIT $limit
            """;

        var rows = new List<LinkBackfillCandidate>();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.Parameters.AddWithValue("$maxRetries", MaxLinkRetries);
        cmd.Parameters.AddWithValue("$now", nowSec);
        cmd.Parameters.AddWithValue("$limit", limit);
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            rows.Add(new LinkBackfillCandidate(
                Id: reader.GetInt64(0),
                Url: reader.GetString(1),
                RetryCount: (int)reader.GetInt64(2)
            ));
        }
        return rows;
    }

    /// <summary>
    /// Mark a link row settled — either with a fetched title (success) or
    /// with <paramref name="title"/> = null (permanent give-up). Stamps
    /// <c>link_fetched_at</c> so the row stops appearing as a backfill
    /// candidate, clears the retry counter, and writes the title into both
    /// <c>entries.link_title</c> and the FTS5 shadow column.
    /// </summary>
    public void SettleLink(long entryId, string? title, DateTimeOffset? at = null)
    {
        var ts = (at ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;

        using var tx = _db.BeginTransaction();

        using (var cmd = _db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                UPDATE entries
                SET link_title = $title,
                    link_fetched_at = $ts,
                    link_retry_count = 0,
                    link_retry_after = NULL
                WHERE id = $id AND deleted_at IS NULL
                """;
            cmd.Parameters.AddWithValue("$title", (object?)title ?? DBNull.Value);
            cmd.Parameters.AddWithValue("$ts", ts);
            cmd.Parameters.AddWithValue("$id", entryId);
            cmd.ExecuteNonQuery();
        }

        // FTS5 doesn't support partial UPDATE on a virtual table; we rewrite
        // the row's shadow entry. Mac path uses the same "delete then insert"
        // dance — see Sources/CpdbShared/Store/Schema.swift v8 reindex loop.
        // For now we only touch the link_title column via a direct UPDATE
        // since the FTS5 shadow's other columns are still valid for this row.
        using (var cmd = _db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                UPDATE entries_fts
                SET link_title = $title
                WHERE rowid = $id
                """;
            cmd.Parameters.AddWithValue("$title", title ?? string.Empty);
            cmd.Parameters.AddWithValue("$id", entryId);
            cmd.ExecuteNonQuery();
        }

        tx.Commit();
    }

    /// <summary>
    /// Record a transient failure for the link row. Increments
    /// <c>link_retry_count</c> by one, parks <c>link_retry_after</c> at
    /// <paramref name="now"/> + <see cref="ComputeRetryBackoffSeconds"/>(new
    /// count). The row stays a candidate (link_fetched_at remains NULL) but
    /// the time gate keeps the backfill loop from hammering it.
    /// </summary>
    public void BumpLinkRetry(long entryId, DateTimeOffset? now = null)
    {
        var nowSec = (now ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;

        // Two-step: SELECT current count, then write new count + retry_after.
        // Atomic under a transaction.
        using var tx = _db.BeginTransaction();

        int currentCount;
        using (var cmd = _db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "SELECT link_retry_count FROM entries WHERE id=$id";
            cmd.Parameters.AddWithValue("$id", entryId);
            var v = cmd.ExecuteScalar();
            if (v is null || v is DBNull) { tx.Rollback(); return; }
            currentCount = (int)(long)v;
        }

        var newCount = currentCount + 1;
        var retryAfter = nowSec + ComputeRetryBackoffSeconds(newCount);

        using (var cmd = _db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                UPDATE entries
                SET link_retry_count = $c,
                    link_retry_after = $ra
                WHERE id = $id AND deleted_at IS NULL
                """;
            cmd.Parameters.AddWithValue("$c", newCount);
            cmd.Parameters.AddWithValue("$ra", retryAfter);
            cmd.Parameters.AddWithValue("$id", entryId);
            cmd.ExecuteNonQuery();
        }

        tx.Commit();
    }

    // ─── Image analysis backfill (docs/schema.md § ocr_text) ────────────────

    /// <summary>
    /// Image entries that still need OCR: <c>kind = 'image'</c>, not
    /// tombstoned, and <c>analyzed_at IS NULL</c> (the sentinel — set once
    /// OCR has run, even if it found no text, so a blank image isn't
    /// re-OCR'd forever). Newest-first so a freshly captured screenshot
    /// becomes searchable within a capture-wake cycle.
    /// </summary>
    public IReadOnlyList<long> NextImageAnalysisCandidates(int limit)
    {
        const string sql = """
            SELECT id FROM entries
            WHERE kind = 'image'
              AND deleted_at IS NULL
              AND analyzed_at IS NULL
            ORDER BY created_at DESC
            LIMIT $limit
            """;
        var ids = new List<long>();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.Parameters.AddWithValue("$limit", limit);
        using var reader = cmd.ExecuteReader();
        while (reader.Read()) ids.Add(reader.GetInt64(0));
        return ids;
    }

    /// <summary>
    /// Record the OCR result for an image entry. Always stamps
    /// <c>analyzed_at</c> (even when <paramref name="ocrText"/> is null —
    /// "we looked, there was no text") so the row drops out of the
    /// candidate set. Writes the text into <c>entries.ocr_text</c> and the
    /// FTS5 shadow's <c>ocr_text</c> column (same delete-free column
    /// UPDATE the link path uses in <see cref="SettleLink"/>).
    /// </summary>
    public void SettleImageOcr(long entryId, string? ocrText, DateTimeOffset? at = null)
    {
        var ts = (at ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;

        using var tx = _db.BeginTransaction();

        using (var cmd = _db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                UPDATE entries
                SET ocr_text = $o, analyzed_at = $ts
                WHERE id = $id AND deleted_at IS NULL
                """;
            cmd.Parameters.AddWithValue("$o", (object?)ocrText ?? DBNull.Value);
            cmd.Parameters.AddWithValue("$ts", ts);
            cmd.Parameters.AddWithValue("$id", entryId);
            cmd.ExecuteNonQuery();
        }

        using (var cmd = _db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "UPDATE entries_fts SET ocr_text = $o WHERE rowid = $id";
            cmd.Parameters.AddWithValue("$o", ocrText ?? string.Empty);
            cmd.Parameters.AddWithValue("$id", entryId);
            cmd.ExecuteNonQuery();
        }

        tx.Commit();
    }

    /// <summary>
    /// Mark <paramref name="entryId"/> deleted (sets <c>deleted_at</c>) and
    /// remove the FTS5 row so the entry stops surfacing in searches. The
    /// blob store keeps its bytes until <c>cpdb gc</c>.
    /// </summary>
    public void Tombstone(long entryId, DateTimeOffset? at = null)
        => TombstoneMany(new[] { entryId }, at);

    /// <summary>
    /// Tombstone several entries inside one transaction. Cheaper than
    /// looping <see cref="Tombstone"/> when the UI deletes multi-selected
    /// rows.
    /// </summary>
    public void TombstoneMany(IEnumerable<long> entryIds, DateTimeOffset? at = null)
    {
        var ts = (at ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;

        using var tx = _db.BeginTransaction();
        using var update = _db.CreateCommand();
        update.Transaction = tx;
        update.CommandText = "UPDATE entries SET deleted_at=$t WHERE id=$id AND deleted_at IS NULL";
        var pT = update.CreateParameter(); pT.ParameterName = "$t"; pT.Value = ts;
        var pId = update.CreateParameter(); pId.ParameterName = "$id";
        update.Parameters.Add(pT); update.Parameters.Add(pId);

        using var fts = _db.CreateCommand();
        fts.Transaction = tx;
        fts.CommandText = "DELETE FROM entries_fts WHERE rowid=$id";
        var pFts = fts.CreateParameter(); pFts.ParameterName = "$id";
        fts.Parameters.Add(pFts);

        foreach (var id in entryIds)
        {
            pId.Value = id;
            update.ExecuteNonQuery();
            pFts.Value = id;
            fts.ExecuteNonQuery();
        }
        tx.Commit();
    }

    private List<EntryRow> Query(string sql, Action<SqliteCommand> bind)
    {
        var rows = new List<EntryRow>();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        bind(cmd);
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            rows.Add(new EntryRow(
                Id: reader.GetInt64(0),
                Kind: reader.GetString(1),
                Title: reader.IsDBNull(2) ? null : reader.GetString(2),
                TextPreview: reader.IsDBNull(3) ? null : reader.GetString(3),
                CreatedAt: reader.GetDouble(4),
                CapturedAt: reader.GetDouble(5),
                TotalSize: reader.GetInt64(6),
                AppBundleId: reader.IsDBNull(7) ? null : reader.GetString(7),
                AppName: reader.IsDBNull(8) ? null : reader.GetString(8),
                ThumbSmall: reader.IsDBNull(9) ? null : (byte[])reader.GetValue(9),
                Pinned: reader.GetInt64(10) != 0,
                LinkTitle: reader.IsDBNull(11) ? null : reader.GetString(11)
            ));
        }
        return rows;
    }
}

public readonly record struct EntryRow(
    long Id,
    string Kind,
    string? Title,
    string? TextPreview,
    double CreatedAt,
    double CapturedAt,
    long TotalSize,
    string? AppBundleId,
    string? AppName,
    byte[]? ThumbSmall,
    bool Pinned,
    string? LinkTitle);

public readonly record struct FlavorRow(
    long EntryId,
    string Uti,
    long Size,
    bool IsInline,
    string? BlobKey);

/// <summary>
/// A row the link-metadata fetcher should try next. <c>Url</c> is the
/// already-validated http(s):// string from <c>entries.text_preview</c>;
/// <c>RetryCount</c> is the number of transient failures so far (0 on first
/// attempt) — useful for logging and for callers that want to vary timeout
/// per attempt.
/// </summary>
public readonly record struct LinkBackfillCandidate(
    long Id,
    string Url,
    int RetryCount);
