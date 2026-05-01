using CpdbWin.Core.Analysis;
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
    public LinkMetadataFetcher LinkFetcher { get; }
    public LinkBackfillService LinkBackfill { get; }
    public AppPaths.Resolved Paths { get; }

    private AppHost(
        AppPaths.Resolved paths,
        SqliteConnection db,
        BlobStore blobs,
        Ingestor ingestor,
        EntryRepository entries,
        CaptureService capture,
        LinkMetadataFetcher linkFetcher,
        LinkBackfillService linkBackfill)
    {
        Paths = paths;
        Database = db;
        Blobs = blobs;
        Ingestor = ingestor;
        Entries = entries;
        Capture = capture;
        LinkFetcher = linkFetcher;
        LinkBackfill = linkBackfill;
    }

    public static AppHost Bootstrap(string? rootOverride = null)
    {
        var paths = AppPaths.Initialize(rootOverride);

        var db = DbHelper.Open(paths.Database);
        // Single entry point — fresh DB → Schema.Initialize; existing DB
        // (e.g. v1.0 / v1.1 install at schema v5) → Migrator.Migrate runs
        // any pending v6/v7/v8/v9 ALTER TABLEs and FTS5 rebuild. Idempotent
        // and fast on already-current DBs.
        Migrator.EnsureSchema(db);

        var blobs = new BlobStore(paths.Blobs);

        // Cheap startup sweep: caps the live entry count, hard-deletes
        // 30-day-old tombstones, and removes blob files nothing references.
        new Gc(db, blobs).Run();

        var ingestor = new Ingestor(db, blobs);
        var entries = new EntryRepository(db, blobs);
        var capture = new CaptureService(ingestor);

        var linkFetcher = new LinkMetadataFetcher();
        var linkBackfill = new LinkBackfillService(entries, linkFetcher);
        // Capture-wake: every kind=link insert (or bump) kicks an
        // immediate fetch cycle so a freshly-copied URL gets its title
        // within a few seconds rather than waiting on the periodic
        // timer. Reentry-guarded inside WakeForCapture, so a flurry of
        // pastes coalesces.
        capture.Ingested += (_, outcome) =>
        {
            if (outcome.EntryKind == "link" &&
                (outcome.Kind == IngestKind.Inserted || outcome.Kind == IngestKind.Bumped))
            {
                linkBackfill.WakeForCapture();
            }
        };
        capture.Start();
        linkBackfill.Start();

        return new AppHost(paths, db, blobs, ingestor, entries, capture, linkFetcher, linkBackfill);
    }

    public void Dispose()
    {
        LinkBackfill.Dispose();
        LinkFetcher.Dispose();
        Capture.Dispose();
        Database.Dispose();
    }
}
