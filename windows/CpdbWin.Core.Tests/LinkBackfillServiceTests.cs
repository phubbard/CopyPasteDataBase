using System.Net;
using System.Text;
using CpdbWin.Core.Analysis;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.Data.Sqlite;
using Xunit;

namespace CpdbWin.Core.Tests;

public class LinkBackfillServiceTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingestor;
    private readonly EntryRepository _repo;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public LinkBackfillServiceTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-backfill-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
        _ingestor = new Ingestor(_db, _blobs);
        _repo = new EntryRepository(_db, _blobs);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    private long IngestLink(string url, DateTimeOffset at) =>
        _ingestor.Ingest(
            new ClipboardSnapshot(new[]
            {
                new CanonicalHash.Flavor("public.url", Encoding.UTF8.GetBytes(url)),
                new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes(url)),
            }),
            null,
            _device,
            at).EntryId;

    /// <summary>Connectivity probe stub. Bool flag toggles online/offline.</summary>
    private sealed class FakeProbe : IConnectivityProbe
    {
        public bool Online { get; set; } = true;
        public bool IsOnline() => Online;
    }

    /// <summary>HttpMessageHandler stub — same shape as
    /// <see cref="LinkMetadataFetcherTests.FakeHandler"/>, plus an
    /// optional async OnSend variant for tests that need a controllable
    /// stall (e.g. the reentry-guard test).</summary>
    private sealed class FakeHandler : HttpMessageHandler
    {
        public Func<HttpRequestMessage, HttpResponseMessage> OnSend { get; set; } =
            _ => new HttpResponseMessage(HttpStatusCode.NotFound);

        /// <summary>If non-null, takes precedence over <see cref="OnSend"/>
        /// and lets a test return a delayed/async response without
        /// blocking the calling thread.</summary>
        public Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>>? OnSendAsync { get; set; }

        private int _count;
        public int RequestCount => Volatile.Read(ref _count);

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref _count);
            if (OnSendAsync is { } asyncSend) return asyncSend(request, cancellationToken);
            try { return Task.FromResult(OnSend(request)); }
            catch (Exception ex) { return Task.FromException<HttpResponseMessage>(ex); }
        }
    }

    private static HttpResponseMessage Html(string html) =>
        new(HttpStatusCode.OK)
        {
            Content = new StringContent(html, Encoding.UTF8, "text/html"),
        };

    // ─── Dispatch ─────────────────────────────────────────────────────────

    [Fact]
    public async Task RunOnceAsync_Success_SettlesWithFetchedTitle()
    {
        var id = IngestLink("https://success.example/", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var handler = new FakeHandler
        {
            OnSend = _ => Html("<html><head><title>Hello</title></head></html>")
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        using var svc = new LinkBackfillService(_repo, fetcher, new FakeProbe());

        await svc.RunOnceAsync();

        var row = _repo.Recent().Single(r => r.Id == id);
        Assert.Equal("Hello", row.LinkTitle);
        Assert.Empty(_repo.NextLinkBackfillCandidates(10));
    }

    [Fact]
    public async Task RunOnceAsync_Permanent_SettlesWithNullTitle()
    {
        var id = IngestLink("https://gone.example/", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var handler = new FakeHandler
        {
            OnSend = _ => new HttpResponseMessage(HttpStatusCode.NotFound)
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        using var svc = new LinkBackfillService(_repo, fetcher, new FakeProbe());

        await svc.RunOnceAsync();

        var row = _repo.Recent().Single(r => r.Id == id);
        Assert.Null(row.LinkTitle);
        // 404 is permanent — row stops being a candidate.
        Assert.Empty(_repo.NextLinkBackfillCandidates(10));
    }

    [Fact]
    public async Task RunOnceAsync_Transient_BumpsRetryAndKeepsRowAsCandidate()
    {
        var id = IngestLink("https://flaky.example/", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var handler = new FakeHandler
        {
            OnSend = _ => new HttpResponseMessage((HttpStatusCode)429)
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        using var svc = new LinkBackfillService(_repo, fetcher, new FakeProbe());

        await svc.RunOnceAsync();

        // BumpLinkRetry uses real-clock UtcNow internally, so we can't
        // assert candidate visibility against a synthetic now without
        // overriding the clock. Instead, inspect the row state directly:
        // link_fetched_at still NULL (not settled), link_retry_count = 1,
        // link_retry_after non-null (parked behind the backoff window).
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            SELECT link_fetched_at, link_retry_count, link_retry_after
            FROM entries WHERE id=$id
            """;
        cmd.Parameters.AddWithValue("$id", id);
        using var reader = cmd.ExecuteReader();
        Assert.True(reader.Read());
        Assert.True(reader.IsDBNull(0), "link_fetched_at should still be NULL after a transient failure");
        Assert.Equal(1, (int)reader.GetInt64(1));
        Assert.False(reader.IsDBNull(2), "link_retry_after should be parked");
    }

    // ─── Connectivity gate ───────────────────────────────────────────────

    [Fact]
    public async Task RunOnceAsync_Offline_NoFetch_NoStateChange()
    {
        IngestLink("https://example.com/x", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var handler = new FakeHandler();   // would return 404 if hit
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        var probe = new FakeProbe { Online = false };
        using var svc = new LinkBackfillService(_repo, fetcher, probe);

        await svc.RunOnceAsync();

        // No HTTP request issued — the candidate query short-circuited
        // before the fetcher ran.
        Assert.Equal(0, handler.RequestCount);
        // Row still pending; nothing got bumped.
        Assert.Single(_repo.NextLinkBackfillCandidates(10));
    }

    // ─── Reentry guard ───────────────────────────────────────────────────

    [Fact]
    public async Task RunOnceAsync_Reentrant_SecondCallSkipsWhileFirstHoldsGate()
    {
        IngestLink("https://slow.example/", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));

        // Async stall: SendAsync awaits a TCS so it yields back to the
        // caller (instead of blocking the thread synchronously). The
        // first RunOnceAsync therefore parks holding the gate, the
        // second observes the held gate, then we release the stall.
        var release = new TaskCompletionSource<HttpResponseMessage>();
        var handler = new FakeHandler
        {
            OnSendAsync = async (req, ct) =>
            {
                using (ct.Register(() => release.TrySetCanceled())) { }
                return await release.Task.ConfigureAwait(false);
            }
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        using var svc = new LinkBackfillService(_repo, fetcher, new FakeProbe());

        var first = svc.RunOnceAsync();
        // First call must reach the SendAsync stall before we issue the
        // second; once RequestCount hits 1 we know the gate is held.
        for (int i = 0; i < 200 && handler.RequestCount == 0; i++)
            await Task.Delay(5);
        Assert.Equal(1, handler.RequestCount);

        // Second call — should observe the gate held and return without
        // issuing another request.
        await svc.RunOnceAsync();
        Assert.Equal(1, handler.RequestCount);

        // Drain the first.
        release.SetResult(Html("<title>Slow</title>"));
        await first;
    }

    // ─── Batch sizing ────────────────────────────────────────────────────

    [Fact]
    public async Task RunOnceAsync_DrainsUpToBatchSizeRows()
    {
        // Insert 10 links, set BatchSize to 3, expect 3 settled rows.
        // Each cycle fires N HTTP requests per row: 1 for the page, plus
        // up to one for the resolved thumbnail URL (the favicon fallback
        // always resolves something on a successful 200, so handler hits
        // = batch × 2). Assert on the row count rather than handler hits
        // so the test stays robust to thumbnail-pipeline tweaks.
        for (int i = 0; i < 10; i++)
            IngestLink($"https://example.com/p{i}", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000 + i));

        var handler = new FakeHandler
        {
            OnSend = _ => Html("<title>page</title>")
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        using var svc = new LinkBackfillService(_repo, fetcher, new FakeProbe()) { BatchSize = 3 };

        await svc.RunOnceAsync();

        // 7 still pending (10 ingested - 3 settled this cycle).
        Assert.Equal(7, _repo.NextLinkBackfillCandidates(20).Count);
    }

    [Fact]
    public async Task RunOnceAsync_OverrideBatchSize_Wins()
    {
        for (int i = 0; i < 10; i++)
            IngestLink($"https://example.com/p{i}", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000 + i));

        var handler = new FakeHandler
        {
            OnSend = _ => Html("<title>page</title>")
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        using var svc = new LinkBackfillService(_repo, fetcher, new FakeProbe()) { BatchSize = 3 };

        await svc.RunOnceAsync(overrideBatchSize: 7);

        // 3 still pending: 10 - 7 settled by this cycle.
        Assert.Equal(3, _repo.NextLinkBackfillCandidates(20).Count);
    }

    // ─── Event surface ───────────────────────────────────────────────────

    [Fact]
    public async Task RowSettled_FiresOnSuccessWithTitle()
    {
        var id = IngestLink("https://example.com/y", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var handler = new FakeHandler
        {
            OnSend = _ => Html("<title>EventTitle</title>")
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        using var svc = new LinkBackfillService(_repo, fetcher, new FakeProbe());

        var settled = new List<LinkBackfillSettledEventArgs>();
        svc.RowSettled += (_, e) => settled.Add(e);

        await svc.RunOnceAsync();

        var ev = Assert.Single(settled);
        Assert.Equal(id, ev.EntryId);
        Assert.Equal("EventTitle", ev.Title);
        Assert.False(ev.Transient);
    }

    [Fact]
    public async Task RowSettled_FiresOnTransient_WithTransientFlag()
    {
        var id = IngestLink("https://example.com/z", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var handler = new FakeHandler
        {
            OnSend = _ => new HttpResponseMessage(HttpStatusCode.InternalServerError)
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        using var svc = new LinkBackfillService(_repo, fetcher, new FakeProbe());

        var settled = new List<LinkBackfillSettledEventArgs>();
        svc.RowSettled += (_, e) => settled.Add(e);

        await svc.RunOnceAsync();

        var ev = Assert.Single(settled);
        Assert.Equal(id, ev.EntryId);
        Assert.Null(ev.Title);
        Assert.True(ev.Transient);
    }

    // ─── End-to-end candidate progression ───────────────────────────────

    // ─── Stage D — thumbnail attach ──────────────────────────────────────

    [Fact]
    public async Task RunOnceAsync_FetchesThumbnailWhenSuccessHasUrl()
    {
        // Confirms the dispatch wiring: a successful HTML fetch with an
        // og:image surfaces a thumbnail URL, which the service then GETs
        // via FetchThumbnailBytesAsync. We assert by counting handler hits
        // — page + thumbnail = 2 requests.
        IngestLink("https://withthumb.example/", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));

        var hits = new List<Uri>();
        var handler = new FakeHandler
        {
            OnSend = req =>
            {
                hits.Add(req.RequestUri!);
                if (req.RequestUri!.AbsoluteUri == "https://withthumb.example/")
                {
                    return Html("""
                        <html><head>
                          <meta property="og:title"  content="Page Title">
                          <meta property="og:image"  content="https://cdn.example/og.jpg">
                        </head></html>
                        """);
                }
                if (req.RequestUri!.AbsoluteUri == "https://cdn.example/og.jpg")
                {
                    // Non-image bytes — Thumbnailer will refuse to decode.
                    // Test passes regardless; we're asserting the GET fired.
                    var resp = new HttpResponseMessage(HttpStatusCode.OK)
                    {
                        Content = new ByteArrayContent(new byte[] { 0xFF }),
                    };
                    resp.Content.Headers.ContentType =
                        new System.Net.Http.Headers.MediaTypeHeaderValue("image/jpeg");
                    return resp;
                }
                return new HttpResponseMessage(HttpStatusCode.NotFound);
            }
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        using var svc = new LinkBackfillService(_repo, fetcher, new FakeProbe());

        await svc.RunOnceAsync();

        Assert.Contains(hits, u => u.AbsoluteUri == "https://withthumb.example/");
        Assert.Contains(hits, u => u.AbsoluteUri == "https://cdn.example/og.jpg");
    }

    [Fact]
    public async Task RunOnceAsync_NonImageThumbnailBytes_NoPreviewWritten()
    {
        // Thumbnailer rejects garbage bytes; UpsertPreview must NOT be
        // called in that case. The link row still settles with its title.
        var id = IngestLink("https://garbage.example/", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var handler = new FakeHandler
        {
            OnSend = req =>
            {
                if (req.RequestUri!.AbsoluteUri.StartsWith("https://garbage.example/", StringComparison.Ordinal))
                {
                    return Html("""
                        <html><head>
                          <title>Garbage Page</title>
                          <meta property="og:image" content="https://cdn.example/garbage.png">
                        </head></html>
                        """);
                }
                if (req.RequestUri!.AbsoluteUri == "https://cdn.example/garbage.png")
                {
                    var resp = new HttpResponseMessage(HttpStatusCode.OK)
                    {
                        Content = new ByteArrayContent(new byte[] { 0x00, 0x01, 0x02, 0x03 }),
                    };
                    resp.Content.Headers.ContentType =
                        new System.Net.Http.Headers.MediaTypeHeaderValue("image/png");
                    return resp;
                }
                return new HttpResponseMessage(HttpStatusCode.NotFound);
            }
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        using var svc = new LinkBackfillService(_repo, fetcher, new FakeProbe());

        await svc.RunOnceAsync();

        Assert.Equal("Garbage Page", _repo.Recent().Single(r => r.Id == id).LinkTitle);
        Assert.Null(_repo.GetThumbLarge(id));
    }

    [Fact]
    public async Task RunOnceAsync_NoThumbnailUrl_NoFetchAttempt()
    {
        // Page has og:title but no og:image / favicon should still
        // resolve (favicon-default fallback always returns a URL). To
        // simulate the no-thumbnail case at the service layer, point the
        // candidate at a non-http URL (won't pass TryNormalize), but
        // that path is Permanent so check a different angle: confirm
        // that on a Permanent outcome, no thumbnail GET fires.
        IngestLink("https://nothumb.example/", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        int requestCount = 0;
        var handler = new FakeHandler
        {
            OnSend = _ =>
            {
                requestCount++;
                return new HttpResponseMessage(HttpStatusCode.NotFound);
            }
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        using var svc = new LinkBackfillService(_repo, fetcher, new FakeProbe());

        await svc.RunOnceAsync();

        // 404 → Permanent → SettleLink(null). Exactly one request, no
        // thumbnail GET attempted.
        Assert.Equal(1, requestCount);
    }

    [Fact]
    public async Task RunOnceAsync_DrainsToEmpty_WhenAllCandidatesFetchSuccessfully()
    {
        for (int i = 0; i < 5; i++)
            IngestLink($"https://example.com/q{i}", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000 + i));

        var handler = new FakeHandler
        {
            OnSend = req => Html($"<title>page-{req.RequestUri!.AbsolutePath}</title>")
        };
        using var fetcher = new LinkMetadataFetcher(new HttpClient(handler), ownsClient: true);
        using var svc = new LinkBackfillService(_repo, fetcher, new FakeProbe()) { BatchSize = 5 };

        await svc.RunOnceAsync();

        Assert.Empty(_repo.NextLinkBackfillCandidates(20));
        // Each row got its title.
        var titles = _repo.Recent().Select(r => r.LinkTitle).ToList();
        Assert.All(titles, t => Assert.NotNull(t));
    }
}

// ─── IngestOutcome.EntryKind plumbing ───────────────────────────────────

public class IngestOutcomeEntryKindTests : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly BlobStore _blobs;
    private readonly string _blobRoot;
    private readonly Ingestor _ingestor;
    private readonly DeviceIdentity.Info _device =
        new("test-machine-guid", "TestPC", "win");

    public IngestOutcomeEntryKindTests()
    {
        _db = new SqliteConnection("Data Source=:memory:");
        _db.Open();
        Schema.Initialize(_db);
        _blobRoot = Path.Combine(Path.GetTempPath(),
            "cpdb-ingest-kind-tests-" + Guid.NewGuid().ToString("N"));
        _blobs = new BlobStore(_blobRoot);
        _ingestor = new Ingestor(_db, _blobs);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_blobRoot, recursive: true); } catch { }
    }

    [Fact]
    public void Ingest_LinkSnapshot_OutcomeReportsLinkKind()
    {
        var snap = new ClipboardSnapshot(new[]
        {
            new CanonicalHash.Flavor("public.url", Encoding.UTF8.GetBytes("https://example.com")),
            new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes("https://example.com")),
        });
        var outcome = _ingestor.Ingest(snap, null, _device);
        Assert.Equal(IngestKind.Inserted, outcome.Kind);
        Assert.Equal("link", outcome.EntryKind);
    }

    [Fact]
    public void Ingest_TextSnapshot_OutcomeReportsTextKind()
    {
        var snap = new ClipboardSnapshot(new[]
        {
            new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes("hello world")),
        });
        var outcome = _ingestor.Ingest(snap, null, _device);
        Assert.Equal("text", outcome.EntryKind);
    }

    [Fact]
    public void Ingest_BumpedRow_OutcomeReportsExistingKind()
    {
        // First insert as link.
        var snap = new ClipboardSnapshot(new[]
        {
            new CanonicalHash.Flavor("public.url", Encoding.UTF8.GetBytes("https://dup.example")),
            new CanonicalHash.Flavor("public.utf8-plain-text", Encoding.UTF8.GetBytes("https://dup.example")),
        });
        var first = _ingestor.Ingest(snap, null, _device);
        Assert.Equal(IngestKind.Inserted, first.Kind);

        // Second ingest of the same content — Bumped, should still report link.
        var second = _ingestor.Ingest(snap, null, _device);
        Assert.Equal(IngestKind.Bumped, second.Kind);
        Assert.Equal("link", second.EntryKind);
    }
}
