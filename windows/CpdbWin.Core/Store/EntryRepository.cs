using Microsoft.Data.Sqlite;

namespace CpdbWin.Core.Store;

/// <summary>
/// Read-side access for the UI: list / search / fetch a flavor's bytes,
/// tombstone an entry. Write-side ingest still goes through
/// <see cref="Ingest.Ingestor"/>.
/// </summary>
public sealed class EntryRepository
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;

    public EntryRepository(SqliteConnection db, BlobStore blobs)
    {
        _db = db;
        _blobs = blobs;
    }

    private const string SelectEntryColumns = """
        SELECT e.id, e.kind, e.title, e.text_preview,
               e.created_at, e.captured_at, e.total_size,
               a.bundle_id, a.name, p.thumb_small
        FROM entries e
        LEFT JOIN apps a ON a.id = e.source_app_id
        LEFT JOIN previews p ON p.entry_id = e.id
        """;

    /// <summary>Newest live entries first. <paramref name="limit"/> caps the row count.</summary>
    public IReadOnlyList<EntryRow> Recent(int limit = 100)
    {
        var sql = SelectEntryColumns + """

            WHERE e.deleted_at IS NULL
            ORDER BY e.created_at DESC
            LIMIT $limit
            """;
        return Query(sql, cmd => cmd.Parameters.AddWithValue("$limit", limit));
    }

    /// <summary>FTS5 MATCH against the <c>entries_fts</c> shadow table.</summary>
    public IReadOnlyList<EntryRow> Search(string ftsQuery, int limit = 100)
    {
        var sql = SelectEntryColumns + """

            JOIN entries_fts f ON f.rowid = e.id
            WHERE entries_fts MATCH $q AND e.deleted_at IS NULL
            ORDER BY e.created_at DESC
            LIMIT $limit
            """;
        return Query(sql, cmd =>
        {
            cmd.Parameters.AddWithValue("$q", ftsQuery);
            cmd.Parameters.AddWithValue("$limit", limit);
        });
    }

    public IReadOnlyList<FlavorRow> Flavors(long entryId)
    {
        const string sql = """
            SELECT uti, size, data IS NOT NULL, blob_key
            FROM entry_flavors WHERE entry_id = $id
            ORDER BY uti
            """;
        var rows = new List<FlavorRow>();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.Parameters.AddWithValue("$id", entryId);
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            rows.Add(new FlavorRow(
                EntryId: entryId,
                Uti: reader.GetString(0),
                Size: reader.GetInt64(1),
                IsInline: reader.GetInt64(2) != 0,
                BlobKey: reader.IsDBNull(3) ? null : reader.GetString(3)
            ));
        }
        return rows;
    }

    /// <summary>Returns the large preview thumbnail (≤ 640 px JPEG) or null.</summary>
    public byte[]? GetThumbLarge(long entryId)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT thumb_large FROM previews WHERE entry_id = $id";
        cmd.Parameters.AddWithValue("$id", entryId);
        var v = cmd.ExecuteScalar();
        return v as byte[];
    }

    /// <summary>
    /// Resolves a single flavor's bytes — either from the inline column or
    /// from the on-disk blob store. Returns null if the flavor doesn't exist.
    /// </summary>
    public byte[]? GetFlavorBytes(long entryId, string uti)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "SELECT data, blob_key FROM entry_flavors WHERE entry_id=$id AND uti=$u";
        cmd.Parameters.AddWithValue("$id", entryId);
        cmd.Parameters.AddWithValue("$u", uti);
        using var reader = cmd.ExecuteReader();
        if (!reader.Read()) return null;

        if (!reader.IsDBNull(0)) return (byte[])reader.GetValue(0);
        if (!reader.IsDBNull(1)) return _blobs.Get(reader.GetString(1));
        return null;
    }

    /// <summary>
    /// Mark <paramref name="entryId"/> deleted (sets <c>deleted_at</c>) and
    /// remove the FTS5 row so the entry stops surfacing in searches. The
    /// blob store keeps its bytes until <c>cpdb gc</c>.
    /// </summary>
    public void Tombstone(long entryId, DateTimeOffset? at = null)
        => TombstoneMany(new[] { entryId }, at);

    /// <summary>
    /// Tombstone several entries inside one transaction. Cheaper than
    /// looping <see cref="Tombstone"/> when the UI deletes multi-selected
    /// rows.
    /// </summary>
    public void TombstoneMany(IEnumerable<long> entryIds, DateTimeOffset? at = null)
    {
        var ts = (at ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;

        using var tx = _db.BeginTransaction();
        using var update = _db.CreateCommand();
        update.Transaction = tx;
        update.CommandText = "UPDATE entries SET deleted_at=$t WHERE id=$id AND deleted_at IS NULL";
        var pT = update.CreateParameter(); pT.ParameterName = "$t"; pT.Value = ts;
        var pId = update.CreateParameter(); pId.ParameterName = "$id";
        update.Parameters.Add(pT); update.Parameters.Add(pId);

        using var fts = _db.CreateCommand();
        fts.Transaction = tx;
        fts.CommandText = "DELETE FROM entries_fts WHERE rowid=$id";
        var pFts = fts.CreateParameter(); pFts.ParameterName = "$id";
        fts.Parameters.Add(pFts);

        foreach (var id in entryIds)
        {
            pId.Value = id;
            update.ExecuteNonQuery();
            pFts.Value = id;
            fts.ExecuteNonQuery();
        }
        tx.Commit();
    }

    private List<EntryRow> Query(string sql, Action<SqliteCommand> bind)
    {
        var rows = new List<EntryRow>();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        bind(cmd);
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            rows.Add(new EntryRow(
                Id: reader.GetInt64(0),
                Kind: reader.GetString(1),
                Title: reader.IsDBNull(2) ? null : reader.GetString(2),
                TextPreview: reader.IsDBNull(3) ? null : reader.GetString(3),
                CreatedAt: reader.GetDouble(4),
                CapturedAt: reader.GetDouble(5),
                TotalSize: reader.GetInt64(6),
                AppBundleId: reader.IsDBNull(7) ? null : reader.GetString(7),
                AppName: reader.IsDBNull(8) ? null : reader.GetString(8),
                ThumbSmall: reader.IsDBNull(9) ? null : (byte[])reader.GetValue(9)
            ));
        }
        return rows;
    }
}

public readonly record struct EntryRow(
    long Id,
    string Kind,
    string? Title,
    string? TextPreview,
    double CreatedAt,
    double CapturedAt,
    long TotalSize,
    string? AppBundleId,
    string? AppName,
    byte[]? ThumbSmall);

public readonly record struct FlavorRow(
    long EntryId,
    string Uti,
    long Size,
    bool IsInline,
    string? BlobKey);
