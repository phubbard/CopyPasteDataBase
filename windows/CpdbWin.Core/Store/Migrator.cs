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
    public static void Migrate(SqliteConnection conn)
    {
        var applied = ReadAppliedMigrations(conn);

        if (!applied.Contains("v6_pinned"))      ApplyV6Pinned(conn);
        if (!applied.Contains("v7_body_evicted")) ApplyV7BodyEvicted(conn);
        if (!applied.Contains("v8_link_metadata")) ApplyV8LinkMetadata(conn);
        if (!applied.Contains("v9_link_retry_backoff")) ApplyV9LinkRetryBackoff(conn);
    }

    /// <summary>
    /// Single entry point AppHost calls on every boot. Fresh installs
    /// hit <see cref="Schema.Initialize"/>; existing installs flow
    /// through <see cref="Migrate"/>. Either way the DB ends at the
    /// current schema with <c>grdb_migrations</c> in agreement.
    /// </summary>
    public static void EnsureSchema(SqliteConnection conn)
    {
        if (!Database.IsInitialized(conn))
        {
            Schema.Initialize(conn);
            return;
        }
        Migrate(conn);
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
}
