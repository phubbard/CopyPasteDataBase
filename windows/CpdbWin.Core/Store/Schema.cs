using Microsoft.Data.Sqlite;

namespace CpdbWin.Core.Store;

/// <summary>
/// On-disk SQLite schema for cpdb-win. Bit-compatible with the macOS app's
/// schema v5 — see ../../../docs/schema.md for the cross-client contract.
/// New clients emit the union DDL below in one transaction rather than
/// replaying each migration. The list of migration identifiers is seeded
/// into <c>grdb_migrations</c> so the file is interchangeable with a Mac
/// install if we ever want it to be.
/// </summary>
public static class Schema
{
    public static readonly IReadOnlyList<string> AppliedMigrationNames = new[]
    {
        "v1",
        "v2",
        "v3",
        "v4_reseed_push_queue_for_flavors",
        "v5_content_addressed_records",
    };

    public const string UnionDdl = """
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
        CREATE INDEX idx_flavors_blob_key
            ON entry_flavors(blob_key) WHERE blob_key IS NOT NULL;

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

        CREATE TABLE pinboards (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid          BLOB UNIQUE NOT NULL,
            name          TEXT NOT NULL,
            color_argb    INTEGER,
            display_order INTEGER NOT NULL
        );

        CREATE TABLE pinboard_entries (
            pinboard_id   INTEGER NOT NULL REFERENCES pinboards(id) ON DELETE CASCADE,
            entry_id      INTEGER NOT NULL REFERENCES entries(id)  ON DELETE CASCADE,
            display_order INTEGER NOT NULL,
            PRIMARY KEY (pinboard_id, entry_id)
        );

        CREATE TABLE previews (
            entry_id    INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
            thumb_small BLOB,
            thumb_large BLOB
        );

        CREATE TABLE cloudkit_push_queue (
            entry_id          INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
            enqueued_at       REAL NOT NULL,
            last_attempted_at REAL,
            attempt_count     INTEGER NOT NULL DEFAULT 0,
            last_error        TEXT
        );
        CREATE INDEX idx_cloudkit_push_queue_enqueued_at
            ON cloudkit_push_queue(enqueued_at);

        CREATE TABLE cloudkit_state (
            key   TEXT PRIMARY KEY,
            value BLOB NOT NULL
        );

        CREATE VIRTUAL TABLE entries_fts USING fts5(
            title,
            text,
            app_name,
            ocr_text,
            image_tags,
            tokenize='porter unicode61 remove_diacritics 2'
        );

        CREATE TABLE grdb_migrations (
            identifier TEXT NOT NULL PRIMARY KEY
        );
        """;

    public static void Initialize(SqliteConnection conn)
    {
        using var tx = conn.BeginTransaction();

        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = UnionDdl;
            cmd.ExecuteNonQuery();
        }

        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "INSERT INTO grdb_migrations(identifier) VALUES ($id)";
            var p = cmd.CreateParameter();
            p.ParameterName = "$id";
            cmd.Parameters.Add(p);
            foreach (var name in AppliedMigrationNames)
            {
                p.Value = name;
                cmd.ExecuteNonQuery();
            }
        }

        tx.Commit();
    }
}
