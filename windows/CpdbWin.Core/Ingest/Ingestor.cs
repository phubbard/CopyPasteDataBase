using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;

namespace CpdbWin.Core.Ingest;

/// <summary>
/// Writes a captured <see cref="ClipboardSnapshot"/> to the database, or
/// bumps the existing row when the content hash already exists live.
/// Mirrors Sources/CpdbCore/Capture/Ingestor.swift but trimmed to the v1
/// scope: no CloudKit push queue, no thumbnails, no OCR, no within-window
/// flavor-rewrite dedup. Each ingest runs inside one SQLite transaction.
/// </summary>
public sealed class Ingestor
{
    public const int BlobInlineThresholdBytes = 256 * 1024;

    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly IgnoredApps _ignored;

    public Ingestor(SqliteConnection db, BlobStore blobs, IgnoredApps? ignored = null)
    {
        _db = db;
        _blobs = blobs;
        _ignored = ignored ?? new IgnoredApps();
    }

    public IngestOutcome Ingest(
        ClipboardSnapshot snapshot,
        ForegroundApp.Info? sourceApp,
        DeviceIdentity.Info device,
        DateTimeOffset? capturedAt = null)
    {
        if (snapshot.Flavors.Count == 0)
            return new IngestOutcome(IngestKind.Skipped, 0, "empty snapshot");

        if (_ignored.ShouldIgnore(sourceApp))
            return new IngestOutcome(IngestKind.Skipped, 0,
                $"ignored app: {sourceApp!.Value.BundleId}");

        var hash = snapshot.ContentHash();
        var ts = (capturedAt ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;

        using var tx = _db.BeginTransaction();

        var existingId = LookupLiveByHash(tx, hash);
        if (existingId is not null)
        {
            BumpCreatedAt(tx, existingId.Value, ts);
            tx.Commit();
            return new IngestOutcome(IngestKind.Bumped, existingId.Value);
        }

        var deviceId = UpsertDevice(tx, device);
        long? appId = sourceApp is { } app ? UpsertApp(tx, app) : null;

        var (title, preview) = TitleAndPreview.Derive(snapshot.Flavors);
        var kind = KindClassifier.Classify(snapshot.Flavors);
        long totalSize = 0;
        foreach (var f in snapshot.Flavors) totalSize += f.Data.Length;

        var entryId = InsertEntry(tx, NewUuidBigEndian(), ts, kind, appId, deviceId,
            title, preview, hash, totalSize);

        foreach (var flavor in snapshot.Flavors)
            InsertFlavor(tx, entryId, flavor);

        InsertFts(tx, entryId, title, preview, sourceApp?.Name);

        if (kind == "image")
        {
            var imageBytes = FindImageFlavorBytes(snapshot.Flavors);
            if (imageBytes is not null)
            {
                var thumbs = Thumbnailer.Generate(imageBytes);
                if (thumbs.Small is not null || thumbs.Large is not null)
                    UpsertPreview(tx, entryId, thumbs.Small, thumbs.Large);
            }
        }

        tx.Commit();
        return new IngestOutcome(IngestKind.Inserted, entryId);
    }

    private static byte[]? FindImageFlavorBytes(IReadOnlyList<CanonicalHash.Flavor> flavors)
    {
        // Prefer PNG (lossless); fall back to JPEG. Both are what the
        // capture pipeline produces, so one of them is present whenever
        // KindClassifier returned "image".
        foreach (var f in flavors)
            if (f.Uti == "public.png" && f.Data.Length >= 1024) return f.Data.ToArray();
        foreach (var f in flavors)
            if (f.Uti == "public.jpeg" && f.Data.Length >= 1024) return f.Data.ToArray();
        return null;
    }

    private void UpsertPreview(SqliteTransaction tx, long entryId, byte[]? small, byte[]? large)
    {
        using var cmd = _db.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = """
            INSERT INTO previews(entry_id, thumb_small, thumb_large)
            VALUES($id, $s, $l)
            ON CONFLICT(entry_id) DO UPDATE SET thumb_small=$s, thumb_large=$l
            """;
        cmd.Parameters.AddWithValue("$id", entryId);
        cmd.Parameters.AddWithValue("$s", (object?)small ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$l", (object?)large ?? DBNull.Value);
        cmd.ExecuteNonQuery();
    }

    // --- queries ---

    private long? LookupLiveByHash(SqliteTransaction tx, byte[] hash)
    {
        using var cmd = _db.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = "SELECT id FROM entries WHERE content_hash = $h AND deleted_at IS NULL LIMIT 1";
        cmd.Parameters.AddWithValue("$h", hash);
        var v = cmd.ExecuteScalar();
        return v is null or DBNull ? null : (long)v;
    }

    private void BumpCreatedAt(SqliteTransaction tx, long id, double ts)
    {
        using var cmd = _db.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = "UPDATE entries SET created_at = $t WHERE id = $id";
        cmd.Parameters.AddWithValue("$t", ts);
        cmd.Parameters.AddWithValue("$id", id);
        cmd.ExecuteNonQuery();
    }

    private long UpsertDevice(SqliteTransaction tx, DeviceIdentity.Info info)
    {
        using (var sel = _db.CreateCommand())
        {
            sel.Transaction = tx;
            sel.CommandText = "SELECT id FROM devices WHERE identifier = $i";
            sel.Parameters.AddWithValue("$i", info.Identifier);
            var v = sel.ExecuteScalar();
            if (v is not null and not DBNull) return (long)v;
        }
        using var ins = _db.CreateCommand();
        ins.Transaction = tx;
        ins.CommandText = "INSERT INTO devices(identifier, name, kind) VALUES($i, $n, $k)";
        ins.Parameters.AddWithValue("$i", info.Identifier);
        ins.Parameters.AddWithValue("$n", info.Name);
        ins.Parameters.AddWithValue("$k", info.Kind);
        ins.ExecuteNonQuery();
        return LastInsertRowId(tx);
    }

    private long UpsertApp(SqliteTransaction tx, ForegroundApp.Info info)
    {
        using (var sel = _db.CreateCommand())
        {
            sel.Transaction = tx;
            sel.CommandText = "SELECT id FROM apps WHERE bundle_id = $b";
            sel.Parameters.AddWithValue("$b", info.BundleId);
            var v = sel.ExecuteScalar();
            if (v is not null and not DBNull) return (long)v;
        }
        using var ins = _db.CreateCommand();
        ins.Transaction = tx;
        ins.CommandText = "INSERT INTO apps(bundle_id, name) VALUES($b, $n)";
        ins.Parameters.AddWithValue("$b", info.BundleId);
        ins.Parameters.AddWithValue("$n", info.Name);
        ins.ExecuteNonQuery();
        return LastInsertRowId(tx);
    }

    private long InsertEntry(
        SqliteTransaction tx, byte[] uuid, double ts, string kind,
        long? appId, long deviceId, string? title, string? preview,
        byte[] hash, long totalSize)
    {
        using var cmd = _db.CreateCommand();
        cmd.Transaction = tx;
        // captured_at is set to the same value as created_at on insert; only
        // created_at moves on dedup-bump (captured_at stays immutable).
        cmd.CommandText = """
            INSERT INTO entries
                (uuid, created_at, captured_at, kind, source_app_id, source_device_id,
                 title, text_preview, content_hash, total_size)
            VALUES
                ($uuid, $ts, $ts, $kind, $appId, $devId,
                 $title, $preview, $hash, $size)
            """;
        cmd.Parameters.AddWithValue("$uuid", uuid);
        cmd.Parameters.AddWithValue("$ts", ts);
        cmd.Parameters.AddWithValue("$kind", kind);
        cmd.Parameters.AddWithValue("$appId", (object?)appId ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$devId", deviceId);
        cmd.Parameters.AddWithValue("$title", (object?)title ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$preview", (object?)preview ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$hash", hash);
        cmd.Parameters.AddWithValue("$size", totalSize);
        cmd.ExecuteNonQuery();
        return LastInsertRowId(tx);
    }

    private void InsertFlavor(SqliteTransaction tx, long entryId, CanonicalHash.Flavor flavor)
    {
        var bytes = flavor.Data.ToArray();
        byte[]? inline = null;
        string? blobKey = null;
        if (bytes.Length < BlobInlineThresholdBytes) inline = bytes;
        else blobKey = _blobs.Put(bytes);

        using var cmd = _db.CreateCommand();
        cmd.Transaction = tx;
        // INSERT OR IGNORE because (entry_id, uti) is the PK. A pasteboard
        // shouldn't publish the same UTI twice in one item, but if it does,
        // keep the first.
        cmd.CommandText = """
            INSERT OR IGNORE INTO entry_flavors(entry_id, uti, size, data, blob_key)
            VALUES($e, $u, $s, $d, $k)
            """;
        cmd.Parameters.AddWithValue("$e", entryId);
        cmd.Parameters.AddWithValue("$u", flavor.Uti);
        cmd.Parameters.AddWithValue("$s", (long)bytes.Length);
        cmd.Parameters.AddWithValue("$d", (object?)inline ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$k", (object?)blobKey ?? DBNull.Value);
        cmd.ExecuteNonQuery();
    }

    private void InsertFts(SqliteTransaction tx, long entryId, string? title, string? preview, string? appName)
    {
        using var cmd = _db.CreateCommand();
        cmd.Transaction = tx;
        // OCR/tags stay empty in v1. Empty strings (not NULL) so FTS5 indexes
        // them as zero-length tokens, matching how CpdbCore writes the row.
        cmd.CommandText = """
            INSERT INTO entries_fts(rowid, title, text, app_name, ocr_text, image_tags)
            VALUES($id, $title, $text, $app, '', '')
            """;
        cmd.Parameters.AddWithValue("$id", entryId);
        cmd.Parameters.AddWithValue("$title", title ?? "");
        cmd.Parameters.AddWithValue("$text", preview ?? "");
        cmd.Parameters.AddWithValue("$app", appName ?? "");
        cmd.ExecuteNonQuery();
    }

    private long LastInsertRowId(SqliteTransaction tx)
    {
        using var cmd = _db.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = "SELECT last_insert_rowid()";
        return (long)cmd.ExecuteScalar()!;
    }

    private static byte[] NewUuidBigEndian()
    {
        // .NET writes Guids in mixed-endian by default (Microsoft format).
        // Force big-endian (RFC 4122) byte order so a hex dump of the bytes
        // matches the canonical UUID string and how Apple's NSUUID serialises
        // — keeps the option open of file-level interop with a Mac install.
        var b = new byte[16];
        Guid.NewGuid().TryWriteBytes(b, bigEndian: true, out _);
        return b;
    }
}

public enum IngestKind
{
    Inserted,
    Bumped,
    Skipped,
}

public readonly record struct IngestOutcome(IngestKind Kind, long EntryId, string? Reason = null);
