using CpdbWin.Core.Store;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Cleans up entries the live <c>CpdbWin.App.exe</c> may have captured
/// from the system clipboard while a test was running. Opens the
/// production database (<c>%LOCALAPPDATA%\cpdb\cpdb.db</c>) and tombstones
/// matches via the same <see cref="EntryRepository.Tombstone"/> path the
/// UI's delete affordance uses, so this code is exercised both ways.
///
/// Two sweeps:
/// <list type="number">
/// <item>Anything whose plain-text starts with <see cref="TestPrefix"/>
///       (the convention every clipboard-touching test follows for
///       generated strings).</item>
/// <item>Anything whose <c>content_hash</c> matches one of the pinned
///       canonical-hash test vectors — the "hello" round-trip test
///       deliberately uses the literal hello to verify cross-platform
///       parity, so we can't prefix it.</item>
/// </list>
/// No-op when the production DB doesn't exist (no live app installed).
/// </summary>
internal static class ProductionDbCleanup
{
    public const string TestPrefix = "cpdb-test-";

    private static readonly byte[][] PinnedTestHashes =
    {
        Convert.FromHexString("b22187611777c1e9c84c3fdd054ed311a47d12f33cba6d1e7761bd3a7314073a"),
        Convert.FromHexString("17a95cac0686665cfe5342a3a041d7afedfa4c14a59d6d3c6b7b53a4bf0ad85a"),
    };

    public static int TombstoneTestEntries()
    {
        AppPaths.Resolved paths;
        try { paths = AppPaths.Initialize(); }
        catch { return 0; }
        if (!File.Exists(paths.Database)) return 0;

        try
        {
            using var conn = Database.Open(paths.Database);
            var blobs = new BlobStore(paths.Blobs);
            var repo = new EntryRepository(conn, blobs);

            var ids = new HashSet<long>();
            CollectByPrefix(conn, ids);
            CollectByHash(conn, ids);
            foreach (var id in ids) repo.Tombstone(id);
            return ids.Count;
        }
        catch
        {
            return 0;
        }
    }

    private static void CollectByPrefix(Microsoft.Data.Sqlite.SqliteConnection conn, HashSet<long> ids)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            SELECT id FROM entries
            WHERE deleted_at IS NULL
              AND text_preview LIKE $p
            """;
        cmd.Parameters.AddWithValue("$p", TestPrefix + "%");
        using var reader = cmd.ExecuteReader();
        while (reader.Read()) ids.Add(reader.GetInt64(0));
    }

    private static void CollectByHash(Microsoft.Data.Sqlite.SqliteConnection conn, HashSet<long> ids)
    {
        foreach (var hash in PinnedTestHashes)
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = """
                SELECT id FROM entries
                WHERE deleted_at IS NULL AND content_hash = $h
                """;
            cmd.Parameters.AddWithValue("$h", hash);
            using var reader = cmd.ExecuteReader();
            while (reader.Read()) ids.Add(reader.GetInt64(0));
        }
    }
}
