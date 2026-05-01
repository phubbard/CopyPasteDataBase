using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

public class MigratorTests : IDisposable
{
    private readonly SqliteConnection _db;

    public MigratorTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
    }

    public void Dispose() => _db.Dispose();

    /// <summary>
    /// Build a v5-shaped database — what a v1.0 / v1.1 install would
    /// have on disk. Mirrors the union DDL that shipped at that time
    /// (no pinned, body_evicted_at, link_*).
    /// </summary>
    private void SeedV5Schema()
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            CREATE TABLE entries (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                uuid             BLOB NOT NULL UNIQUE,
                created_at       REAL NOT NULL,
                captured_at      REAL NOT NULL,
                kind             TEXT NOT NULL CHECK (kind IN ('text','link','image','file','color','other')),
                source_app_id    INTEGER REFERENCES apps(id),
                source_device_id INTEGER NOT NULL REFERENCES devices(id),
                title            TEXT,
                text_preview     TEXT,
                content_hash     BLOB NOT NULL,
                total_size       INTEGER NOT NULL,
                deleted_at       REAL,
                ocr_text         TEXT,
                image_tags       TEXT,
                analyzed_at      REAL
            );
            CREATE INDEX idx_entries_created_at ON entries(created_at DESC);
            CREATE INDEX idx_entries_kind ON entries(kind);
            CREATE UNIQUE INDEX idx_entries_live_content_hash
                ON entries(content_hash) WHERE deleted_at IS NULL;

            CREATE TABLE entry_flavors (
                entry_id  INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                uti       TEXT NOT NULL,
                size      INTEGER NOT NULL,
                data      BLOB,
                blob_key  TEXT,
                PRIMARY KEY (entry_id, uti),
                CHECK ((data IS NULL) <> (blob_key IS NULL))
            );

            CREATE TABLE apps (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                bundle_id TEXT UNIQUE NOT NULL,
                name      TEXT NOT NULL,
                icon_png  BLOB
            );

            CREATE TABLE devices (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                identifier TEXT UNIQUE NOT NULL,
                name       TEXT NOT NULL,
                kind       TEXT NOT NULL
            );

            CREATE VIRTUAL TABLE entries_fts USING fts5(
                title, text, app_name, ocr_text, image_tags,
                tokenize='porter unicode61 remove_diacritics 2'
            );

            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
            INSERT INTO grdb_migrations(identifier) VALUES ('v1');
            INSERT INTO grdb_migrations(identifier) VALUES ('v2');
            INSERT INTO grdb_migrations(identifier) VALUES ('v3');
            INSERT INTO grdb_migrations(identifier) VALUES ('v4_reseed_push_queue_for_flavors');
            INSERT INTO grdb_migrations(identifier) VALUES ('v5_content_addressed_records');
            """;
        cmd.ExecuteNonQuery();
    }

    private void SeedDevice()
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            INSERT INTO devices (id, identifier, name, kind)
            VALUES (1, 'test-device', 'Test', 'win')
            """;
        cmd.ExecuteNonQuery();
    }

    private void SeedEntry(long id, string title, string textPreview, byte hashByte = 0x42)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            INSERT INTO entries
                (id, uuid, created_at, captured_at, kind,
                 source_device_id, title, text_preview,
                 content_hash, total_size)
            VALUES
                ($id, randomblob(16), 1700000000, 1700000000, 'text',
                 1, $title, $tp,
                 $hash, $size)
            """;
        cmd.Parameters.AddWithValue("$id", id);
        cmd.Parameters.AddWithValue("$title", title);
        cmd.Parameters.AddWithValue("$tp", textPreview);
        var hash = new byte[32];
        Array.Fill(hash, hashByte);
        cmd.Parameters.AddWithValue("$hash", hash);
        cmd.Parameters.AddWithValue("$size", textPreview.Length);
        cmd.ExecuteNonQuery();
    }

    private HashSet<string> ColumnsOf(string table)
    {
        var set = new HashSet<string>();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = $"PRAGMA table_info({table})";
        using var r = cmd.ExecuteReader();
        while (r.Read()) set.Add(r.GetString(1));
        return set;
    }

    private HashSet<string> AppliedMigrations()
    {
        var set = new HashSet<string>();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT identifier FROM grdb_migrations";
        using var r = cmd.ExecuteReader();
        while (r.Read()) set.Add(r.GetString(0));
        return set;
    }

    // ─── EnsureSchema dispatch ───────────────────────────────────────────

    [Fact]
    public void EnsureSchema_FreshDb_RunsInitialize()
    {
        // No tables — Initialize fires.
        Migrator.EnsureSchema(_db);
        var cols = ColumnsOf("entries");
        Assert.Contains("link_title",       cols);
        Assert.Contains("link_retry_count", cols);
        Assert.Equal(Schema.AppliedMigrationNames.Count, AppliedMigrations().Count);
    }

    [Fact]
    public void EnsureSchema_AlreadyCurrentDb_NoOps()
    {
        // Initialize a fresh schema, then run EnsureSchema again — must
        // be idempotent.
        Schema.Initialize(_db);
        var beforeCount = AppliedMigrations().Count;

        Migrator.EnsureSchema(_db);

        Assert.Equal(beforeCount, AppliedMigrations().Count);
    }

    // ─── Per-migration upgrade paths ─────────────────────────────────────

    [Fact]
    public void Migrate_FromV5_AddsAllColumnsAndRecordsMigrations()
    {
        SeedV5Schema();
        // Sanity: pre-migration columns are absent.
        var preCols = ColumnsOf("entries");
        Assert.DoesNotContain("pinned",           preCols);
        Assert.DoesNotContain("body_evicted_at",  preCols);
        Assert.DoesNotContain("link_title",       preCols);
        Assert.DoesNotContain("link_fetched_at",  preCols);
        Assert.DoesNotContain("link_retry_count", preCols);
        Assert.DoesNotContain("link_retry_after", preCols);

        Migrator.Migrate(_db);

        var postCols = ColumnsOf("entries");
        Assert.Contains("pinned",           postCols);
        Assert.Contains("body_evicted_at",  postCols);
        Assert.Contains("link_title",       postCols);
        Assert.Contains("link_fetched_at",  postCols);
        Assert.Contains("link_retry_count", postCols);
        Assert.Contains("link_retry_after", postCols);

        var applied = AppliedMigrations();
        Assert.Contains("v6_pinned",             applied);
        Assert.Contains("v7_body_evicted",       applied);
        Assert.Contains("v8_link_metadata",      applied);
        Assert.Contains("v9_link_retry_backoff", applied);
    }

    [Fact]
    public void Migrate_FromV5_PreservesExistingData()
    {
        SeedV5Schema();
        SeedDevice();
        SeedEntry(id: 1, title: "first",  textPreview: "first body",  hashByte: 0x01);
        SeedEntry(id: 2, title: "second", textPreview: "second body", hashByte: 0x02);

        Migrator.Migrate(_db);

        // Both rows survive + the new columns default cleanly.
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            SELECT id, title, pinned, link_title, link_retry_count
            FROM entries ORDER BY id
            """;
        using var r = cmd.ExecuteReader();
        Assert.True(r.Read());
        Assert.Equal(1L,       r.GetInt64(0));
        Assert.Equal("first",  r.GetString(1));
        Assert.Equal(0L,       r.GetInt64(2));   // pinned default 0
        Assert.True(r.IsDBNull(3));              // link_title NULL
        Assert.Equal(0L,       r.GetInt64(4));   // link_retry_count default 0

        Assert.True(r.Read());
        Assert.Equal(2L,       r.GetInt64(0));
    }

    [Fact]
    public void Migrate_RebuildsFtsTableWithLinkTitleColumn()
    {
        SeedV5Schema();
        SeedDevice();
        SeedEntry(id: 1, title: "alpha", textPreview: "needle in haystack", hashByte: 0xA1);
        SeedEntry(id: 2, title: "beta",  textPreview: "different body",     hashByte: 0xB2);

        // Populate the v5 entries_fts so we have something to rebuild.
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = """
                INSERT INTO entries_fts(rowid, title, text, app_name, ocr_text, image_tags)
                VALUES (1, 'alpha', 'needle in haystack', '', '', ''),
                       (2, 'beta',  'different body',     '', '', '')
                """;
            cmd.ExecuteNonQuery();
        }

        Migrator.Migrate(_db);

        // entries_fts should now have 6 indexed columns including link_title.
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "SELECT sql FROM sqlite_master WHERE name='entries_fts'";
            var sql = cmd.ExecuteScalar() as string ?? "";
            Assert.Contains("link_title", sql);
        }

        // Reindex preserved searchable content for live rows.
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = """
                SELECT rowid FROM entries_fts WHERE entries_fts MATCH 'needle'
                """;
            var hit = cmd.ExecuteScalar();
            Assert.NotNull(hit);
            Assert.Equal(1L, (long)hit!);
        }
    }

    [Fact]
    public void Migrate_FromV5_PreservesAlreadyAppliedMigrations()
    {
        SeedV5Schema();
        // Manually apply v6_pinned the way a half-completed earlier
        // migration would — column present + ledger row present.
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = """
                ALTER TABLE entries ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
                INSERT INTO grdb_migrations(identifier) VALUES ('v6_pinned')
                """;
            cmd.ExecuteNonQuery();
        }

        // EnsureSchema must NOT try to re-add the column (would throw
        // "duplicate column name") and must run the rest.
        Migrator.Migrate(_db);

        var applied = AppliedMigrations();
        Assert.Contains("v6_pinned",             applied);
        Assert.Contains("v8_link_metadata",      applied);
        Assert.Contains("v9_link_retry_backoff", applied);

        // pinned still exactly one column entry (not duplicated).
        var pinnedCount = 0;
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "PRAGMA table_info(entries)";
            using var r = cmd.ExecuteReader();
            while (r.Read())
            {
                if (r.GetString(1) == "pinned") pinnedCount++;
            }
        }
        Assert.Equal(1, pinnedCount);
    }

    [Fact]
    public void Migrate_RunsTwice_IsIdempotent()
    {
        SeedV5Schema();
        Migrator.Migrate(_db);
        // Second run is a no-op.
        Migrator.Migrate(_db);

        // Each migration name appears exactly once in the ledger.
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            SELECT identifier, COUNT(*) FROM grdb_migrations
            GROUP BY identifier
            HAVING COUNT(*) > 1
            """;
        using var r = cmd.ExecuteReader();
        Assert.False(r.Read(), "no migration name should appear more than once");
    }

    [Fact]
    public void Migrate_DbWithoutMigrationsTable_TreatsAsPreV1AndCreatesLedger()
    {
        // Edge case: a database that's missing grdb_migrations entirely
        // (pre-v1 prototype, or someone manually nuked the table).
        // ReadAppliedMigrations creates it; Migrate then runs everything.
        // We seed the entries table (so IsInitialized would say true)
        // but skip the ledger.
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = """
                CREATE TABLE devices (id INTEGER PRIMARY KEY, identifier TEXT, name TEXT, kind TEXT);
                CREATE TABLE apps (id INTEGER PRIMARY KEY, bundle_id TEXT, name TEXT);
                CREATE TABLE entries (
                    id INTEGER PRIMARY KEY,
                    uuid BLOB,
                    created_at REAL,
                    captured_at REAL,
                    kind TEXT,
                    source_app_id INTEGER,
                    source_device_id INTEGER,
                    title TEXT,
                    text_preview TEXT,
                    content_hash BLOB,
                    total_size INTEGER,
                    deleted_at REAL,
                    ocr_text TEXT,
                    image_tags TEXT,
                    analyzed_at REAL
                );
                CREATE TABLE entry_flavors (
                    entry_id INTEGER, uti TEXT, size INTEGER, data BLOB, blob_key TEXT,
                    PRIMARY KEY(entry_id, uti)
                );
                CREATE VIRTUAL TABLE entries_fts USING fts5(
                    title, text, app_name, ocr_text, image_tags,
                    tokenize='porter unicode61 remove_diacritics 2'
                );
                """;
            cmd.ExecuteNonQuery();
        }

        Migrator.Migrate(_db);

        var applied = AppliedMigrations();
        Assert.Contains("v6_pinned",             applied);
        Assert.Contains("v9_link_retry_backoff", applied);
    }
}
