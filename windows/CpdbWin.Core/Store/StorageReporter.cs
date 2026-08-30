using Microsoft.Data.Sqlite;

namespace CpdbWin.Core.Store;

/// <summary>
/// Snapshot of on-disk storage consumption. Windows port of macOS's
/// <c>Sources/CpdbShared/StorageReport.swift</c>. Consumed by both the
/// <c>cpdb-win storage</c> CLI command (v1.51) and the Preferences →
/// Storage pane (v1.21); a single reporter keeps the numbers
/// consistent between the two surfaces the way Mac does.
///
/// <para>
/// <b>Three-tier model</b> (Mac's framing, preserved verbatim so the
/// two platforms describe the same DB the same way):
/// </para>
/// <list type="bullet">
///   <item><description><b>Metadata</b> — everything the DB holds that
///     isn't clipboard bytes or thumbnails: entry rows, FTS shadow
///     rows, chips_json, embeddings, apps, devices. Always kept —
///     eviction never touches it.</description></item>
///   <item><description><b>Thumbnails</b> — the <c>previews</c> table
///     (small + large per image). Always kept so a body-evicted image
///     still renders in the row.</description></item>
///   <item><description><b>Flavor bodies</b> — the clipboard bytes.
///     Two sub-tiers: <b>inline</b> (&lt; 256 KB, stored in
///     <c>entry_flavors.data</c>) and <b>on-disk blobs</b> (content-
///     addressed files under <see cref="BlobStore.Root"/>). This is
///     the tier <see cref="EntryEvictor"/> targets.</description></item>
/// </list>
///
/// <para>
/// <b>Windows-only addition</b> (drift from Mac): the SQLite trio
/// (<c>cpdb.db</c> + <c>-wal</c> + <c>-shm</c>) is reported as a
/// separate first line. WAL mode is on, so `-wal` and `-shm` are
/// live files a user's disk-usage tool will see; hiding them would
/// desync the CLI report from what Explorer reports.
/// </para>
/// </summary>
public readonly record struct StorageReport(
    // Windows-only: on-disk sizes of the SQLite file trio.
    long DatabaseFileBytes,
    long DatabaseWalBytes,
    long DatabaseShmBytes,
    // Mac's three tiers, byte totals.
    long MetadataBytes,
    long ThumbnailBytes,
    long InlineFlavorBytes,
    long BlobBytes,
    // Trailer counts.
    long LiveEntryCount,
    long PinnedEntryCount,
    long BodyEvictedEntryCount)
{
    /// <summary>Derived — sum of the two flavor-body sub-tiers.</summary>
    public long FlavorBytes => InlineFlavorBytes + BlobBytes;

    /// <summary>Derived — Mac's "Library size" total across the
    /// three tiers. Deliberately excludes the SQLite file trio
    /// (WAL / SHM are transient; -wal will collapse into -db on
    /// the next checkpoint). Reporting them separately keeps the
    /// tier totals stable across checkpoints.</summary>
    public long Total => MetadataBytes + ThumbnailBytes + FlavorBytes;
}

/// <summary>
/// Gathers the numbers <see cref="StorageReport"/> holds.
/// Ports <c>Sources/CpdbShared/StorageReport.swift StorageInspector</c>.
/// </summary>
public static class StorageReporter
{
    /// <summary>
    /// One-shot snapshot. SQL work + filesystem walks all happen
    /// synchronously — caller can wrap in <c>Task.Run</c> if it
    /// matters (the Preferences pane does; the CLI doesn't).
    /// </summary>
    public static StorageReport Report(SqliteConnection db, BlobStore blobs, string databasePath)
    {
        var (metadata, thumbnails, inline, live, pinned, bodyEvicted) = QueryCountsAndSizes(db);
        var blobBytes = DirSize(blobs.Root);

        return new StorageReport(
            DatabaseFileBytes:      FileSize(databasePath),
            DatabaseWalBytes:       FileSize(databasePath + "-wal"),
            DatabaseShmBytes:       FileSize(databasePath + "-shm"),
            MetadataBytes:          metadata,
            ThumbnailBytes:         thumbnails,
            InlineFlavorBytes:      inline,
            BlobBytes:              blobBytes,
            LiveEntryCount:         live,
            PinnedEntryCount:       pinned,
            BodyEvictedEntryCount:  bodyEvicted);
    }

    /// <summary>
    /// Render the report as the human-readable multi-line block the
    /// CLI prints. Matches macOS's <c>StorageReport.formatted()</c>
    /// three-tier shape verbatim, plus the Windows-only SQLite file
    /// trio at the top. Right-aligned byte column at
    /// <paramref name="width"/> chars (16 matches Mac's default).
    /// </summary>
    public static string Formatted(StorageReport r, int width = 16)
    {
        var lines = new List<string>
        {
            $"Library size:{PadLeft(FormatBytes(r.Total), width)}",
            "",
            $"  Database        {PadLeft(FormatBytes(r.DatabaseFileBytes), width)}   +wal {FormatBytes(r.DatabaseWalBytes)}, +shm {FormatBytes(r.DatabaseShmBytes)}",
            $"  Metadata        {PadLeft(FormatBytes(r.MetadataBytes), width)}   always kept",
            $"  Thumbnails      {PadLeft(FormatBytes(r.ThumbnailBytes), width)}   always kept",
            $"  Flavor bodies   {PadLeft(FormatBytes(r.FlavorBytes), width)}   evictable",
            $"      inline      {PadLeft(FormatBytes(r.InlineFlavorBytes), width)}",
            $"      on-disk     {PadLeft(FormatBytes(r.BlobBytes), width)}",
            "",
            $"  {r.LiveEntryCount:N0} live entries ({r.PinnedEntryCount:N0} pinned, skipped by eviction)",
            $"  {r.BodyEvictedEntryCount:N0} entries with bodies discarded by retention policy",
        };
        return string.Join('\n', lines);
    }

    // ── SQL: aggregates + counts in one connection pass ─────────────

    private static (long metadata, long thumbnails, long inline,
                    long live, long pinned, long bodyEvicted) QueryCountsAndSizes(SqliteConnection db)
    {
        // Thumbnails: sum of both preview blobs. NULL-safe via COALESCE.
        long thumbnails = ScalarLong(db, """
            SELECT COALESCE(SUM(COALESCE(length(thumb_small),0) + COALESCE(length(thumb_large),0)), 0)
            FROM previews
            """);

        // Inline flavor bytes: entry_flavors.data (< 256 KB path). The
        // out-of-line rows have data IS NULL so they contribute 0.
        long inline = ScalarLong(db, """
            SELECT COALESCE(SUM(length(data)), 0)
            FROM entry_flavors
            WHERE data IS NOT NULL
            """);

        // Metadata: page-size × pages currently allocated. SQLite tracks
        // both; the product is the on-disk logical size of the DB.
        // Subtract thumbnails + inline bytes to leave "everything else"
        // (entry rows, FTS shadow, chips, embeddings, apps, devices).
        // This approximates Mac's semantics — Mac computes each table's
        // size separately and calls the remainder "metadata"; the
        // subtraction gets us the same number without per-table walks.
        long pageSize  = ScalarLong(db, "PRAGMA page_size");
        long pageCount = ScalarLong(db, "PRAGMA page_count");
        long total     = pageSize * pageCount;
        long metadata  = Math.Max(0, total - thumbnails - inline);

        long live        = ScalarLong(db, "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL");
        long pinned      = ScalarLong(db, "SELECT COUNT(*) FROM entries WHERE pinned = 1 AND deleted_at IS NULL");
        long bodyEvicted = ScalarLong(db, "SELECT COUNT(*) FROM entries WHERE body_evicted_at IS NOT NULL AND deleted_at IS NULL");

        return (metadata, thumbnails, inline, live, pinned, bodyEvicted);
    }

    private static long ScalarLong(SqliteConnection db, string sql)
    {
        using var cmd = db.CreateCommand();
        cmd.CommandText = sql;
        var v = cmd.ExecuteScalar();
        return v is null or DBNull ? 0 : Convert.ToInt64(v);
    }

    // ── Filesystem: sizes + tree walk ────────────────────────────────

    private static long FileSize(string path)
    {
        try { return File.Exists(path) ? new FileInfo(path).Length : 0; }
        catch { return 0; }
    }

    private static long DirSize(string dir)
    {
        if (!Directory.Exists(dir)) return 0;
        long total = 0;
        try
        {
            foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
            {
                try { total += new FileInfo(f).Length; } catch { /* skip files that vanish mid-walk */ }
            }
        }
        catch { /* dir vanished / permission — best-effort */ }
        return total;
    }

    // ── Formatting helpers ──────────────────────────────────────────

    /// <summary>Compact human-readable bytes formatter — same shape as
    /// the Cli's local <c>FormatBytes</c> (kept public so it can be
    /// lifted here once the CLI is refactored). Invariant culture:
    /// output must not vary by locale.</summary>
    public static string FormatBytes(long bytes)
    {
        if (bytes < 1024)                return $"{bytes} B";
        if (bytes < 1024 * 1024)         return $"{bytes / 1024.0:F1} KB";
        if (bytes < 1024L * 1024 * 1024) return $"{bytes / (1024.0 * 1024):F1} MB";
        return $"{bytes / (1024.0 * 1024 * 1024):F2} GB";
    }

    private static string PadLeft(string s, int width) =>
        s.Length >= width ? s : new string(' ', width - s.Length) + s;
}
