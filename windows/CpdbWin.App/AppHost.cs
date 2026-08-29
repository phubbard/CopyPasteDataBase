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
    public ImageAnalysisService ImageAnalysis { get; }
    public EmbeddingSweeper Embeddings { get; }
    public EmbeddingIndex EmbeddingIndex { get; }
    public ChipBackfillService Chips { get; }
    public AppPaths.Resolved Paths { get; }

    /// <summary>
    /// True when this boot tripped the empty-DB circuit breaker (the
    /// previous clean run had live entries, this one has none). When set,
    /// Gc was skipped and capture was <b>not</b> started — the DB is
    /// frozen for forensics and a <c>DATA-LOSS-WARNING.txt</c> was
    /// written. The UI layer surfaces this to the user.
    /// </summary>
    public bool SuspectedDataLoss { get; }

    private AppHost(
        AppPaths.Resolved paths,
        SqliteConnection db,
        BlobStore blobs,
        Ingestor ingestor,
        EntryRepository entries,
        CaptureService capture,
        LinkMetadataFetcher linkFetcher,
        LinkBackfillService linkBackfill,
        ImageAnalysisService imageAnalysis,
        EmbeddingSweeper embeddings,
        EmbeddingIndex embeddingIndex,
        ChipBackfillService chips,
        bool suspectedDataLoss)
    {
        Paths = paths;
        Database = db;
        Blobs = blobs;
        Ingestor = ingestor;
        Entries = entries;
        Capture = capture;
        LinkFetcher = linkFetcher;
        LinkBackfill = linkBackfill;
        ImageAnalysis = imageAnalysis;
        Embeddings = embeddings;
        EmbeddingIndex = embeddingIndex;
        Chips = chips;
        SuspectedDataLoss = suspectedDataLoss;
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

        // Empty-DB circuit breaker. Compare this boot's live-entry count
        // against the count the last clean run recorded. A non-empty →
        // empty transition is treated as suspected data loss: skip Gc
        // (never compound a loss with a destructive sweep), don't start
        // capture (freeze the DB for inspection), and write a loud
        // DATA-LOSS-WARNING.txt. One-shot: the marker is rewritten below
        // so a deliberate "clear history" doesn't lock the app forever.
        var liveBefore = BootDiagnostics.LiveEntryCount(db);
        var marker = BootDiagnostics.ReadEntryMarker(paths.Root);
        var suspectedDataLoss = BootDiagnostics.IsSuspectedDataLoss(marker, liveBefore);

        if (suspectedDataLoss)
        {
            BootDiagnostics.Log(paths.Root,
                $"SUSPECTED DATA LOSS: previous marker={marker} liveNow={liveBefore} "
              + "— Gc SKIPPED, capture WILL NOT START");
            BootDiagnostics.WriteDataLossWarning(paths.Root, marker!.Value);
        }
        else
        {
            // Cheap startup sweep: caps the live entry count, hard-deletes
            // 30-day-old tombstones, removes unreferenced blob files. The
            // returned Stats used to be discarded — now audited to gc.log
            // so a destructive sweep is never silent again.
            var stats = new Gc(db, blobs).Run();
            var liveAfter = BootDiagnostics.LiveEntryCount(db);
            BootDiagnostics.LogGc(paths.Root, stats, liveBefore, liveAfter);
        }

        // Record the post-boot live count as the new baseline. After a
        // suspected loss this rewrites the marker to the (zero) current
        // count so the guard is one-shot — the next launch starts clean.
        BootDiagnostics.WriteEntryMarker(paths.Root, BootDiagnostics.LiveEntryCount(db));

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
        var imageAnalysis = new ImageAnalysisService(entries);
        var embeddings    = new EmbeddingSweeper(entries);
        var embeddingIndex = new EmbeddingIndex(entries);
        var chips = new ChipBackfillService(entries);
        // Sweep-settle invalidates the search-time vector cache so the
        // next hybrid query sees the freshly-embedded row. Cheap: just
        // bumps a generation counter; the cache reloads lazily on the
        // next SearchAsync call.
        embeddings.RowSettled += (_, _) => embeddingIndex.Invalidate();
        capture.Ingested += (_, outcome) =>
        {
            if (outcome.Kind is not (IngestKind.Inserted or IngestKind.Bumped))
                return;
            // Capture-wake: a fresh URL gets its title, a fresh
            // screenshot gets OCR'd, a fresh text/link gets embedded,
            // and a fresh text/link gets scanned for action chips —
            // all within a couple seconds instead of waiting on the
            // periodic timer. All are reentry-guarded.
            if (outcome.EntryKind == "link")  linkBackfill.WakeForCapture();
            if (outcome.EntryKind == "image") imageAnalysis.WakeForCapture();
            if (outcome.EntryKind == "text" || outcome.EntryKind == "link")
            {
                embeddings.WakeForCapture();
                chips.WakeForCapture();
            }
        };
        // The guard: refuse to start capture (or the backfill loops) when
        // we suspect data loss, so the frozen DB is preserved exactly as
        // found until the user has a chance to restore a backup.
        if (!suspectedDataLoss)
        {
            capture.Start();
            linkBackfill.Start();
            imageAnalysis.Start();
            embeddings.Start();
            chips.Start();
        }

        return new AppHost(paths, db, blobs, ingestor, entries, capture,
            linkFetcher, linkBackfill, imageAnalysis, embeddings, embeddingIndex, chips, suspectedDataLoss);
    }

    public void Dispose()
    {
        Chips.Dispose();
        Embeddings.Dispose();
        ImageAnalysis.Dispose();
        LinkBackfill.Dispose();
        LinkFetcher.Dispose();
        Capture.Dispose();
        Database.Dispose();
    }
}
