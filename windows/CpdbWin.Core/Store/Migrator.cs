using Microsoft.Data.Sqlite;

namespace CpdbWin.Core.Store;

/// <summary>
/// Idempotent forward-only schema migrator. <see cref="Schema.Initialize"/>
/// emits the union DDL on a brand-new database; this class brings an
/// existing database (a v1.0 / v1.1 install at schema v5, say) up to the
/// current schema by running each missing migration in order.
///
/// <para>
/// Each step:
/// </para>
/// <list type="bullet">
/// <item>Checks <c>grdb_migrations</c> for the migration name. Skip if
///       already applied.</item>
/// <item>Runs the DDL inside its own transaction so a partial failure
///       leaves the DB at a clean intermediate version.</item>
/// <item>Records the migration name on success.</item>
/// </list>
///
/// <para>
/// Migrations match macOS GRDB names verbatim so a Mac install opening
/// a Windows-migrated DB sees the same applied set and skips them.
/// </para>
/// </summary>
public static class Migrator
{
    /// <summary>
    /// Run any pending migrations against an existing DB. Safe to call
    /// on a fully-up-to-date database — the loop short-circuits on each
    /// already-applied step. Throws on SQL errors so the caller (AppHost
    /// boot) can fail loudly rather than silently corrupt state.
    /// </summary>
    public static void Migrate(SqliteConnection conn, BlobStore? blobs = null)
    {
        var applied = ReadAppliedMigrations(conn);

        if (!applied.Contains("v6_pinned"))      ApplyV6Pinned(conn);
        if (!applied.Contains("v7_body_evicted")) ApplyV7BodyEvicted(conn);
        if (!applied.Contains("v8_link_metadata")) ApplyV8LinkMetadata(conn);
        if (!applied.Contains("v9_link_retry_backoff")) ApplyV9LinkRetryBackoff(conn);
        if (!applied.Contains("v10_image_per_pass_timestamps")) ApplyV10ImagePerPassTimestamps(conn);
        // v12 runs BEFORE v11: the v11 collision-merge SQL references
        // modified_at when retiring losers, so the column must exist
        // first. The migration *identifiers* keep their numeric ordering
        // (it's just a naming convention; grdb_migrations records them
        // independently of execution order).
        if (!applied.Contains("v12_modified_at")) ApplyV12ModifiedAt(conn);
        if (!applied.Contains("v11_semantic_identity")) ApplyV11SemanticIdentity(conn, blobs);
        if (!applied.Contains("v13_semantic_enrichment")) ApplyV13SemanticEnrichment(conn);
        if (!applied.Contains("v14_recency_index")) ApplyV14RecencyIndex(conn);
    }

    /// <summary>
    /// Single entry point AppHost calls on every boot. Fresh installs
    /// hit <see cref="Schema.Initialize"/>; existing installs flow
    /// through <see cref="Migrate"/>. Either way the DB ends at the
    /// current schema with <c>grdb_migrations</c> in agreement.
    ///
    /// <para>
    /// <paramref name="blobs"/> is required only for the
    /// <c>v11_semantic_identity</c> rehash (reads out-of-line flavor
    /// bytes by blob_key). Pass null in tests that use inline flavors
    /// only — rows with unreadable flavors keep their v1 hash, same
    /// as real body-evicted rows.
    /// </para>
    /// </summary>
    public static void EnsureSchema(SqliteConnection conn, BlobStore? blobs = null)
    {
        if (!Database.IsInitialized(conn))
        {
            Schema.Initialize(conn);
            return;
        }
        Migrate(conn, blobs);
    }

    private static HashSet<string> ReadAppliedMigrations(SqliteConnection conn)
    {
        // Some very old (pre-grdb_migrations) DBs may be missing the
        // ledger table entirely. Treat that as "no migrations applied"
        // and create the table; the per-migration steps will populate.
        using (var ensure = conn.CreateCommand())
        {
            ensure.CommandText =
                "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)";
            ensure.ExecuteNonQuery();
        }

        var set = new HashSet<string>();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT identifier FROM grdb_migrations";
        using var r = cmd.ExecuteReader();
        while (r.Read()) set.Add(r.GetString(0));
        return set;
    }

    private static void RecordApplied(SqliteConnection conn, SqliteTransaction tx, string name)
    {
        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = "INSERT INTO grdb_migrations(identifier) VALUES ($id)";
        cmd.Parameters.AddWithValue("$id", name);
        cmd.ExecuteNonQuery();
    }

    /// <summary>
    /// True iff <paramref name="table"/> already has <paramref name="column"/>.
    /// Defensive guard so a re-run doesn't trip "duplicate column" on a
    /// DB where someone partially applied a migration by hand.
    /// </summary>
    private static bool HasColumn(SqliteConnection conn, string table, string column)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = $"PRAGMA table_info({table})";
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            // table_info columns: cid, name, type, notnull, dflt_value, pk
            if (r.GetString(1) == column) return true;
        }
        return false;
    }

    // ─── v6: pinned + idx_entries_pinned ────────────────────────────────

    private static void ApplyV6Pinned(SqliteConnection conn)
    {
        using var tx = conn.BeginTransaction();

        if (!HasColumn(conn, "entries", "pinned"))
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = "ALTER TABLE entries ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0";
            cmd.ExecuteNonQuery();
        }

        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                CREATE INDEX IF NOT EXISTS idx_entries_pinned
                    ON entries(created_at DESC)
                    WHERE pinned = 1 AND deleted_at IS NULL
                """;
            cmd.ExecuteNonQuery();
        }

        RecordApplied(conn, tx, "v6_pinned");
        tx.Commit();
    }

    // ─── v7: body_evicted_at (reserved column for sync parity) ──────────

    private static void ApplyV7BodyEvicted(SqliteConnection conn)
    {
        using var tx = conn.BeginTransaction();

        if (!HasColumn(conn, "entries", "body_evicted_at"))
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = "ALTER TABLE entries ADD COLUMN body_evicted_at REAL";
            cmd.ExecuteNonQuery();
        }

        RecordApplied(conn, tx, "v7_body_evicted");
        tx.Commit();
    }

    // ─── v8: link_title + link_fetched_at + FTS5 rebuild ────────────────

    private static void ApplyV8LinkMetadata(SqliteConnection conn)
    {
        using var tx = conn.BeginTransaction();

        if (!HasColumn(conn, "entries", "link_title"))
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = "ALTER TABLE entries ADD COLUMN link_title TEXT";
            cmd.ExecuteNonQuery();
        }
        if (!HasColumn(conn, "entries", "link_fetched_at"))
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = "ALTER TABLE entries ADD COLUMN link_fetched_at REAL";
            cmd.ExecuteNonQuery();
        }

        // FTS5 doesn't support ALTER. Drop the shadow table and rebuild
        // it with the new column, then reindex every live row. Same
        // dance as the macOS v8 migration.
        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "DROP TABLE IF EXISTS entries_fts";
            cmd.ExecuteNonQuery();
        }
        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                CREATE VIRTUAL TABLE entries_fts USING fts5(
                    title,
                    text,
                    app_name,
                    ocr_text,
                    image_tags,
                    link_title,
                    tokenize='porter unicode61 remove_diacritics 2'
                )
                """;
            cmd.ExecuteNonQuery();
        }
        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                INSERT INTO entries_fts(rowid, title, text, app_name, ocr_text, image_tags, link_title)
                SELECT e.id,
                       COALESCE(e.title, ''),
                       COALESCE(e.text_preview, ''),
                       COALESCE(a.name, ''),
                       COALESCE(e.ocr_text, ''),
                       COALESCE(e.image_tags, ''),
                       COALESCE(e.link_title, '')
                FROM entries e
                LEFT JOIN apps a ON a.id = e.source_app_id
                WHERE e.deleted_at IS NULL
                """;
            cmd.ExecuteNonQuery();
        }

        RecordApplied(conn, tx, "v8_link_metadata");
        tx.Commit();
    }

    // ─── v9: link_retry_count + link_retry_after ────────────────────────

    private static void ApplyV9LinkRetryBackoff(SqliteConnection conn)
    {
        using var tx = conn.BeginTransaction();

        if (!HasColumn(conn, "entries", "link_retry_count"))
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText =
                "ALTER TABLE entries ADD COLUMN link_retry_count INTEGER NOT NULL DEFAULT 0";
            cmd.ExecuteNonQuery();
        }
        if (!HasColumn(conn, "entries", "link_retry_after"))
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = "ALTER TABLE entries ADD COLUMN link_retry_after REAL";
            cmd.ExecuteNonQuery();
        }

        RecordApplied(conn, tx, "v9_link_retry_backoff");
        tx.Commit();
    }

    // ─── v10: per-pass image-analysis timestamps ───────────────────────

    /// <summary>
    /// Adds <c>ocr_at</c> + <c>tags_at</c> to <c>entries</c> so the
    /// image OCR pass and the classifier-tag pass can be reset
    /// independently (Preferences "Re-OCR images" vs "Re-tag images").
    /// Existing rows that already went through the unified analyzer
    /// (analyzed_at non-null) get backfilled on both so they don't
    /// look like fresh candidates after the upgrade. <c>analyzed_at</c>
    /// is retained for Mac-parity / "ever processed at all" semantics
    /// — both passes still stamp it on settle.
    /// </summary>
    private static void ApplyV10ImagePerPassTimestamps(SqliteConnection conn)
    {
        using var tx = conn.BeginTransaction();

        if (!HasColumn(conn, "entries", "ocr_at"))
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = "ALTER TABLE entries ADD COLUMN ocr_at REAL";
            cmd.ExecuteNonQuery();
        }
        if (!HasColumn(conn, "entries", "tags_at"))
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = "ALTER TABLE entries ADD COLUMN tags_at REAL";
            cmd.ExecuteNonQuery();
        }

        // Backfill from the existing unified sentinel: anything that
        // already ran through the analyzer is "OCR done + tags done"
        // (the pre-v10 service did both in one shot). Without this,
        // every previously-analyzed image would re-process on first
        // boot post-upgrade.
        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                UPDATE entries
                SET ocr_at  = COALESCE(ocr_at,  analyzed_at),
                    tags_at = COALESCE(tags_at, analyzed_at)
                WHERE kind = 'image' AND analyzed_at IS NOT NULL
                """;
            cmd.ExecuteNonQuery();
        }

        RecordApplied(conn, tx, "v10_image_per_pass_timestamps");
        tx.Commit();
    }

    // ─── v11: semantic identity (canonical-hash v2) ─────────────────────

    /// <summary>
    /// Add the v2 identity columns, recompute every readable row's
    /// content_hash via <see cref="Capture.ContentIdentity"/>, then
    /// collision-merge rows that collapse to the same identity. Per
    /// <c>docs/handoffs/windows-hash-v2.md</c>: ContentIdentity + the
    /// rehash MUST ship in the same release — otherwise the capture
    /// path's new dedup key and the existing rows disagree and every
    /// re-capture forks the library.
    /// </summary>
    private static void ApplyV11SemanticIdentity(SqliteConnection conn, BlobStore? blobs)
    {
        using var tx = conn.BeginTransaction();

        // 1. Add columns (idempotent guards).
        if (!HasColumn(conn, "entries", "hash_version"))
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = "ALTER TABLE entries ADD COLUMN hash_version INTEGER NOT NULL DEFAULT 1";
            cmd.ExecuteNonQuery();
        }
        if (!HasColumn(conn, "entries", "prev_content_hash"))
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = "ALTER TABLE entries ADD COLUMN prev_content_hash BLOB";
            cmd.ExecuteNonQuery();
        }
        if (!HasColumn(conn, "entries", "identity_tag"))
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = "ALTER TABLE entries ADD COLUMN identity_tag TEXT";
            cmd.ExecuteNonQuery();
        }

        // Idempotence: if any row is already at hash_version=2 the rehash
        // has run. Just record the migration name and exit.
        long alreadyV2;
        using (var probe = conn.CreateCommand())
        {
            probe.Transaction = tx;
            probe.CommandText = "SELECT COUNT(*) FROM entries WHERE hash_version = 2";
            alreadyV2 = (long)probe.ExecuteScalar()!;
        }
        if (alreadyV2 > 0)
        {
            RecordApplied(conn, tx, "v11_semantic_identity");
            tx.Commit();
            return;
        }

        // 2. Drop the unique-on-live index — rehash will transiently
        // produce duplicate content_hash values; collision-merge cleans
        // them up; index is recreated below.
        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "DROP INDEX IF EXISTS idx_entries_live_content_hash";
            cmd.ExecuteNonQuery();
        }

        // 3. Recompute every row's identity. Body-evicted rows / rows
        // with unresolvable blob_key keep v1 hash + hash_version=1.
        IdentityRehash.Run(conn, tx, blobs);

        // 4. Collision-merge: collapse rows now sharing a v2 hash.
        double now = ((DateTimeOffset)DateTime.UtcNow).ToUnixTimeMilliseconds() / 1000.0;
        IdentityRehash.MergeCollisions(conn, tx, now);

        // 5. Recreate the unique-on-live index.
        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_entries_live_content_hash
                    ON entries(content_hash) WHERE deleted_at IS NULL
                """;
            cmd.ExecuteNonQuery();
        }

        RecordApplied(conn, tx, "v11_semantic_identity");
        tx.Commit();
    }

    // ─── v12: modified_at (LWW timestamp for future sync) ──────────────

    /// <summary>
    /// Add <c>modified_at</c> tracking the last user mutation (pin /
    /// delete / restore). On macOS this drives last-writer-wins
    /// resolution on sync pull; Windows is standalone today so the
    /// column is here for schema parity + future sync. Backfill from
    /// <c>created_at</c> so the value is meaningful from day one.
    /// </summary>
    private static void ApplyV12ModifiedAt(SqliteConnection conn)
    {
        using var tx = conn.BeginTransaction();

        if (!HasColumn(conn, "entries", "modified_at"))
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            // ADD COLUMN with NOT NULL DEFAULT 0 lets existing rows take
            // the default; the UPDATE below replaces 0 with created_at.
            // Fresh installs land at the same place via Schema.UnionDdl.
            cmd.CommandText = "ALTER TABLE entries ADD COLUMN modified_at REAL NOT NULL DEFAULT 0";
            cmd.ExecuteNonQuery();
        }

        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "UPDATE entries SET modified_at = created_at WHERE modified_at = 0";
            cmd.ExecuteNonQuery();
        }

        RecordApplied(conn, tx, "v12_modified_at");
        tx.Commit();
    }

    // ─── v13: semantic-enrichment foundation ────────────────────────────

    /// <summary>
    /// Create the <c>entry_embeddings</c> table and the <c>chips_json</c>
    /// column that back cpdb-win's semantic-search + action-chips
    /// features. Schema-only — the pipelines that populate them
    /// (<c>EmbeddingSweeper</c>, chip detector) land in follow-on
    /// releases. Mirrors macOS 3.3.0's <c>v12_semantic_enrichment</c>
    /// per <c>docs/handoffs/windows-v33-features.md</c>. The
    /// <c>ai_title</c>/<c>ai_summary</c>/<c>ai_retry_count</c> columns
    /// Mac adds here + at v13 are skipped: Foundation Models is
    /// Copilot+-only on Windows so the enrichment stream is not
    /// planned. Columns can be added later if a Windows AI-enrichment
    /// path ever earns its keep.
    /// </summary>
    private static void ApplyV13SemanticEnrichment(SqliteConnection conn)
    {
        using var tx = conn.BeginTransaction();

        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                CREATE TABLE IF NOT EXISTS entry_embeddings (
                    entry_id    INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
                    model_id    TEXT NOT NULL,
                    revision    INTEGER NOT NULL,
                    dims        INTEGER NOT NULL,
                    vector      BLOB NOT NULL,
                    embedded_at REAL NOT NULL
                )
                """;
            cmd.ExecuteNonQuery();
        }

        if (!HasColumn(conn, "entries", "chips_json"))
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = "ALTER TABLE entries ADD COLUMN chips_json TEXT";
            cmd.ExecuteNonQuery();
        }

        RecordApplied(conn, tx, "v13_semantic_enrichment");
        tx.Commit();
    }

    // ─── v14: recency partial index ─────────────────────────────────────

    /// <summary>
    /// Composite partial index over <c>(pinned DESC, created_at DESC)
    /// WHERE deleted_at IS NULL</c>. The popup's <c>Recent()</c> query
    /// orders by exactly this shape; without the index SQLite
    /// full-scans + temp-B-tree-sorts every live row on every call.
    /// v13's <c>chips_json</c> column (plus any future per-row
    /// enrichment writes) fattens pages, so the scan cost grows —
    /// this index turns the ORDER BY into an index walk that stops at
    /// LIMIT. Mirrors macOS 3.3.0's <c>v14_recency_index</c>; Mac
    /// caught the need on their first v3.3 launch via their
    /// popup-perf log. Windows already meets its summon-perf target
    /// (see <c>PopupPerf</c>) but ships this proactively so v13 +
    /// future writes don't regress it.
    /// </summary>
    private static void ApplyV14RecencyIndex(SqliteConnection conn)
    {
        using var tx = conn.BeginTransaction();

        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                CREATE INDEX IF NOT EXISTS idx_entries_recency
                    ON entries(pinned DESC, created_at DESC)
                    WHERE deleted_at IS NULL
                """;
            cmd.ExecuteNonQuery();
        }

        RecordApplied(conn, tx, "v14_recency_index");
        tx.Commit();
    }
}
