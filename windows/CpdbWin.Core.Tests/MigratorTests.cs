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

    // ─── v11_semantic_identity + v12_modified_at ───────────────────────

    /// <summary>
    /// Create the supplementary tables that <see cref="IdentityRehash.Coalesce"/>
    /// expects to exist on a real install. The v5 seed predates these in
    /// the test fixture's history, but every shipped DB has them — fresh
    /// installs via <see cref="Schema.Initialize"/>, and pre-v5 installs
    /// via earlier migrations not modeled here. Without them
    /// collision-merge SQL fails with "no such table".
    /// </summary>
    private void SeedSupplementaryTables()
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            CREATE TABLE IF NOT EXISTS pinboards (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                uuid          BLOB UNIQUE NOT NULL,
                name          TEXT NOT NULL,
                color_argb    INTEGER,
                display_order INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS pinboard_entries (
                pinboard_id   INTEGER NOT NULL REFERENCES pinboards(id) ON DELETE CASCADE,
                entry_id      INTEGER NOT NULL REFERENCES entries(id)  ON DELETE CASCADE,
                display_order INTEGER NOT NULL,
                PRIMARY KEY (pinboard_id, entry_id)
            );
            CREATE TABLE IF NOT EXISTS previews (
                entry_id    INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
                thumb_small BLOB,
                thumb_large BLOB
            );
            """;
        cmd.ExecuteNonQuery();
    }

    /// <summary>Insert a row + its flavors. Uses the v1 full-set hash as
    /// the seeded content_hash so the test mirrors what a real pre-v11
    /// install would have on disk.</summary>
    private void SeedEntryWithFlavors(
        long id, long createdAt, bool pinned, params (string Uti, byte[] Bytes)[] flavors)
    {
        var flavorList = flavors.Select(f => new CpdbWin.Core.Capture.CanonicalHash.Flavor(f.Uti, f.Bytes)).ToList();
        var v1Hash = CpdbWin.Core.Capture.CanonicalHash.Compute(
            new[] { (IReadOnlyList<CpdbWin.Core.Capture.CanonicalHash.Flavor>)flavorList });

        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = """
                INSERT INTO entries
                    (id, uuid, created_at, captured_at, kind, source_device_id,
                     title, text_preview, content_hash, total_size)
                VALUES
                    ($id, randomblob(16), $ts, $ts, 'text', 1,
                     NULL, NULL, $hash, $size)
                """;
            cmd.Parameters.AddWithValue("$id",   id);
            cmd.Parameters.AddWithValue("$ts",   (double)createdAt);
            cmd.Parameters.AddWithValue("$hash", v1Hash);
            cmd.Parameters.AddWithValue("$size", flavors.Sum(f => f.Bytes.Length));
            cmd.ExecuteNonQuery();
        }
        foreach (var (uti, bytes) in flavors)
        {
            using var f = _db.CreateCommand();
            f.CommandText = "INSERT INTO entry_flavors (entry_id, uti, size, data) VALUES ($id, $u, $s, $d)";
            f.Parameters.AddWithValue("$id", id);
            f.Parameters.AddWithValue("$u",  uti);
            f.Parameters.AddWithValue("$s",  bytes.Length);
            f.Parameters.AddWithValue("$d",  bytes);
            f.ExecuteNonQuery();
        }

        // SetPinned needs the pinned column which v5 doesn't have, but
        // by the time we'd call it the v6 migration has already run.
        // The fixture seeds raw inserts that target the post-v6 column
        // set indirectly: just patch pinned after the fact.
        if (pinned)
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = "UPDATE entries SET pinned = 1 WHERE id = $id";
            cmd.Parameters.AddWithValue("$id", id);
            cmd.ExecuteNonQuery();
        }
    }

    [Fact]
    public void V11Migration_RehashesV1RowsToV2AndCollisionMerges()
    {
        SeedV5Schema();
        SeedSupplementaryTables();
        SeedDevice();

        // Plain v6+ schema first so the seed rows have pinned column,
        // then seed the entries. Migrations v6-v10 add columns the
        // helper relies on.
        Migrator.Migrate(_db);

        // Chrome-sidecar collision pattern: two rows with identical text
        // but different volatile sidecars. v1 hashes them as different
        // entries (full-set varies); v2 collapses to a single text-rung
        // identity. Test pins this real-world dedup case.
        var hello = System.Text.Encoding.UTF8.GetBytes("hello");
        var sidecarA = System.Text.Encoding.UTF8.GetBytes("https://chromium.example/A");
        var sidecarB = System.Text.Encoding.UTF8.GetBytes("https://chromium.example/B");

        SeedEntryWithFlavors(id: 1, createdAt: 1700000000, pinned: false,
            ("public.utf8-plain-text", hello),
            ("org.chromium.source-url", sidecarA));
        SeedEntryWithFlavors(id: 2, createdAt: 1700000060, pinned: true,
            ("public.utf8-plain-text", hello),
            ("org.chromium.source-url", sidecarB));
        SeedEntryWithFlavors(id: 3, createdAt: 1700000120, pinned: false,
            ("public.utf8-plain-text", System.Text.Encoding.UTF8.GetBytes("unique entry")));

        // Mark v11/v12 as not-applied even though Migrate just ran them
        // implicitly — Migrate is idempotent and we want to re-run v11
        // against the seeded rows. (The first Migrate-after-seed pass
        // sees no entries; we seed after.)
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "DELETE FROM grdb_migrations WHERE identifier IN ('v11_semantic_identity', 'v12_modified_at')";
            cmd.ExecuteNonQuery();
        }
        // Reset the rehashed rows so v11 sees them as hash_version=1.
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "UPDATE entries SET hash_version = 1, prev_content_hash = NULL, identity_tag = NULL";
            cmd.ExecuteNonQuery();
        }

        Migrator.Migrate(_db, blobs: null);

        // 1. Survivor id=1 (earliest created_at) holds v2 hash; pinned
        //    inherited from id=2 via the OR-collapse rule.
        var survivor = ReadEntry(1);
        Assert.Equal(2L, survivor.HashVersion);
        Assert.Equal("text", survivor.IdentityTag);
        Assert.True(survivor.Pinned, "Pin should have salvaged onto the survivor (OR-collapse).");
        Assert.NotNull(survivor.PrevContentHash);
        Assert.Null(survivor.DeletedAt);
        // created_at bumps to MAX(group) = 1700000060.
        Assert.Equal(1700000060.0, survivor.CreatedAt);

        // 2. Loser id=2 tombstoned, reverted to v1 hash.
        var loser = ReadEntry(2);
        Assert.NotNull(loser.DeletedAt);
        Assert.Equal(1L, loser.HashVersion);
        Assert.Null(loser.IdentityTag);

        // 3. Unique row id=3 untouched (different identity, no collision).
        var lone = ReadEntry(3);
        Assert.Equal(2L, lone.HashVersion);
        Assert.Equal("text", lone.IdentityTag);
        Assert.Null(lone.DeletedAt);
        Assert.NotEqual(survivor.ContentHash, lone.ContentHash);

        // 4. The "live unique content_hash" invariant holds — each v2
        //    hash is held by exactly one live row.
        Assert.Equal(2L, ScalarLong("SELECT COUNT(DISTINCT content_hash) FROM entries WHERE deleted_at IS NULL"));
        Assert.Equal(2L, ScalarLong("SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL"));

        // 5. modified_at backfilled from created_at for all rows.
        Assert.True(ScalarDouble("SELECT MIN(modified_at) FROM entries") > 0,
            "v12 backfill should have populated modified_at from created_at.");
    }

    [Fact]
    public void V11Migration_IdempotentReRunIsNoOp()
    {
        SeedV5Schema();
        SeedSupplementaryTables();
        SeedDevice();
        Migrator.Migrate(_db);
        var hello = System.Text.Encoding.UTF8.GetBytes("hello");
        SeedEntryWithFlavors(1, 1700000000, false, ("public.utf8-plain-text", hello));

        // Reset so v11 will rehash on first call.
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "DELETE FROM grdb_migrations WHERE identifier IN ('v11_semantic_identity', 'v12_modified_at')";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "UPDATE entries SET hash_version = 1, prev_content_hash = NULL, identity_tag = NULL";
            cmd.ExecuteNonQuery();
        }

        Migrator.Migrate(_db, blobs: null);
        var afterFirst = ReadEntry(1);

        // Re-run should observe hash_version=2 already, skip the rehash,
        // and leave the row exactly as-is.
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "DELETE FROM grdb_migrations WHERE identifier = 'v11_semantic_identity'";
            cmd.ExecuteNonQuery();
        }
        Migrator.Migrate(_db, blobs: null);
        var afterSecond = ReadEntry(1);

        Assert.Equal(afterFirst.ContentHash,    afterSecond.ContentHash);
        Assert.Equal(afterFirst.HashVersion,    afterSecond.HashVersion);
        Assert.Equal(afterFirst.IdentityTag,    afterSecond.IdentityTag);
        Assert.Equal(afterFirst.PrevContentHash, afterSecond.PrevContentHash);
    }

    private record EntryRow(
        long Id, byte[] ContentHash, long HashVersion, string? IdentityTag,
        byte[]? PrevContentHash, bool Pinned, double CreatedAt, double? DeletedAt);

    private EntryRow ReadEntry(long id)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            SELECT id, content_hash, hash_version, identity_tag,
                   prev_content_hash, pinned, created_at, deleted_at
            FROM entries WHERE id = $id
            """;
        cmd.Parameters.AddWithValue("$id", id);
        using var r = cmd.ExecuteReader();
        Assert.True(r.Read(), $"entry id={id} missing");
        return new EntryRow(
            r.GetInt64(0),
            (byte[])r.GetValue(1),
            r.GetInt64(2),
            r.IsDBNull(3) ? null : r.GetString(3),
            r.IsDBNull(4) ? null : (byte[])r.GetValue(4),
            r.GetInt64(5) != 0,
            r.GetDouble(6),
            r.IsDBNull(7) ? (double?)null : r.GetDouble(7));
    }

    private long ScalarLong(string sql)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        return (long)cmd.ExecuteScalar()!;
    }

    private double ScalarDouble(string sql)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        return Convert.ToDouble(cmd.ExecuteScalar()!);
    }

    private string ScalarString(string sql)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        return (string)cmd.ExecuteScalar()!;
    }

    // ─── v13_semantic_enrichment + v14_recency_index ────────────────────

    [Fact]
    public void V13Migration_AddsEntryEmbeddingsTable_AndChipsJsonColumn()
    {
        SeedV5Schema();
        SeedSupplementaryTables();
        Migrator.Migrate(_db);  // runs through v14

        // entry_embeddings exists with the expected columns.
        var embedCols = ColumnsOf("entry_embeddings");
        Assert.Contains("entry_id",    embedCols);
        Assert.Contains("model_id",    embedCols);
        Assert.Contains("revision",    embedCols);
        Assert.Contains("dims",        embedCols);
        Assert.Contains("vector",      embedCols);
        Assert.Contains("embedded_at", embedCols);

        // chips_json landed on entries.
        Assert.Contains("chips_json", ColumnsOf("entries"));

        // Migration ledger records both new identifiers.
        var applied = AppliedMigrations();
        Assert.Contains("v13_semantic_enrichment", applied);
        Assert.Contains("v14_recency_index",       applied);
    }

    [Fact]
    public void V13Migration_IdempotentReRunIsNoOp()
    {
        SeedV5Schema();
        SeedSupplementaryTables();
        Migrator.Migrate(_db);

        // Wipe the ledger entries and re-run — the CREATE TABLE IF NOT
        // EXISTS + HasColumn guard should keep the run a no-op that
        // just re-records the identifier.
        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "DELETE FROM grdb_migrations WHERE identifier IN ('v13_semantic_enrichment', 'v14_recency_index')";
            cmd.ExecuteNonQuery();
        }
        Migrator.Migrate(_db);  // must not throw "duplicate column"/table

        Assert.Contains("v13_semantic_enrichment", AppliedMigrations());
        Assert.Contains("v14_recency_index",       AppliedMigrations());
    }

    [Fact]
    public void V15Migration_AddsCapturedAtIndex()
    {
        SeedV5Schema();
        SeedSupplementaryTables();
        Migrator.Migrate(_db);

        // The v15 partial index is what makes Neighbors() an index
        // walk instead of a full scan. If this stops firing, the
        // time-pivot query silently degrades on a real user's DB.
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            EXPLAIN QUERY PLAN
            SELECT id FROM entries
            WHERE deleted_at IS NULL
              AND captured_at BETWEEN ? AND ?
            ORDER BY captured_at ASC
            LIMIT 500
            """;
        cmd.Parameters.AddWithValue("$1", 0);
        cmd.Parameters.AddWithValue("$2", 100);
        using var r = cmd.ExecuteReader();
        var plans = new List<string>();
        while (r.Read()) plans.Add(r.GetString(3));

        Assert.Contains(plans, p => p.Contains("idx_entries_captured_at"));
        Assert.Contains("v15_captured_at_index", AppliedMigrations());
    }

    [Fact]
    public void V15Migration_IdempotentReRunIsNoOp()
    {
        SeedV5Schema();
        SeedSupplementaryTables();
        Migrator.Migrate(_db);

        using (var cmd = _db.CreateCommand())
        {
            cmd.CommandText = "DELETE FROM grdb_migrations WHERE identifier = 'v15_captured_at_index'";
            cmd.ExecuteNonQuery();
        }
        Migrator.Migrate(_db);  // CREATE INDEX IF NOT EXISTS: must be a no-op.
        Assert.Contains("v15_captured_at_index", AppliedMigrations());
    }

    [Fact]
    public void V14RecencyIndex_MatchesPopupRecentQueryShape()
    {
        SeedV5Schema();
        SeedSupplementaryTables();
        Migrator.Migrate(_db);

        // EXPLAIN QUERY PLAN of the popup's Recent() shape must hit
        // idx_entries_recency — the whole point of v14 is turning the
        // ORDER BY into an index walk. If this stops firing (e.g.
        // someone changes the ORDER BY), the test fails loudly.
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            EXPLAIN QUERY PLAN
            SELECT id FROM entries
            WHERE deleted_at IS NULL
            ORDER BY pinned DESC, created_at DESC
            LIMIT 100
            """;
        using var r = cmd.ExecuteReader();
        var plans = new List<string>();
        while (r.Read())
        {
            // table_info-shaped: id, parent, notused, detail(TEXT)
            plans.Add(r.GetString(3));
        }
        Assert.Contains(plans, p => p.Contains("idx_entries_recency"));
    }
}
