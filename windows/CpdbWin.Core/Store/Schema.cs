using Microsoft.Data.Sqlite;

namespace CpdbWin.Core.Store;

/// <summary>
/// On-disk SQLite schema for cpdb-win. Bit-compatible with the macOS app's
/// schema v9 — see ../../../docs/schema.md for the cross-client contract.
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
        "v6_pinned",
        "v7_body_evicted",
        "v8_link_metadata",
        "v9_link_retry_backoff",
        "v10_image_per_pass_timestamps",
        // Per docs/handoffs/windows-hash-v2.md: identifier collision with
        // macOS at v10 (Mac has v10_semantic_identity / v11_modified_at;
        // Windows had v10_image_per_pass_timestamps shipped first).
        // Migration identifiers are local bookkeeping; the cross-platform
        // contract is column-set + algorithm, not identifier-string
        // equality. We add the v2 work under fresh identifiers from v11
        // upward so each platform's grdb_migrations remains internally
        // consistent. See docs/schema.md §Migration identifiers.
        "v11_semantic_identity",
        "v12_modified_at",
        // v13/v14 mirror macOS v12_semantic_enrichment + v14_recency_index
        // (per docs/handoffs/windows-v33-features.md). Identifier numbers
        // are per-platform local bookkeeping; the contract is column-set +
        // algorithm equality across platforms.
        "v13_semantic_enrichment",
        "v14_recency_index",
        // v15 (v1.48.0 time-pivot): captured_at partial index the
        // Neighbors() range scan walks instead of full-scanning the
        // table. See docs/parity.md → Time-pivot mode.
        "v15_captured_at_index",
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
            analyzed_at      REAL,
            pinned           INTEGER NOT NULL DEFAULT 0,
            -- v7: tier-2 eviction sentinel. Reserved column for parity
            -- with Mac schema; eviction itself is not yet implemented
            -- on Windows (see docs/parity.md § Storage management).
            body_evicted_at  REAL,
            -- v8: background-fetched link metadata.
            link_title       TEXT,
            link_fetched_at  REAL,
            -- v9: exponential-backoff retry state for the link fetcher.
            link_retry_count INTEGER NOT NULL DEFAULT 0,
            link_retry_after REAL,
            -- v10: per-pass sentinels for image analysis. NULL = "this
            -- pass hasn't run yet for this image" — independently
            -- candidate for OCR vs the classifier so Preferences can
            -- offer separate "Re-OCR" and "Re-tag" buttons that don't
            -- collide. analyzed_at stays as a Mac-parity "ever
            -- processed" sentinel; both passes stamp it on settle.
            ocr_at           REAL,
            tags_at          REAL,
            -- v11 (semantic identity, mirrors macOS canonical-hash v2):
            -- hash_version=1 is the legacy full-set hash; 2 is the rung-
            -- chain identity that converges sidecar-varying duplicates.
            -- prev_content_hash retains the v1 hash for forensics + a
            -- dual-era dedup probe in importers. identity_tag is the
            -- rung that produced a v2 hash (image/file/url/text/color/
            -- fallback). Fresh installs land at v2 from the start.
            hash_version       INTEGER NOT NULL DEFAULT 1,
            prev_content_hash  BLOB,
            identity_tag       TEXT,
            -- v12 (modified_at, mirrors macOS 3.1.0): unix-seconds
            -- timestamp of the last user mutation (pin / delete /
            -- restore). On the Mac it drives last-writer-wins on sync
            -- pull; Windows is standalone today so we just maintain
            -- the column for schema parity + future sync. Defaults to
            -- 0 so the migration backfill from created_at is a single
            -- UPDATE rather than NOT-NULL-violating row-by-row.
            modified_at        REAL NOT NULL DEFAULT 0,
            -- v13 (semantic enrichment, mirrors macOS 3.3.0's
            -- v12_semantic_enrichment): chips_json holds a JSON array
            -- of data chips detected in the entry's text (dates,
            -- phones, tracking numbers, URLs, etc). NULL = not yet
            -- scanned. Chip detection code lands in a follow-on
            -- release; the column is here now so the schema is
            -- forward-compatible with v14 (recency index) and doesn't
            -- need another migration when chips ship.
            chips_json         TEXT
        );
        CREATE INDEX idx_entries_created_at ON entries(created_at DESC);
        CREATE INDEX idx_entries_kind ON entries(kind);
        CREATE UNIQUE INDEX idx_entries_live_content_hash
            ON entries(content_hash) WHERE deleted_at IS NULL;
        CREATE INDEX idx_entries_pinned
            ON entries(created_at DESC)
            WHERE pinned = 1 AND deleted_at IS NULL;
        -- v14 (recency index, mirrors macOS 3.3.0's v14_recency_index):
        -- the popup's Recent() query orders by (pinned DESC, created_at
        -- DESC) over live rows. Without this composite partial index
        -- SQLite full-scans + temp-B-tree-sorts every live row; v13's
        -- new chips_json + future enrichment columns fatten pages, so
        -- the scan cost grows. This index turns the ORDER BY into an
        -- index walk that stops at LIMIT. Mac caught this on their
        -- first v3.3 launch via their popup-perf log.
        CREATE INDEX idx_entries_recency
            ON entries(pinned DESC, created_at DESC)
            WHERE deleted_at IS NULL;
        -- v15 (captured_at index, v1.48.0 time-pivot): the pivot
        -- primitive (EntryRepository.Neighbors) does a bounded range
        -- scan on captured_at BETWEEN $lo AND $hi; without this index
        -- SQLite full-scans every live row and filters. Partial on
        -- deleted_at IS NULL for the same reason idx_entries_recency
        -- is — the tombstone check falls out of the index walk.
        CREATE INDEX idx_entries_captured_at
            ON entries(captured_at)
            WHERE deleted_at IS NULL;

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

        -- v13 (semantic enrichment): one row per entry with a semantic
        -- embedding vector. Kept as its own table (not columns on
        -- entries) because a model upgrade re-embeds by delete+insert,
        -- not a wide-table ALTER, and most entries (images, files)
        -- never get a row at all.
        --   model_id    — identifies the embedding function (e.g.
        --                 'onnx-minilm-l6-v2'). Cross-platform contract
        --                 is that vectors are per-device-family; do NOT
        --                 compare Mac vectors with Windows vectors.
        --   revision    — bump to trigger a background re-embed sweep
        --                 without changing model_id (e.g. a preprocessing
        --                 tweak to the same model).
        --   vector      — dims × Float32, little-endian, L2-normalized
        --                 so cosine similarity is a plain dot product.
        CREATE TABLE entry_embeddings (
            entry_id    INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
            model_id    TEXT NOT NULL,
            revision    INTEGER NOT NULL,
            dims        INTEGER NOT NULL,
            vector      BLOB NOT NULL,
            embedded_at REAL NOT NULL
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
            link_title,
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
