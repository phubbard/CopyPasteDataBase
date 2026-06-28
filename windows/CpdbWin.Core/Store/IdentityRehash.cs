using CpdbWin.Core.Capture;
using Microsoft.Data.Sqlite;

namespace CpdbWin.Core.Store;

/// <summary>
/// One-shot library rehash that converts every entry's
/// <c>content_hash</c> from canonical-hash v1 (full-set SHA-256 over every
/// stored flavor) to v2 (semantic identity — see
/// <see cref="ContentIdentity"/>) and merges rows that collapse to a
/// shared identity. Used by the <c>v11_semantic_identity</c> migration.
///
/// <para>
/// Self-contained so <c>MigratorTests</c> can construct a fixture DB and
/// exercise it without standing up an <c>AppHost</c>. The migration
/// invokes <see cref="Run"/> + <see cref="MergeCollisions"/> inside its
/// own transaction; this class never opens its own.
/// </para>
///
/// <para>
/// Mirrors the Mac's <c>Sources/CpdbShared/Store/IdentityCutover.swift</c>
/// (collision-merge phase) + <c>Sources/CpdbShared/Store/EntryCoalesce.swift</c>
/// (salvage rules), adapted for the Windows column set + the standalone
/// (no-CloudKit) model. Per docs/handoffs/windows-hash-v2.md, no
/// pull-side conflict resolution, no zone work — just the local rehash.
/// </para>
/// </summary>
public static class IdentityRehash
{
    /// <summary>
    /// Recompute the v2 content_hash for every live row that has readable
    /// flavor bytes. Body-evicted rows (or rows whose flavors live in a
    /// blob store we can't reach) keep their v1 hash + hash_version=1
    /// untouched. Returns the count of rows successfully rehashed to v2.
    ///
    /// <para>
    /// The caller must have already dropped any unique index on
    /// <c>content_hash</c> — collision merge runs after this, so during
    /// rehash the column will transiently hold duplicates. The caller
    /// (the migrator) recreates the unique index after merging.
    /// </para>
    /// </summary>
    public static int Run(SqliteConnection conn, SqliteTransaction tx, BlobStore? blobs)
    {
        var ids = new List<long>();
        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            // Include tombstoned rows too — they have valid flavor bytes and
            // collision merge in step 2 relies on their hashes being
            // comparable. Mac does the same (any row with content gets
            // rehashed).
            cmd.CommandText = "SELECT id FROM entries ORDER BY id";
            using var r = cmd.ExecuteReader();
            while (r.Read()) ids.Add(r.GetInt64(0));
        }

        int rehashed = 0;
        foreach (var id in ids)
        {
            var flavors = ReadFlavors(conn, tx, id, blobs);
            if (flavors.Count == 0) continue;  // body-evicted / unreadable

            var oldHash = ReadContentHash(conn, tx, id);
            var (tag, newHash) = ContentIdentity.Compute(flavors);

            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = """
                UPDATE entries
                SET content_hash      = $h,
                    prev_content_hash = COALESCE(prev_content_hash, $prev),
                    hash_version      = 2,
                    identity_tag      = $tag
                WHERE id = $id
                """;
            cmd.Parameters.AddWithValue("$h",    newHash);
            cmd.Parameters.AddWithValue("$prev", oldHash);
            cmd.Parameters.AddWithValue("$tag",  ContentIdentity.TagString(tag));
            cmd.Parameters.AddWithValue("$id",   id);
            cmd.ExecuteNonQuery();
            rehashed++;
        }
        return rehashed;
    }

    /// <summary>
    /// Find live rows that share a v2 <c>content_hash</c> and collapse
    /// each cluster onto the earliest-created survivor (tie-break smallest
    /// id). Per-cluster: <see cref="Coalesce"/> the losers' enrichment onto
    /// the survivor, then <see cref="RetireLoser"/> each loser (tombstone +
    /// revert to v1 hash so each v2 hash is held by exactly one live row).
    /// Returns <c>(clusters, losersTombstoned)</c>.
    /// </summary>
    public static (int Clusters, int LosersTombstoned) MergeCollisions(
        SqliteConnection conn, SqliteTransaction tx, double now)
    {
        var dupHashes = new List<byte[]>();
        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = """
                SELECT content_hash FROM entries
                WHERE deleted_at IS NULL
                GROUP BY content_hash
                HAVING COUNT(*) > 1
                """;
            using var r = cmd.ExecuteReader();
            while (r.Read()) dupHashes.Add((byte[])r.GetValue(0));
        }

        int clusters = 0, losersTotal = 0;
        foreach (var hash in dupHashes)
        {
            var ids = new List<long>();
            using (var cmd = conn.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = """
                    SELECT id FROM entries
                    WHERE deleted_at IS NULL AND content_hash = $h
                    ORDER BY created_at ASC, id ASC
                    """;
                cmd.Parameters.AddWithValue("$h", hash);
                using var r = cmd.ExecuteReader();
                while (r.Read()) ids.Add(r.GetInt64(0));
            }
            if (ids.Count <= 1) continue;
            clusters++;
            var survivor = ids[0];
            var losers   = ids.Skip(1).ToList();
            Coalesce(conn, tx, survivor, losers, now);
            foreach (var l in losers) RetireLoser(conn, tx, l, now);
            losersTotal += losers.Count;
        }
        return (clusters, losersTotal);
    }

    // ── Salvage (mirrors EntryCoalesce.swift) ────────────────────────────

    internal static void Coalesce(
        SqliteConnection conn, SqliteTransaction tx,
        long survivorId, IReadOnlyList<long> loserIds, double now)
    {
        if (loserIds.Count == 0) return;
        var loserList = string.Join(",", loserIds);
        var allList   = string.Join(",", new[] { survivorId }.Concat(loserIds));

        // pinned = OR(group); created_at = MAX(group) (bump-recency).
        Exec(conn, tx, $"""
            UPDATE entries SET
                pinned     = (SELECT MAX(pinned)     FROM entries WHERE id IN ({allList})),
                created_at = (SELECT MAX(created_at) FROM entries WHERE id IN ({allList}))
            WHERE id = $sid
            """,
            ("$sid", survivorId));

        // Scalar salvage: fill survivor NULLs from losers.
        // link_title prefers the most-recently-fetched donor (carries
        // link_fetched_at alongside so we don't strand the timestamp).
        var (curLinkTitle, _) = ReadStringDouble(conn, tx,
            "SELECT link_title, link_fetched_at FROM entries WHERE id = $id", survivorId);
        if (string.IsNullOrEmpty(curLinkTitle))
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = $"""
                SELECT link_title, link_fetched_at FROM entries
                WHERE id IN ({loserList})
                  AND link_title IS NOT NULL AND link_title != ''
                ORDER BY link_fetched_at DESC LIMIT 1
                """;
            using var r = cmd.ExecuteReader();
            if (r.Read())
            {
                string? donorTitle = r.IsDBNull(0) ? null : r.GetString(0);
                double? donorAt    = r.IsDBNull(1) ? (double?)null : r.GetDouble(1);
                r.Close();
                Exec(conn, tx, """
                    UPDATE entries
                    SET link_title      = $t,
                        link_fetched_at = COALESCE(link_fetched_at, $f)
                    WHERE id = $sid
                    """,
                    ("$t",   (object?)donorTitle ?? DBNull.Value),
                    ("$f",   (object?)donorAt    ?? DBNull.Value),
                    ("$sid", survivorId));
            }
        }

        // Other null-scalar fills: take any non-null donor.
        foreach (var col in new[] { "title", "text_preview", "ocr_text", "image_tags" })
        {
            Exec(conn, tx, $"""
                UPDATE entries SET {col} =
                    (SELECT {col} FROM entries WHERE id IN ({loserList}) AND {col} IS NOT NULL LIMIT 1)
                WHERE id = $sid AND {col} IS NULL
                """,
                ("$sid", survivorId));
        }

        // analyzed_at / ocr_at / tags_at: deterministic re-derivations,
        // take MAX(donor) when survivor is null (avoids re-running OCR/
        // classifier on the merged row).
        foreach (var col in new[] { "analyzed_at", "ocr_at", "tags_at" })
        {
            Exec(conn, tx, $"""
                UPDATE entries SET {col} =
                    (SELECT MAX({col}) FROM entries WHERE id IN ({loserList}))
                WHERE id = $sid AND {col} IS NULL
                """,
                ("$sid", survivorId));
        }

        // Previews: keep survivor's. If empty, re-point the first loser's
        // row. UPDATE OR IGNORE handles the rare survivor-already-has-one
        // race silently.
        bool survivorHasPreview = ScalarBool(conn, tx,
            "SELECT EXISTS(SELECT 1 FROM previews WHERE entry_id = $id)", survivorId);
        if (!survivorHasPreview)
        {
            Exec(conn, tx, $"""
                UPDATE OR IGNORE previews SET entry_id = $sid
                WHERE entry_id = (SELECT entry_id FROM previews WHERE entry_id IN ({loserList}) LIMIT 1)
                """,
                ("$sid", survivorId));
        }

        // Pinboard memberships: re-point loser refs onto survivor (PK is
        // (pinboard_id, entry_id), so UPDATE OR IGNORE silently drops
        // duplicates); then delete anything still pointing at a loser —
        // that's a genuine duplicate that didn't migrate.
        Exec(conn, tx, $"""
            UPDATE OR IGNORE pinboard_entries SET entry_id = $sid WHERE entry_id IN ({loserList})
            """,
            ("$sid", survivorId));
        Exec(conn, tx, $"DELETE FROM pinboard_entries WHERE entry_id IN ({loserList})");

        // Flavors: adopt UTIs the survivor lacks (union). SKIPPED when
        // the survivor's body has been evicted — flavor rows were
        // deliberately discarded and re-adding partials from a loser
        // would leave the row in an incoherent state.
        double? survivorEvicted = ScalarNullableDouble(conn, tx,
            "SELECT body_evicted_at FROM entries WHERE id = $id", survivorId);
        if (survivorEvicted is null)
        {
            Exec(conn, tx, $"""
                INSERT OR IGNORE INTO entry_flavors (entry_id, uti, size, data, blob_key)
                SELECT $sid, uti, size, data, blob_key
                FROM entry_flavors WHERE entry_id IN ({loserList})
                """,
                ("$sid", survivorId));
            Exec(conn, tx, """
                UPDATE entries SET total_size =
                    (SELECT COALESCE(SUM(size), 0) FROM entry_flavors WHERE entry_id = $sid)
                WHERE id = $sid
                """,
                ("$sid", survivorId));
        }
    }

    internal static void RetireLoser(SqliteConnection conn, SqliteTransaction tx, long loserId, double now)
    {
        // Revert the loser's content_hash to its v1 form and re-stamp
        // hash_version=1 so the unique-on-live index can be safely
        // rebuilt: each v2 hash is held by exactly one LIVE row (the
        // survivor); losers are tombstoned with a different (v1) hash.
        // Mirror IdentityCutover.swift §retireLoser case 1.
        Exec(conn, tx, """
            UPDATE entries
            SET deleted_at   = $now,
                modified_at  = $now,
                content_hash = COALESCE(prev_content_hash, content_hash),
                hash_version = 1,
                identity_tag = NULL
            WHERE id = $id
            """,
            ("$now", now), ("$id", loserId));
    }

    // ── Flavor reading (inline column OR blob store) ─────────────────────

    private static List<CanonicalHash.Flavor> ReadFlavors(
        SqliteConnection conn, SqliteTransaction tx, long entryId, BlobStore? blobs)
    {
        var rows = new List<(string Uti, object Data, string? BlobKey)>();
        using (var cmd = conn.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "SELECT uti, data, blob_key FROM entry_flavors WHERE entry_id = $id";
            cmd.Parameters.AddWithValue("$id", entryId);
            using var r = cmd.ExecuteReader();
            while (r.Read())
            {
                rows.Add((
                    r.GetString(0),
                    r.IsDBNull(1) ? DBNull.Value : r.GetValue(1),
                    r.IsDBNull(2) ? null : r.GetString(2)));
            }
        }

        var flavors = new List<CanonicalHash.Flavor>(rows.Count);
        foreach (var (uti, data, blobKey) in rows)
        {
            byte[]? bytes = data as byte[];
            if (bytes is null && blobKey is not null && blobs is not null && blobs.Has(blobKey))
                bytes = blobs.Get(blobKey);
            // If neither resolved (body evicted, missing blob), skip this
            // flavor. If all flavors skip, the row is unrehashable and the
            // caller keeps v1.
            if (bytes is null) continue;
            flavors.Add(new CanonicalHash.Flavor(uti, bytes));
        }
        return flavors;
    }

    private static byte[] ReadContentHash(SqliteConnection conn, SqliteTransaction tx, long id)
    {
        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = "SELECT content_hash FROM entries WHERE id = $id";
        cmd.Parameters.AddWithValue("$id", id);
        return (byte[])cmd.ExecuteScalar()!;
    }

    // ── Tiny SQL helpers (this class owns its boilerplate) ───────────────

    private static void Exec(
        SqliteConnection conn, SqliteTransaction tx, string sql,
        params (string Name, object Value)[] parameters)
    {
        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = sql;
        foreach (var (n, v) in parameters) cmd.Parameters.AddWithValue(n, v);
        cmd.ExecuteNonQuery();
    }

    private static bool ScalarBool(SqliteConnection conn, SqliteTransaction tx, string sql, long id)
    {
        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = sql;
        cmd.Parameters.AddWithValue("$id", id);
        var v = cmd.ExecuteScalar();
        return v is long n && n != 0;
    }

    private static double? ScalarNullableDouble(
        SqliteConnection conn, SqliteTransaction tx, string sql, long id)
    {
        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = sql;
        cmd.Parameters.AddWithValue("$id", id);
        var v = cmd.ExecuteScalar();
        return v is null or DBNull ? null : Convert.ToDouble(v);
    }

    private static (string? Str, double? D) ReadStringDouble(
        SqliteConnection conn, SqliteTransaction tx, string sql, long id)
    {
        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = sql;
        cmd.Parameters.AddWithValue("$id", id);
        using var r = cmd.ExecuteReader();
        if (!r.Read()) return (null, null);
        string? s = r.IsDBNull(0) ? null : r.GetString(0);
        double? d = r.IsDBNull(1) ? null : r.GetDouble(1);
        return (s, d);
    }
}
