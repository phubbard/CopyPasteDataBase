using CpdbWin.Core.Ingest;
using CpdbWin.Core.Service;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;

// Alias the helper class so it doesn't collide with the property of the
// same name on AppHost.
using DbHelper = CpdbWin.Core.Store.Database;

namespace CpdbWin.App;

/// <summary>
/// Composition root. Resolves <c>%LOCALAPPDATA%\cpdb\</c>, opens the
/// SQLite connection, applies the schema if missing, builds the
/// blob store / ingestor / repository, and starts the capture loop.
/// </summary>
public sealed class AppHost : IDisposable
{
    public SqliteConnection Database { get; }
    public BlobStore Blobs { get; }
    public Ingestor Ingestor { get; }
    public EntryRepository Entries { get; }
    public CaptureService Capture { get; }
    public AppPaths.Resolved Paths { get; }

    private AppHost(
        AppPaths.Resolved paths,
        SqliteConnection db,
        BlobStore blobs,
        Ingestor ingestor,
        EntryRepository entries,
        CaptureService capture)
    {
        Paths = paths;
        Database = db;
        Blobs = blobs;
        Ingestor = ingestor;
        Entries = entries;
        Capture = capture;
    }

    public static AppHost Bootstrap(string? rootOverride = null)
    {
        var paths = AppPaths.Initialize(rootOverride);

        var db = DbHelper.Open(paths.Database);
        if (!DbHelper.IsInitialized(db)) Schema.Initialize(db);

        var blobs = new BlobStore(paths.Blobs);

        // Cheap startup sweep: caps the live entry count, hard-deletes
        // 30-day-old tombstones, and removes blob files nothing references.
        new Gc(db, blobs).Run();

        var ingestor = new Ingestor(db, blobs);
        var entries = new EntryRepository(db, blobs);
        var capture = new CaptureService(ingestor);
        capture.Start();

        return new AppHost(paths, db, blobs, ingestor, entries, capture);
    }

    public void Dispose()
    {
        Capture.Dispose();
        Database.Dispose();
    }
}
