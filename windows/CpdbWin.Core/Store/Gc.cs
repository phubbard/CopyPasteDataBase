using Microsoft.Data.Sqlite;

namespace CpdbWin.Core.Store;

/// <summary>
/// Periodic cleanup so the database and blob store don't grow unbounded.
/// Three passes, in order:
/// <list type="number">
/// <item>Tombstone the oldest live entries beyond <c>maxLive</c> — they
///       drop out of search but the rows survive long enough for any
///       tooling to notice the deletion.</item>
/// <item>Hard-delete tombstones older than <c>tombstoneRetention</c> —
///       cascades through ON DELETE on entry_flavors / previews /
///       cloudkit_push_queue.</item>
/// <item>Delete blob files no flavor references any more.</item>
/// </list>
/// </summary>
public sealed class Gc
{
    public const int DefaultMaxLive = 5000;
    public static readonly TimeSpan DefaultTombstoneRetention = TimeSpan.FromDays(30);

    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;

    public Gc(SqliteConnection db, BlobStore blobs)
    {
        _db = db;
        _blobs = blobs;
    }

    public readonly record struct Stats(int TombstonedExtras, int HardDeleted, int OrphanBlobs);

    public Stats Run(
        int maxLive = DefaultMaxLive,
        TimeSpan? tombstoneRetention = null,
        DateTimeOffset? now = null)
    {
        var ts = (now ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;
        var cutoff = ts - (tombstoneRetention ?? DefaultTombstoneRetention).TotalSeconds;

        var tombstoned = TombstoneBeyondCount(maxLive, ts);
        var hardDeleted = HardDeleteOlderThan(cutoff);
        var orphans = CleanOrphanBlobs();
        return new Stats(tombstoned, hardDeleted, orphans);
    }

    private int TombstoneBeyondCount(int maxLive, double nowTs)
    {
        var ids = new List<long>();
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = """
                SELECT id FROM entries
                WHERE deleted_at IS NULL
                ORDER BY created_at DESC
                LIMIT -1 OFFSET $skip
                """;
            cmd.Parameters.AddWithValue("$skip", maxLive);
            using var reader = cmd.ExecuteReader();
            while (reader.Read()) ids.Add(reader.GetInt64(0));
        }
        if (ids.Count == 0) return 0;

        using var tx = _db.BeginTransaction();
        foreach (var id in ids)
        {
            using (var u = _db.CreateCommand())
            {
                u.Transaction = tx;
                u.CommandText = "UPDATE entries SET deleted_at = $t WHERE id = $id";
                u.Parameters.AddWithValue("$t", nowTs);
                u.Parameters.AddWithValue("$id", id);
                u.ExecuteNonQuery();
            }
            // Drop FTS5 row so the entry stops surfacing in searches; it's
            // tombstoned and on its way out.
            using (var d = _db.CreateCommand())
            {
                d.Transaction = tx;
                d.CommandText = "DELETE FROM entries_fts WHERE rowid = $id";
                d.Parameters.AddWithValue("$id", id);
                d.ExecuteNonQuery();
            }
        }
        tx.Commit();
        return ids.Count;
    }

    private int HardDeleteOlderThan(double cutoffTs)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            DELETE FROM entries
            WHERE deleted_at IS NOT NULL AND deleted_at < $c
            """;
        cmd.Parameters.AddWithValue("$c", cutoffTs);
        return cmd.ExecuteNonQuery();
    }

    private int CleanOrphanBlobs()
    {
        var referenced = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "SELECT DISTINCT blob_key FROM entry_flavors WHERE blob_key IS NOT NULL";
            using var reader = cmd.ExecuteReader();
            while (reader.Read()) referenced.Add(reader.GetString(0));
        }

        if (!Directory.Exists(_blobs.Root)) return 0;
        int deleted = 0;
        foreach (var sub1 in SafeEnumerateDirectories(_blobs.Root))
        {
            foreach (var sub2 in SafeEnumerateDirectories(sub1))
            {
                foreach (var file in SafeEnumerateFiles(sub2))
                {
                    var key = Path.GetFileName(file);
                    if (referenced.Contains(key)) continue;
                    try { File.Delete(file); deleted++; }
                    catch { /* in use, permission, etc. — try again next sweep */ }
                }
            }
        }
        return deleted;
    }

    private static IEnumerable<string> SafeEnumerateDirectories(string path)
    {
        try { return Directory.EnumerateDirectories(path); }
        catch { return Array.Empty<string>(); }
    }

    private static IEnumerable<string> SafeEnumerateFiles(string path)
    {
        try { return Directory.EnumerateFiles(path); }
        catch { return Array.Empty<string>(); }
    }
}
