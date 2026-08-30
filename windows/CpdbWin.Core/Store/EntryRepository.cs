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

    // Split into SELECT-list and FROM-clause halves so Search() can
    // splice extra highlight() columns in between them (the columns
    // have to sit in the SELECT list, not appended after the JOINs).
    // Recent/RowsByIds glue the two halves back with SelectEntryColumns.
    private const string SelectEntryColumnsList = """
        SELECT e.id, e.kind, e.title, e.text_preview,
               e.created_at, e.captured_at, e.total_size,
               a.bundle_id, a.name, p.thumb_small, e.pinned,
               e.link_title,
               CASE WHEN e.ocr_text IS NOT NULL AND e.ocr_text <> ''
                    THEN 1 ELSE 0 END AS has_ocr,
               e.image_tags,
               e.chips_json
        """;

    private const string SelectEntryFrom = """
        FROM entries e
        LEFT JOIN apps a ON a.id = e.source_app_id
        LEFT JOIN previews p ON p.entry_id = e.id
        """;

    private const string SelectEntryColumns = SelectEntryColumnsList + "\n" + SelectEntryFrom;

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
    /// Hydrate specific entry ids into <see cref="EntryRow"/>s. Order
    /// of the returned list is unspecified — callers that need a
    /// particular order (e.g. hybrid-search RRF result) re-sort by
    /// looking up each id in the returned dictionary. Filters out
    /// tombstoned rows and (optionally) rows whose <c>kind</c>
    /// doesn't match. Small-set query: SQLite's parameter binder
    /// doesn't take a variadic <c>IN (...)</c>, so ids are inlined
    /// as a literal comma-joined int list — safe because they came
    /// from us (<c>long</c>-typed).
    /// </summary>
    public IReadOnlyList<EntryRow> RowsByIds(IReadOnlyList<long> ids, string? kind = null)
    {
        if (ids.Count == 0) return Array.Empty<EntryRow>();
        var idList = string.Join(",", ids);  // long-typed, so no injection risk
        var sql = SelectEntryColumns + $"""

            WHERE e.id IN ({idList})
              AND e.deleted_at IS NULL
              AND ($kind IS NULL OR e.kind = $kind)
            """;
        return Query(sql, cmd =>
        {
            cmd.Parameters.AddWithValue("$kind", (object?)kind ?? DBNull.Value);
        });
    }

    /// <summary>
    /// FTS5 MATCH against the <c>entries_fts</c> shadow table, optionally
    /// narrowed to a single <c>entries.kind</c>. Pinned rows float to the
    /// top of the matching set.
    ///
    /// <para>
    /// Populates <see cref="EntryRow.MatchSource"/> on each returned row.
    /// Attribution mirrors Mac's <c>Sources/CpdbShared/Search/FtsIndex.swift</c>:
    /// <see cref="HighlightSentinelStart"/>/<see cref="HighlightSentinelEnd"/>
    /// (U+0001/U+0002 — bytes that never appear in clipboard text) wrap each
    /// FTS5 <c>highlight()</c> return, then a plain <c>Contains</c> on the
    /// output tells us which searchable column produced the hit. Column
    /// indices match <c>docs/schema.md</c> § FTS5: text=1, ocr_text=3,
    /// image_tags=4. See <see cref="MatchSource"/> for the classification
    /// buckets and <see cref="ClassifyMatchSource"/> for the fall-through
    /// rules.
    /// </para>
    /// </summary>
    public IReadOnlyList<EntryRow> Search(string ftsQuery, int limit = 100, string? kind = null)
    {
        // 3 extra columns per Mac's usage — column indices are hard-coded
        // to the FTS5 schema in Store/Schema.cs (title=0, text=1,
        // app_name=2, ocr_text=3, image_tags=4, link_title=5). If the
        // FTS5 column order ever changes, MatchSourceTests will fail
        // before UI regressions can ship.
        // Extras live in the SELECT list (between the column list and
        // the FROM clause) — SQL forbids trailing columns after JOINs.
        // Column indices tied to Store/Schema.cs FTS5 definition:
        // 1=text, 3=ocr_text, 4=image_tags.
        var sql = SelectEntryColumnsList + """
            ,
                   highlight(entries_fts, 1, char(1), char(2)) AS hl_text,
                   highlight(entries_fts, 3, char(1), char(2)) AS hl_ocr,
                   highlight(entries_fts, 4, char(1), char(2)) AS hl_tags
            """ + "\n" + SelectEntryFrom + """

            JOIN entries_fts f ON f.rowid = e.id
            WHERE entries_fts MATCH $q AND e.deleted_at IS NULL
              AND ($kind IS NULL OR e.kind = $kind)
            ORDER BY e.pinned DESC, e.created_at DESC
            LIMIT $limit
            """;
        var rows = new List<EntryRow>();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.Parameters.AddWithValue("$q", ftsQuery);
        cmd.Parameters.AddWithValue("$limit", limit);
        cmd.Parameters.AddWithValue("$kind", (object?)kind ?? DBNull.Value);
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            var source = ClassifyMatchSource(
                hlText: reader.IsDBNull(15) ? "" : reader.GetString(15),
                hlOcr:  reader.IsDBNull(16) ? "" : reader.GetString(16),
                hlTags: reader.IsDBNull(17) ? "" : reader.GetString(17));

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
                LinkTitle: reader.IsDBNull(11) ? null : reader.GetString(11),
                HasOcr: reader.GetInt64(12) != 0,
                ImageTags: reader.IsDBNull(13) ? null : reader.GetString(13),
                ChipsJson: reader.IsDBNull(14) ? null : reader.GetString(14),
                MatchSource: source
            ));
        }
        return rows;
    }

    /// <summary>
    /// Classify a search hit into a match-source bucket from the FTS5
    /// <c>highlight()</c> sentinels. Public+static so the parity tests
    /// can drive it directly without a live DB — the SQL layer is just
    /// a marker producer, the semantics live here.
    /// </summary>
    /// <remarks>
    /// Bucket rules, mirroring <c>Sources/CpdbShared/Search/FtsIndex.swift</c>:
    /// <list type="bullet">
    ///   <item><description>OCR hit + tag hit ⇒ <see cref="MatchSource.Multiple"/></description></item>
    ///   <item><description>OCR hit only ⇒ <see cref="MatchSource.Ocr"/></description></item>
    ///   <item><description>tag hit only ⇒ <see cref="MatchSource.Tag"/></description></item>
    ///   <item><description>otherwise ⇒ <see cref="MatchSource.Text"/> — the
    ///   fall-through catches plain text matches, title matches,
    ///   link_title matches, and app_name matches. Mac collapses all four
    ///   into one bucket because the badge would be noise for the
    ///   overwhelmingly common "matched the visible text" case.</description></item>
    /// </list>
    /// </remarks>
    public static MatchSource ClassifyMatchSource(string hlText, string hlOcr, string hlTags)
    {
        bool ocrHit  = hlOcr.IndexOf(HighlightSentinelStart) >= 0;
        bool tagHit  = hlTags.IndexOf(HighlightSentinelStart) >= 0;
        if (ocrHit && tagHit) return MatchSource.Multiple;
        if (ocrHit)           return MatchSource.Ocr;
        if (tagHit)           return MatchSource.Tag;
        return MatchSource.Text;
    }

    /// <summary>
    /// Marker chars wrapping each <c>highlight()</c> return. U+0001 (SOH)
    /// and U+0002 (STX) are C0 control characters that can't legally
    /// appear in JSON-safe clipboard text; both platforms use the exact
    /// same pair so cross-platform test vectors stay portable.
    /// </summary>
    public const char HighlightSentinelStart = '';
    public const char HighlightSentinelEnd   = '';

    /// <summary>
    /// Toggle the <c>entries.pinned</c> bit for a single row. Per
    /// docs/schema.md § Pinning the column is INTEGER 0/1; the on-disk
    /// representation is just that single update — sort order and
    /// eviction-skip semantics fall out of the existing queries.
    /// </summary>
    public void SetPinned(long entryId, bool pinned)
    {
        // Bump modified_at: pin is a user mutation, so the cross-platform
        // LWW sync contract (mac docs/canonical-hash-v2.md §undo) requires
        // we mark when it happened. Windows is standalone today but the
        // column is wired in for future sync.
        var ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            UPDATE entries SET pinned = $p, modified_at = $t
            WHERE id = $id AND deleted_at IS NULL
            """;
        cmd.Parameters.AddWithValue("$p", pinned ? 1 : 0);
        cmd.Parameters.AddWithValue("$t", ts);
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

    /// <summary>
    /// Read <c>entries.ocr_text</c> for a single row. The list-query
    /// projection only exposes a non-empty <c>HasOcr</c> flag (avoids
    /// pulling potentially-long OCR strings for every visible row); the
    /// preview pane fetches the full text on demand via this. Returns
    /// <c>null</c> when the entry hasn't been analyzed or the OCR found
    /// no text.
    /// </summary>
    public string? GetOcrText(long entryId)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT ocr_text FROM entries WHERE id = $id";
        cmd.Parameters.AddWithValue("$id", entryId);
        var v = cmd.ExecuteScalar();
        if (v is null or DBNull) return null;
        var s = (string)v;
        return string.IsNullOrEmpty(s) ? null : s;
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
    /// Image entries that still need at least one analysis pass —
    /// either OCR (<c>ocr_at IS NULL</c>) or classifier tags
    /// (<c>tags_at IS NULL</c>). Newest-first so a freshly captured
    /// screenshot becomes searchable within a capture-wake cycle.
    /// The per-pass flags let the analyzer skip work that's already
    /// done (so the Preferences "Re-OCR images" button doesn't
    /// implicitly re-tag, and vice versa).
    /// </summary>
    public IReadOnlyList<ImageAnalysisCandidate> NextImageAnalysisCandidates(int limit)
    {
        const string sql = """
            SELECT id,
                   CASE WHEN ocr_at  IS NULL THEN 1 ELSE 0 END AS needs_ocr,
                   CASE WHEN tags_at IS NULL THEN 1 ELSE 0 END AS needs_tags
            FROM entries
            WHERE kind = 'image'
              AND deleted_at IS NULL
              AND (ocr_at IS NULL OR tags_at IS NULL)
            ORDER BY created_at DESC
            LIMIT $limit
            """;
        var rows = new List<ImageAnalysisCandidate>();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.Parameters.AddWithValue("$limit", limit);
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            rows.Add(new ImageAnalysisCandidate(
                Id:        reader.GetInt64(0),
                NeedsOcr:  reader.GetInt64(1) != 0,
                NeedsTags: reader.GetInt64(2) != 0));
        return rows;
    }

    /// <summary>
    /// Record an OCR result for an image entry. Stamps <c>ocr_at</c>
    /// + <c>analyzed_at</c> (even when <paramref name="ocrText"/> is
    /// null — "we looked, there was no text") so the row stops being
    /// an OCR candidate. <b>Does not touch</b> <c>tags_at</c> /
    /// <c>image_tags</c>, so a Preferences "Re-OCR images" reset (which
    /// clears only <c>ocr_at</c>) can re-run OCR without disturbing
    /// classifier tags. Mirrors the per-pass column UPDATE pattern used
    /// by <see cref="SettleLink"/>.
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
                SET ocr_text    = $o,
                    ocr_at      = $ts,
                    analyzed_at = $ts
                WHERE id = $id AND deleted_at IS NULL
                """;
            cmd.Parameters.AddWithValue("$o",  (object?)ocrText ?? DBNull.Value);
            cmd.Parameters.AddWithValue("$ts", ts);
            cmd.Parameters.AddWithValue("$id", entryId);
            cmd.ExecuteNonQuery();
        }
        using (var cmd = _db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "UPDATE entries_fts SET ocr_text = $o WHERE rowid = $id";
            cmd.Parameters.AddWithValue("$o",  ocrText ?? string.Empty);
            cmd.Parameters.AddWithValue("$id", entryId);
            cmd.ExecuteNonQuery();
        }
        tx.Commit();
    }

    /// <summary>
    /// Record an image-classifier result. Stamps <c>tags_at</c> +
    /// <c>analyzed_at</c> regardless of whether
    /// <paramref name="imageTags"/> is null. Independent of
    /// <see cref="SettleImageOcr"/> — a "Re-tag images" reset (clears
    /// only <c>tags_at</c>) re-runs the classifier without re-running
    /// OCR.
    /// </summary>
    public void SettleImageTags(long entryId, string? imageTags, DateTimeOffset? at = null)
    {
        var ts = (at ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;

        using var tx = _db.BeginTransaction();

        using (var cmd = _db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                UPDATE entries
                SET image_tags  = $t,
                    tags_at     = $ts,
                    analyzed_at = $ts
                WHERE id = $id AND deleted_at IS NULL
                """;
            cmd.Parameters.AddWithValue("$t",  (object?)imageTags ?? DBNull.Value);
            cmd.Parameters.AddWithValue("$ts", ts);
            cmd.Parameters.AddWithValue("$id", entryId);
            cmd.ExecuteNonQuery();
        }
        using (var cmd = _db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "UPDATE entries_fts SET image_tags = $t WHERE rowid = $id";
            cmd.Parameters.AddWithValue("$t",  imageTags ?? string.Empty);
            cmd.Parameters.AddWithValue("$id", entryId);
            cmd.ExecuteNonQuery();
        }
        tx.Commit();
    }

    /// <summary>
    /// Combined settle — equivalent to back-to-back
    /// <see cref="SettleImageOcr"/> + <see cref="SettleImageTags"/>
    /// but in a single transaction with a single FTS5 update. Used
    /// when the analyzer ran both passes in one decode (the common
    /// fresh-capture case); also a back-compat call site for tests +
    /// the CLI that don't care about per-pass timing.
    /// </summary>
    public void SettleImageAnalysis(
        long entryId,
        string? ocrText,
        string? imageTags = null,
        DateTimeOffset? at = null)
    {
        var ts = (at ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;

        using var tx = _db.BeginTransaction();

        using (var cmd = _db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                UPDATE entries
                SET ocr_text    = $o,
                    image_tags  = $t,
                    ocr_at      = $ts,
                    tags_at     = $ts,
                    analyzed_at = $ts
                WHERE id = $id AND deleted_at IS NULL
                """;
            cmd.Parameters.AddWithValue("$o",  (object?)ocrText  ?? DBNull.Value);
            cmd.Parameters.AddWithValue("$t",  (object?)imageTags ?? DBNull.Value);
            cmd.Parameters.AddWithValue("$ts", ts);
            cmd.Parameters.AddWithValue("$id", entryId);
            cmd.ExecuteNonQuery();
        }
        using (var cmd = _db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText =
                "UPDATE entries_fts SET ocr_text = $o, image_tags = $t WHERE rowid = $id";
            cmd.Parameters.AddWithValue("$o",  ocrText  ?? string.Empty);
            cmd.Parameters.AddWithValue("$t",  imageTags ?? string.Empty);
            cmd.Parameters.AddWithValue("$id", entryId);
            cmd.ExecuteNonQuery();
        }
        tx.Commit();
    }

    // ─── Action-chip storage (v13_semantic_enrichment, chips_json column) ──

    /// <summary>
    /// Return text + link entries the chip backfiller should scan next
    /// — rows whose <c>chips_json</c> is NULL (never scanned). A row
    /// that came back with zero chips still gets <c>"[]"</c> written,
    /// so this query self-drains as the sweep progresses. Ordered
    /// newest-first so a freshly-copied clip gets its chips within
    /// one sweep tick. Mirrors macOS <c>entriesNeedingChips</c>.
    /// </summary>
    public IReadOnlyList<long> EntriesNeedingChips(int limit)
    {
        const string sql = """
            SELECT id FROM entries
            WHERE kind IN ('text', 'link')
              AND deleted_at IS NULL
              AND chips_json IS NULL
            ORDER BY created_at DESC
            LIMIT $lim
            """;
        var ids = new List<long>();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.Parameters.AddWithValue("$lim", limit);
        using var r = cmd.ExecuteReader();
        while (r.Read()) ids.Add(r.GetInt64(0));
        return ids;
    }

    /// <summary>
    /// Text an entry should be scanned for chips. Uses
    /// <c>text_preview</c> — same as the sweeper does, and shorter
    /// than the full flavor bytes — because chip detection is
    /// deterministic and text-preview is the canonical stored form
    /// (already normalized on capture). Returns null for tombstoned
    /// or missing rows.
    /// </summary>
    public string? GetChipScanText(long entryId)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT text_preview FROM entries WHERE id = $id AND deleted_at IS NULL";
        cmd.Parameters.AddWithValue("$id", entryId);
        using var r = cmd.ExecuteReader();
        if (!r.Read()) return null;
        return r.IsDBNull(0) ? null : r.GetString(0);
    }

    /// <summary>
    /// Write <paramref name="json"/> into <c>chips_json</c> for
    /// <paramref name="entryId"/>, but only when the column is still
    /// NULL — first-writer-wins between the ingest-time detection
    /// task and the periodic backfill sweep. A row that raced to
    /// "[]" (scanned, found nothing) doesn't get overwritten by a
    /// subsequent scan that would also come back empty.
    /// </summary>
    public void SetChipsIfUnset(long entryId, string json)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            UPDATE entries
            SET chips_json = $j
            WHERE id = $id
              AND chips_json IS NULL
              AND deleted_at IS NULL
            """;
        cmd.Parameters.AddWithValue("$id", entryId);
        cmd.Parameters.AddWithValue("$j",  json);
        cmd.ExecuteNonQuery();
    }

    /// <summary>
    /// Unconditional <c>chips_json</c> write. Distinguished from
    /// <see cref="SetChipsIfUnset"/>: the QR pass on image entries
    /// (v1.45) re-runs whenever a "Re-OCR images" reset re-arms the
    /// OCR sentinel, and its output should update the stored chips
    /// rather than being suppressed by the first-writer guard.
    /// Callers pair with <see cref="Chip.Merge"/> when preserving
    /// prior chip payloads matters.
    /// </summary>
    public void SetChips(long entryId, string json)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "UPDATE entries SET chips_json = $j WHERE id = $id AND deleted_at IS NULL";
        cmd.Parameters.AddWithValue("$id", entryId);
        cmd.Parameters.AddWithValue("$j",  json);
        cmd.ExecuteNonQuery();
    }

    // ─── Semantic-search embedding storage (v13_semantic_enrichment) ────

    /// <summary>
    /// Rows the embedding sweeper should encode next: text / link
    /// entries with no <c>entry_embeddings</c> row, or one that a
    /// model or revision bump has left stale. Ordered newest-first so
    /// a freshly-copied clip becomes semantically searchable as
    /// quickly as the sweeper can drain the queue. Mirrors macOS
    /// <c>EntryRepository.entriesNeedingEmbedding</c>.
    /// </summary>
    public IReadOnlyList<long> EntriesNeedingEmbedding(string modelId, int revision, int limit)
    {
        const string sql = """
            SELECT e.id
            FROM entries e
            LEFT JOIN entry_embeddings v ON v.entry_id = e.id
            WHERE e.kind IN ('text', 'link')
              AND e.deleted_at IS NULL
              AND (v.entry_id IS NULL OR v.model_id != $mid OR v.revision != $rev)
            ORDER BY e.created_at DESC
            LIMIT $lim
            """;
        var ids = new List<long>();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.Parameters.AddWithValue("$mid", modelId);
        cmd.Parameters.AddWithValue("$rev", revision);
        cmd.Parameters.AddWithValue("$lim", limit);
        using var reader = cmd.ExecuteReader();
        while (reader.Read()) ids.Add(reader.GetInt64(0));
        return ids;
    }

    /// <summary>
    /// Read the text an entry should be embedded from. Returns the
    /// non-empty of <c>link_title</c> + <c>text_preview</c> for links,
    /// or <c>text_preview</c> for text entries. Never returns bytes
    /// bigger than the full text_preview column — chunking is the
    /// service's responsibility.
    /// </summary>
    public string? GetEmbeddableText(long entryId)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT text_preview, link_title FROM entries WHERE id = $id AND deleted_at IS NULL";
        cmd.Parameters.AddWithValue("$id", entryId);
        using var r = cmd.ExecuteReader();
        if (!r.Read()) return null;
        var textPreview = r.IsDBNull(0) ? null : r.GetString(0);
        var linkTitle   = r.IsDBNull(1) ? null : r.GetString(1);
        // Concatenate title + preview for links so semantic search finds
        // the row by page title as well as URL/text. text-only rows
        // just embed their preview.
        if (!string.IsNullOrWhiteSpace(linkTitle) && !string.IsNullOrWhiteSpace(textPreview))
            return linkTitle + "\n\n" + textPreview;
        return textPreview ?? linkTitle;
    }

    /// <summary>
    /// Upsert one <c>entry_embeddings</c> row. Serialization to
    /// <c>Float32 little-endian</c> is caller's responsibility (via
    /// <see cref="Analysis.EmbeddingService.SerializeLittleEndian"/>);
    /// this method just persists what it's given. Mirrors macOS
    /// <c>saveEmbedding</c>: overwrites on the PK so a re-embed
    /// (model or revision bump) replaces the vector in place rather
    /// than accumulating stale rows.
    /// </summary>
    public void SaveEmbedding(long entryId, string modelId, int revision, int dims, byte[] vector, DateTimeOffset? at = null)
    {
        var ts = (at ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            INSERT INTO entry_embeddings (entry_id, model_id, revision, dims, vector, embedded_at)
            VALUES ($id, $mid, $rev, $dims, $vec, $ts)
            ON CONFLICT(entry_id) DO UPDATE SET
                model_id    = excluded.model_id,
                revision    = excluded.revision,
                dims        = excluded.dims,
                vector      = excluded.vector,
                embedded_at = excluded.embedded_at
            """;
        cmd.Parameters.AddWithValue("$id",   entryId);
        cmd.Parameters.AddWithValue("$mid",  modelId);
        cmd.Parameters.AddWithValue("$rev",  revision);
        cmd.Parameters.AddWithValue("$dims", dims);
        cmd.Parameters.AddWithValue("$vec",  vector);
        cmd.Parameters.AddWithValue("$ts",   ts);
        cmd.ExecuteNonQuery();
    }

    /// <summary>Row shape returned by <see cref="LoadAllEmbeddings"/>:
    /// (entry_id, model_id, revision, dims, vector-bytes).</summary>
    public readonly record struct EmbeddingRow(long EntryId, string ModelId, int Revision, int Dims, byte[] Vector);

    /// <summary>
    /// Load every <c>entry_embeddings</c> row (only for live entries)
    /// so the in-memory search index can build a contiguous float
    /// buffer. Cheap enough for a 10k-entry library
    /// (10k × 384 × 4 B ≈ 15 MB); the index caches the result and
    /// invalidates on write. Mirrors macOS <c>EmbeddingIndex</c>'s
    /// paged reload — Windows loads in one pass because SQLite ADO
    /// doesn't yield the way GRDB does.
    /// </summary>
    public IReadOnlyList<EmbeddingRow> LoadAllEmbeddings()
    {
        const string sql = """
            SELECT v.entry_id, v.model_id, v.revision, v.dims, v.vector
            FROM entry_embeddings v
            INNER JOIN entries e ON e.id = v.entry_id
            WHERE e.deleted_at IS NULL
            ORDER BY v.entry_id
            """;
        var rows = new List<EmbeddingRow>();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            rows.Add(new EmbeddingRow(
                EntryId:  r.GetInt64(0),
                ModelId:  r.GetString(1),
                Revision: (int)r.GetInt64(2),
                Dims:     (int)r.GetInt64(3),
                Vector:   (byte[])r.GetValue(4)));
        }
        return rows;
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
        // Bump modified_at alongside deleted_at — delete is a user
        // mutation, same LWW contract as pin (see SetPinned).
        update.CommandText = "UPDATE entries SET deleted_at=$t, modified_at=$t WHERE id=$id AND deleted_at IS NULL";
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
                LinkTitle: reader.IsDBNull(11) ? null : reader.GetString(11),
                HasOcr: reader.GetInt64(12) != 0,
                ImageTags: reader.IsDBNull(13) ? null : reader.GetString(13),
                ChipsJson: reader.IsDBNull(14) ? null : reader.GetString(14)
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
    string? LinkTitle,
    bool HasOcr,
    string? ImageTags,
    string? ChipsJson,
    // v1.47: search-only attribution. NULL on Recent() / RowsByIds()
    // paths; populated only by Search() so the UI can render a
    // "OCR" / "tag" / "•••" badge on rows that matched a non-text
    // column. Defaulted so existing positional callers stay valid.
    MatchSource? MatchSource = null);

/// <summary>
/// Which FTS5 column produced a search hit — surfaces as a small badge
/// on the row so users can tell "this matched the OCR text on a
/// screenshot" from "this matched the visible clipboard text". Ports
/// <c>Sources/CpdbShared/Search/FtsIndex.MatchSource</c>; naming
/// preserved byte-for-byte so parity fixtures port straight across.
/// </summary>
/// <remarks>
/// Mac also has a <c>.semantic</c> case set by the popup's embedding
/// re-ranker. Windows' <c>HybridRank</c> currently returns fused IDs
/// through <see cref="EntryRepository.RowsByIds"/>, which drops the
/// per-hit source — plumbing <c>.semantic</c> through requires the RRF
/// pipeline to preserve which rank each id got its slot from, which
/// isn't in this cut. When that lands, add the enum value here and
/// wire the badge label + color in the UI.
/// </remarks>
public enum MatchSource
{
    /// <summary>Matched a "plain text" column (text, title, app_name,
    /// link_title) — the common case; no badge is rendered.</summary>
    Text,
    /// <summary>Matched the <c>ocr_text</c> column — the row is an
    /// image whose OCR pass turned up the search terms.</summary>
    Ocr,
    /// <summary>Matched the <c>image_tags</c> column — the row is an
    /// image whose ImageNet classifier turned up the search terms.</summary>
    Tag,
    /// <summary>Matched more than one non-text column at once (both
    /// OCR and tags fired). Rare in practice but honest to the data.</summary>
    Multiple,
}

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

/// <summary>
/// One image entry the analyzer should process next, with per-pass
/// flags so the service can skip work that's already done. Both flags
/// false would mean the row is fully settled — the candidate query
/// filters those out, so a returned candidate always has at least one
/// flag set.
/// </summary>
public readonly record struct ImageAnalysisCandidate(
    long Id,
    bool NeedsOcr,
    bool NeedsTags);
