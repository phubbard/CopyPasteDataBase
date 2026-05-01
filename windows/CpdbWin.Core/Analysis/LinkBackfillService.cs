using System.Net.NetworkInformation;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Store;

namespace CpdbWin.Core.Analysis;

/// <summary>
/// Drives the link-metadata backfill loop. Pulls the next batch of
/// candidate rows from <see cref="EntryRepository.NextLinkBackfillCandidates"/>,
/// dispatches each through <see cref="LinkMetadataFetcher.FetchAsync"/>,
/// and translates the outcome into <c>SettleLink</c> / <c>BumpLinkRetry</c>
/// repository writes per the Stage A contract.
///
/// <para>
/// Three triggers run a backfill cycle:
/// </para>
/// <list type="number">
/// <item><b>Periodic timer</b> at <see cref="Interval"/> (default 15 min).
///       Catches anything that slipped past the wake hook (offline at
///       capture time, slow network, etc.).</item>
/// <item><b>Capture-wake</b> via <see cref="WakeForCapture"/>: AppHost
///       calls this on every newly-captured kind=link row so the
///       fetcher fires within seconds of the user copying a URL,
///       not minutes.</item>
/// <item><b>Online-edge catch-up</b>: <see cref="NetworkChange.NetworkAvailabilityChanged"/>
///       firing with <c>IsAvailable=true</c> kicks a cycle so the
///       backlog drains as soon as a flaky connection comes back.</item>
/// </list>
///
/// <para>
/// Two safety rails: a <see cref="SemaphoreSlim"/> reentry guard makes
/// concurrent calls a no-op (only one cycle in flight), and an
/// <see cref="IConnectivityProbe"/> short-circuits cycles when the
/// network is offline. The latter avoids burning the row's retry
/// budget on errors that aren't the page's fault.
/// </para>
/// </summary>
public sealed class LinkBackfillService : IDisposable
{
    private readonly EntryRepository _entries;
    private readonly LinkMetadataFetcher _fetcher;
    private readonly IConnectivityProbe _connectivity;
    private readonly SemaphoreSlim _gate = new(1, 1);

    private System.Threading.Timer? _timer;
    private CancellationTokenSource? _cts;
    private NetworkAvailabilityChangedEventHandler? _connHandler;

    /// <summary>
    /// Periodic-cycle interval. 15 minutes matches the macOS default and
    /// keeps the average outstanding-row age reasonable without burning
    /// network on a quiet hour.
    /// </summary>
    public TimeSpan Interval { get; set; } = TimeSpan.FromMinutes(15);

    /// <summary>
    /// Rows pulled per cycle. 5 mirrors the macOS Stage 4 batch size —
    /// big enough to keep up with typical capture rates, small enough
    /// that one timer tick can't pin a worker for minutes.
    /// </summary>
    public int BatchSize { get; set; } = 5;

    /// <summary>Raised after each row is settled (success or
    /// permanent give-up) or its retry counter bumped. Subscribers
    /// drive the live UI refresh in Stage D.</summary>
    public event EventHandler<LinkBackfillSettledEventArgs>? RowSettled;

    /// <summary>Non-fatal errors caught inside the cycle. The cycle
    /// keeps draining whatever it can; this event is for visibility
    /// (log line, telemetry) only.</summary>
    public event EventHandler<Exception>? Errored;

    public LinkBackfillService(
        EntryRepository entries,
        LinkMetadataFetcher fetcher,
        IConnectivityProbe? connectivity = null)
    {
        _entries = entries;
        _fetcher = fetcher;
        _connectivity = connectivity ?? new DefaultConnectivityProbe();
    }

    public void Start()
    {
        if (_timer is not null) throw new InvalidOperationException(
            $"{nameof(LinkBackfillService)} already started");
        _cts = new CancellationTokenSource();
        // Fire once immediately on Start, then every Interval. The first
        // tick catches a backlog that may have accumulated while the app
        // wasn't running.
        _timer = new System.Threading.Timer(
            _ => _ = RunOnceAsync(null, _cts.Token),
            state: null,
            dueTime: TimeSpan.Zero,
            period: Interval);
        // Online-edge catch-up. NetworkChange is .NET's portable hook;
        // it doesn't always fire reliably on every Windows configuration
        // (corporate WANs, locked-down VDIs), but when it does it lets
        // us drain a backlog within seconds of reconnection.
        _connHandler = (_, e) =>
        {
            if (e.IsAvailable) _ = RunOnceAsync(null, _cts.Token);
        };
        NetworkChange.NetworkAvailabilityChanged += _connHandler;
    }

    public void Stop()
    {
        if (_connHandler is not null)
        {
            NetworkChange.NetworkAvailabilityChanged -= _connHandler;
            _connHandler = null;
        }
        _cts?.Cancel();
        _timer?.Dispose();
        _timer = null;
    }

    public void Dispose()
    {
        Stop();
        _cts?.Dispose();
        _gate.Dispose();
    }

    /// <summary>
    /// Run a single backfill cycle: fetch up to <paramref name="overrideBatchSize"/>
    /// (or <see cref="BatchSize"/>) candidates and dispatch each. Returns
    /// when the batch is drained or the cycle is cancelled. Reentrant-
    /// guarded; concurrent calls return immediately without touching the
    /// network.
    /// </summary>
    public async Task RunOnceAsync(int? overrideBatchSize = null, CancellationToken ct = default)
    {
        // TryAcquire — non-blocking. If another cycle holds the gate,
        // skip this one. Wake events (capture-wake, online-edge,
        // periodic timer) all coalesce harmlessly through this guard.
        if (!await _gate.WaitAsync(0, ct).ConfigureAwait(false)) return;
        try
        {
            // Connectivity short-circuit. Fetching while offline would
            // burn each row's retry budget on errors that aren't the
            // page's fault — better to wait for the next tick.
            if (!_connectivity.IsOnline()) return;

            var candidates = _entries.NextLinkBackfillCandidates(
                limit: overrideBatchSize ?? BatchSize);
            foreach (var c in candidates)
            {
                if (ct.IsCancellationRequested) break;
                await DispatchOneAsync(c, ct).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            // Cancellation isn't an error — happens during Stop / Dispose.
        }
        catch (Exception ex)
        {
            // Surface but don't propagate. The timer thread MUST stay
            // alive or every subsequent cycle gets dropped.
            try { Errored?.Invoke(this, ex); } catch { }
        }
        finally
        {
            try { _gate.Release(); } catch (ObjectDisposedException) { /* during Dispose */ }
        }
    }

    /// <summary>
    /// Hint that a fresh kind=link capture just landed — drain a small
    /// batch right now instead of waiting for the next periodic tick.
    /// Safe to call from any thread; coalesces through the reentry gate
    /// so a flurry of pastes doesn't pile up.
    /// </summary>
    public void WakeForCapture()
    {
        var token = _cts?.Token ?? CancellationToken.None;
        _ = RunOnceAsync(null, token);
    }

    private async Task DispatchOneAsync(LinkBackfillCandidate c, CancellationToken ct)
    {
        FetchOutcome outcome;
        try
        {
            outcome = await _fetcher.FetchAsync(c.Url, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            // Defensive — FetchAsync is supposed to swallow exceptions
            // and return Transient/Permanent. If something slips through
            // (e.g. a bug), treat as transient so the row gets retried
            // rather than permanently settled with no title.
            outcome = new FetchOutcome.Transient($"unexpected: {ex.Message}");
        }

        WriteFetchLog(c, outcome);

        switch (outcome)
        {
            case FetchOutcome.Success success:
                _entries.SettleLink(c.Id, success.Title);
                // Attach the og:image / favicon / Wikipedia REST API
                // thumbnail (whichever resolved). Best-effort — failure
                // here doesn't undo the title settle. Done AFTER
                // SettleLink so a later thumbnail crash leaves the row
                // settled rather than stranding it as a candidate forever.
                if (success.ThumbnailUrl is { } thumbUrl)
                {
                    await TryAttachThumbnailAsync(c.Id, thumbUrl, ct).ConfigureAwait(false);
                }
                RaiseSettled(c, success.Title, transient: false);
                break;

            case FetchOutcome.Permanent:
                // Settle with a null title so the row stops appearing as
                // a candidate. The fetched_at sentinel is non-NULL but
                // link_title is NULL — UI renders the URL itself.
                _entries.SettleLink(c.Id, null);
                RaiseSettled(c, null, transient: false);
                break;

            case FetchOutcome.Transient:
                // Bump retry counter + park behind backoff window. The
                // next cycle (or wake) re-evaluates after the gate
                // expires, until link_retry_count hits MaxLinkRetries
                // and the candidate query stops returning the row.
                _entries.BumpLinkRetry(c.Id);
                RaiseSettled(c, null, transient: true);
                break;
        }
    }

    /// <summary>
    /// Download the resolved thumbnail URL, hand the bytes to
    /// <see cref="Thumbnailer"/>, and write the small + large JPEGs into
    /// the <c>previews</c> table for <paramref name="entryId"/>. Best-
    /// effort: 404s, oversized payloads, decoder failures, network blips,
    /// and any other path that doesn't yield bytes get silently skipped.
    /// The link row's title is already settled by the time we get here,
    /// so the worst-case is "no preview thumbnail for this entry."
    /// </summary>
    private async Task TryAttachThumbnailAsync(long entryId, Uri url, CancellationToken ct)
    {
        try
        {
            var bytes = await _fetcher.FetchThumbnailBytesAsync(url, ct).ConfigureAwait(false);
            if (bytes is null || bytes.Length == 0) return;
            var thumbs = Thumbnailer.Generate(bytes);
            if (thumbs.Small is null && thumbs.Large is null) return;
            _entries.UpsertPreview(entryId, thumbs.Small, thumbs.Large);
        }
        catch
        {
            // Best-effort — a thumbnail failure must never tear down the
            // backfill cycle. The Errored event is reserved for the cycle
            // itself; thumbnail-attach errors are quiet.
        }
    }

    /// <summary>
    /// Append a one-line record of each fetch attempt to
    /// <c>%LOCALAPPDATA%\cpdb\link-fetch.log</c>. Diagnostic surface only;
    /// the file rotates by being capped at 1 MB (truncated when oversize).
    /// Best-effort: a failure to log must never escape the backfill loop.
    /// </summary>
    private static void WriteFetchLog(LinkBackfillCandidate c, FetchOutcome outcome)
    {
        try
        {
            var path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "cpdb", "link-fetch.log");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);

            // Cheap rotation: truncate when the file passes 1 MB. Replaces
            // the need for a real rolling logger and keeps the file readable
            // by `Get-Content -Tail` without filling the disk.
            if (File.Exists(path) && new FileInfo(path).Length > 1_000_000)
            {
                File.WriteAllText(path, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] (rotated)\n");
            }

            string line = outcome switch
            {
                FetchOutcome.Success { Title: { } t, ThumbnailUrl: var u, Source: var s } =>
                    $"OK [{s}] {c.Url} → \"{Trunc(t, 80)}\"" + (u is null ? "" : $" thumb={u}"),
                FetchOutcome.Success { Title: null, ThumbnailUrl: var u, Source: var s } =>
                    $"OK-EMPTY [{s}] {c.Url} (200 but no title found)" + (u is null ? "" : $" thumb={u}"),
                FetchOutcome.Permanent p =>
                    $"PERMANENT {c.Url} — {p.Reason}",
                FetchOutcome.Transient t =>
                    $"TRANSIENT {c.Url} — {t.Reason} (retry #{c.RetryCount + 1})",
                _ => $"UNKNOWN-OUTCOME {c.Url}",
            };

            File.AppendAllText(path,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {line}\n");
        }
        catch
        {
            // Logging is never critical-path.
        }
    }

    private static string Trunc(string s, int max) =>
        s.Length <= max ? s : s.Substring(0, max) + "…";

    private void RaiseSettled(LinkBackfillCandidate c, string? title, bool transient)
    {
        try
        {
            RowSettled?.Invoke(this, new LinkBackfillSettledEventArgs(c.Id, title, transient));
        }
        catch
        {
            // UI subscribers MUST NOT take down the worker thread.
        }
    }
}

/// <summary>
/// Hook for connectivity probing. The default implementation uses
/// <see cref="NetworkInterface.GetIsNetworkAvailable"/> — coarse but
/// portable. App-layer callers can swap in a richer probe (Windows.Networking
/// .Connectivity.NetworkInformation) if desired; tests inject a fake.
/// </summary>
public interface IConnectivityProbe
{
    bool IsOnline();
}

/// <summary>
/// .NET-portable probe: asks the OS whether any non-loopback interface
/// has an active link. Doesn't probe an actual server, so DNS / captive-
/// portal failures still slip through — they end up as Transient
/// outcomes that backoff appropriately.
/// </summary>
public sealed class DefaultConnectivityProbe : IConnectivityProbe
{
    public bool IsOnline() => NetworkInterface.GetIsNetworkAvailable();
}

public sealed class LinkBackfillSettledEventArgs : EventArgs
{
    public long EntryId { get; }
    /// <summary>Fetched title, null on permanent give-up or transient
    /// failure (caller distinguishes via <see cref="Transient"/>).</summary>
    public string? Title { get; }
    /// <summary>True when this was a transient failure (BumpLinkRetry);
    /// false on success or permanent give-up (SettleLink).</summary>
    public bool Transient { get; }

    public LinkBackfillSettledEventArgs(long entryId, string? title, bool transient)
    {
        EntryId = entryId;
        Title = title;
        Transient = transient;
    }
}
