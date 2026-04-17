import Foundation
import GRDB

/// Schema migrations. Add a new closure for each version; never edit a shipped one.
enum Schema {
    static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            // entries — one row per captured/imported clipboard event
            try db.execute(sql: """
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
                    deleted_at       REAL
                );
            """)
            try db.execute(sql: "CREATE INDEX idx_entries_created_at ON entries(created_at DESC);")
            try db.execute(sql: "CREATE INDEX idx_entries_kind ON entries(kind);")
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_entries_live_content_hash
                    ON entries(content_hash) WHERE deleted_at IS NULL;
            """)

            // flavors — one row per NSPasteboardItem UTI
            try db.execute(sql: """
                CREATE TABLE entry_flavors (
                    entry_id  INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                    uti       TEXT NOT NULL,
                    size      INTEGER NOT NULL,
                    data      BLOB,
                    blob_key  TEXT,
                    PRIMARY KEY (entry_id, uti),
                    CHECK ((data IS NULL) <> (blob_key IS NULL))
                );
            """)
            try db.execute(sql: """
                CREATE INDEX idx_flavors_blob_key
                    ON entry_flavors(blob_key) WHERE blob_key IS NOT NULL;
            """)

            // apps — source application metadata
            try db.execute(sql: """
                CREATE TABLE apps (
                    id        INTEGER PRIMARY KEY AUTOINCREMENT,
                    bundle_id TEXT UNIQUE NOT NULL,
                    name      TEXT NOT NULL,
                    icon_png  BLOB
                );
            """)

            // devices — machines that captured entries
            try db.execute(sql: """
                CREATE TABLE devices (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    identifier TEXT UNIQUE NOT NULL,
                    name       TEXT NOT NULL,
                    kind       TEXT NOT NULL
                );
            """)

            // pinboards — user-organised lists (imported from Paste for now)
            try db.execute(sql: """
                CREATE TABLE pinboards (
                    id            INTEGER PRIMARY KEY AUTOINCREMENT,
                    uuid          BLOB UNIQUE NOT NULL,
                    name          TEXT NOT NULL,
                    color_argb    INTEGER,
                    display_order INTEGER NOT NULL
                );
            """)

            try db.execute(sql: """
                CREATE TABLE pinboard_entries (
                    pinboard_id   INTEGER NOT NULL REFERENCES pinboards(id) ON DELETE CASCADE,
                    entry_id      INTEGER NOT NULL REFERENCES entries(id)  ON DELETE CASCADE,
                    display_order INTEGER NOT NULL,
                    PRIMARY KEY (pinboard_id, entry_id)
                );
            """)

            // previews — small/large JPEG thumbnails (optional)
            try db.execute(sql: """
                CREATE TABLE previews (
                    entry_id    INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
                    thumb_small BLOB,
                    thumb_large BLOB
                );
            """)

            // FTS5 index populated manually by FtsIndex.swift. We deliberately
            // do NOT use `content=''` (contentless) mode — it doesn't support
            // snippet() / highlight(). We do NOT use `content='entries'`
            // (external content) either, because our searchable text comes from
            // three tables (entries.title/text_preview + apps.name), which
            // external content can't express. Cost is a mild duplication of
            // text_preview in the FTS shadow tables; worth it for snippets.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE entries_fts USING fts5(
                    title,
                    text,
                    app_name,
                    tokenize='porter unicode61 remove_diacritics 2'
                );
            """)
        }
    }
}
