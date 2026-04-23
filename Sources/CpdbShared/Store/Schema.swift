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

        migrator.registerMigration("v2") { db in
            // Two new columns on entries for the image-analysis pipeline.
            // `analyzed_at` is the NULL-vs-non-NULL sentinel that tells the
            // backfill command which rows still need processing.
            try db.execute(sql: "ALTER TABLE entries ADD COLUMN ocr_text TEXT;")
            try db.execute(sql: "ALTER TABLE entries ADD COLUMN image_tags TEXT;")
            try db.execute(sql: "ALTER TABLE entries ADD COLUMN analyzed_at REAL;")

            // FTS5 virtual tables can't be ALTERed. Drop + recreate with the
            // new 5-column layout, then reindex every live row. The reindex
            // is O(n) but cheap — title/text/app_name fit inline in RAM for
            // a 10k-entry corpus.
            try db.execute(sql: "DROP TABLE entries_fts;")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE entries_fts USING fts5(
                    title,
                    text,
                    app_name,
                    ocr_text,
                    image_tags,
                    tokenize='porter unicode61 remove_diacritics 2'
                );
            """)

            // Reindex. OCR and image_tags are empty because we haven't
            // run the analyzer yet — `cpdb analyze-images` backfills them.
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.id, e.title, e.text_preview, a.name AS app_name,
                       e.ocr_text, e.image_tags
                FROM entries e
                LEFT JOIN apps a ON a.id = e.source_app_id
                WHERE e.deleted_at IS NULL
            """)
            for row in rows {
                try db.execute(
                    sql: """
                        INSERT INTO entries_fts(rowid, title, text, app_name, ocr_text, image_tags)
                        VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        row["id"] as Int64,
                        (row["title"] as String?) ?? "",
                        (row["text_preview"] as String?) ?? "",
                        (row["app_name"] as String?) ?? "",
                        (row["ocr_text"] as String?) ?? "",
                        (row["image_tags"] as String?) ?? "",
                    ]
                )
            }
        }

        migrator.registerMigration("v3") { db in
            // CloudKit sync bookkeeping.
            //
            // `cloudkit_push_queue`: one row per Entry that has local
            // changes the syncer hasn't pushed yet. Keyed on entry_id so
            // repeated enqueues coalesce — the syncer pushes the *current*
            // state of the entry, not a log of individual changes. Deletes
            // don't need a separate op: a tombstone is a save with
            // deleted_at set.
            //
            // `cloudkit_state`: opaque key/value bag for zone change
            // tokens, last-pull timestamps, and other syncer state that
            // doesn't deserve its own schema. Values are bytes because
            // change tokens are NSSecureCoding blobs.
            try db.execute(sql: """
                CREATE TABLE cloudkit_push_queue (
                    entry_id          INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
                    enqueued_at       REAL NOT NULL,
                    last_attempted_at REAL,
                    attempt_count     INTEGER NOT NULL DEFAULT 0,
                    last_error        TEXT
                );
            """)
            try db.execute(sql: """
                CREATE INDEX idx_cloudkit_push_queue_enqueued_at
                    ON cloudkit_push_queue(enqueued_at);
            """)
            try db.execute(sql: """
                CREATE TABLE cloudkit_state (
                    key   TEXT PRIMARY KEY,
                    value BLOB NOT NULL
                );
            """)

            // Seed the push queue with every live entry on a fresh v3 —
            // a user upgrading from v2 wants their whole history mirrored
            // to CloudKit, not just entries captured after the upgrade.
            // On a fresh install (no entries yet) this is a no-op.
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: """
                    INSERT INTO cloudkit_push_queue (entry_id, enqueued_at)
                    SELECT id, ? FROM entries
                """,
                arguments: [now]
            )
        }
    }
}
