using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

public class SchemaTests
{
    [Fact]
    public void Initialize_CreatesAllTablesAndIndexes()
    {
        using var conn = new SqliteConnection("Data Source=:memory:");
        conn.Open();

        Schema.Initialize(conn);

        var expectedObjects = new[]
        {
            "entries", "entry_flavors", "apps", "devices",
            "pinboards", "pinboard_entries", "previews",
            "cloudkit_push_queue", "cloudkit_state",
            "entries_fts", "grdb_migrations",
            "idx_entries_created_at", "idx_entries_kind",
            "idx_entries_live_content_hash", "idx_flavors_blob_key",
            "idx_cloudkit_push_queue_enqueued_at",
        };

        foreach (var name in expectedObjects)
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "SELECT name FROM sqlite_master WHERE name=$n";
            cmd.Parameters.AddWithValue("$n", name);
            Assert.Equal(name, cmd.ExecuteScalar() as string);
        }
    }

    [Fact]
    public void Initialize_SeedsMigrationNamesInOrder()
    {
        using var conn = new SqliteConnection("Data Source=:memory:");
        conn.Open();

        Schema.Initialize(conn);

        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT identifier FROM grdb_migrations ORDER BY rowid";
        using var reader = cmd.ExecuteReader();
        var names = new List<string>();
        while (reader.Read()) names.Add(reader.GetString(0));

        Assert.Equal(Schema.AppliedMigrationNames, names);
    }

    [Fact]
    public void Fts5IsAvailable()
    {
        // Microsoft.Data.Sqlite ships e_sqlite3 with FTS5 compiled in. Fail
        // fast if a future package release ever drops it.
        using var conn = new SqliteConnection("Data Source=:memory:");
        conn.Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "CREATE VIRTUAL TABLE t USING fts5(x)";
        cmd.ExecuteNonQuery();
    }

    [Fact]
    public void EntriesKindCheckRejectsUnknownValues()
    {
        using var conn = new SqliteConnection("Data Source=:memory:");
        conn.Open();
        Database_TurnOnForeignKeys(conn);
        Schema.Initialize(conn);
        SeedDevice(conn);

        using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            INSERT INTO entries (uuid, created_at, captured_at, kind,
                                 source_device_id, content_hash, total_size)
            VALUES (x'00000000000000000000000000000000', 0, 0, 'bogus',
                    1, x'0000000000000000000000000000000000000000000000000000000000000000', 0)
            """;
        Assert.Throws<SqliteException>(() => cmd.ExecuteNonQuery());
    }

    [Fact]
    public void EntryFlavors_ExactlyOneOfDataOrBlobKey()
    {
        using var conn = new SqliteConnection("Data Source=:memory:");
        conn.Open();
        Database_TurnOnForeignKeys(conn);
        Schema.Initialize(conn);
        SeedDevice(conn);

        var entryId = InsertEntry(conn);

        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = """
                INSERT INTO entry_flavors (entry_id, uti, size, data, blob_key)
                VALUES ($id, 'public.utf8-plain-text', 5, NULL, NULL)
                """;
            cmd.Parameters.AddWithValue("$id", entryId);
            Assert.Throws<SqliteException>(() => cmd.ExecuteNonQuery());
        }

        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = """
                INSERT INTO entry_flavors (entry_id, uti, size, data, blob_key)
                VALUES ($id, 'public.utf8-plain-text', 5, x'68656c6c6f', 'abc123')
                """;
            cmd.Parameters.AddWithValue("$id", entryId);
            Assert.Throws<SqliteException>(() => cmd.ExecuteNonQuery());
        }
    }

    [Fact]
    public void Entries_HasV7V8V9Columns()
    {
        // The union DDL bakes Mac schema versions v7..v9 into a fresh DB:
        //   v7: body_evicted_at (reserved column for parity; eviction not
        //       yet implemented on Windows — see docs/parity.md § Storage
        //       management).
        //   v8: link_title + link_fetched_at — populated by the link-metadata
        //       backfiller.
        //   v9: link_retry_count + link_retry_after — exponential-backoff
        //       retry state. NOT NULL DEFAULT 0 on link_retry_count means
        //       fresh inserts get 0 without the ingestor having to mention
        //       the column.
        using var conn = new SqliteConnection("Data Source=:memory:");
        conn.Open();
        Schema.Initialize(conn);

        using var cmd = conn.CreateCommand();
        cmd.CommandText = "PRAGMA table_info(entries)";
        var found = new HashSet<string>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            // PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
            found.Add(reader.GetString(1));
        }
        Assert.Contains("body_evicted_at", found);
        Assert.Contains("link_title", found);
        Assert.Contains("link_fetched_at", found);
        Assert.Contains("link_retry_count", found);
        Assert.Contains("link_retry_after", found);
    }

    [Fact]
    public void EntriesFts_HasLinkTitleColumn()
    {
        // FTS5 indexes link_title alongside title/text/app_name/ocr_text/
        // image_tags so a fetched page title is searchable. Mac sourced this
        // shape in v8_link_metadata; we bake it in directly.
        using var conn = new SqliteConnection("Data Source=:memory:");
        conn.Open();
        Schema.Initialize(conn);

        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT sql FROM sqlite_master WHERE name='entries_fts'";
        var sql = cmd.ExecuteScalar() as string ?? "";
        Assert.Contains("link_title", sql);
    }

    [Fact]
    public void AppliedMigrationNames_IncludeV7V8V9()
    {
        // Sanity check: the seed list still names v7..v9 so a Mac install
        // opening this DB skips re-running them.
        Assert.Contains("v7_body_evicted",        Schema.AppliedMigrationNames);
        Assert.Contains("v8_link_metadata",       Schema.AppliedMigrationNames);
        Assert.Contains("v9_link_retry_backoff",  Schema.AppliedMigrationNames);
    }

    [Fact]
    public void LiveContentHashUniqueness_AllowsTombstonedDuplicate()
    {
        using var conn = new SqliteConnection("Data Source=:memory:");
        conn.Open();
        Database_TurnOnForeignKeys(conn);
        Schema.Initialize(conn);
        SeedDevice(conn);

        InsertEntry(conn, hashByte: 0x42, deletedAt: 1.0);
        InsertEntry(conn, hashByte: 0x42, deletedAt: null);

        using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            INSERT INTO entries (uuid, created_at, captured_at, kind,
                                 source_device_id, content_hash, total_size)
            VALUES (randomblob(16), 0, 0, 'text', 1,
                    x'4242424242424242424242424242424242424242424242424242424242424242', 0)
            """;
        Assert.Throws<SqliteException>(() => cmd.ExecuteNonQuery());
    }

    private static void Database_TurnOnForeignKeys(SqliteConnection conn)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "PRAGMA foreign_keys = ON";
        cmd.ExecuteNonQuery();
    }

    private static void SeedDevice(SqliteConnection conn)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            INSERT INTO devices (id, identifier, name, kind)
            VALUES (1, 'test-device', 'Test', 'win')
            """;
        cmd.ExecuteNonQuery();
    }

    private static long InsertEntry(SqliteConnection conn, byte hashByte = 0x00, double? deletedAt = null)
    {
        var hash = new byte[32];
        Array.Fill(hash, hashByte);

        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = """
                INSERT INTO entries (uuid, created_at, captured_at, kind,
                                     source_device_id, content_hash, total_size, deleted_at)
                VALUES (randomblob(16), 0, 0, 'text', 1, $h, 0, $d)
                """;
            cmd.Parameters.AddWithValue("$h", hash);
            cmd.Parameters.AddWithValue("$d", (object?)deletedAt ?? DBNull.Value);
            cmd.ExecuteNonQuery();
        }

        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT last_insert_rowid()";
            return (long)cmd.ExecuteScalar()!;
        }
    }
}
