using CpdbWin.Core.Store;

namespace CpdbWin.Core.Analysis;

/// <summary>
/// Background embedding pass for text + link entries — the Windows
/// analogue of macOS <c>EmbeddingSweeper</c>. Same shape as
/// <see cref="LinkBackfillService"/> and <see cref="ImageAnalysisService"/>:
/// a periodic timer plus a capture-wake hook, coalesced by a reentry gate,
/// with an event so the UI (and later semantic-search index) can react
/// as rows settle.
///
/// <para>
/// Idempotence + resumability come from <c>EntryRepository.EntriesNeedingEmbedding</c>
/// which filters on model_id/revision — a bump of either
/// <see cref="EmbeddingService.ModelId"/> or <see cref="EmbeddingService.Revision"/>
/// automatically re-sweeps every row. Skip when the model bundle isn't
/// available at all (<see cref="EmbeddingService.IsAvailable"/> is
/// sticky-false), same fail-soft posture the classifier uses.
/// </para>
/// </summary>
public sealed class EmbeddingSweeper : IDisposable
{
    private readonly EntryRepository _entries;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private System.Threading.Timer? _timer;
    private CancellationTokenSource? _cts;

    /// <summary>Periodic sweep cadence. First tick fires on
    /// <see cref="Start"/> to drain what accumulated while the app
    /// wasn't running.</summary>
    public TimeSpan Interval { get; set; } = TimeSpan.FromMinutes(5);

    /// <summary>Entries per cycle. Larger than image-OCR (Mac uses 15
    /// for interactive, 200 for backlog drain); MiniLM INT8 clocks at
    /// ~18 ms/entry on Apple Silicon → a 15-entry batch fits in a few
    /// hundred ms, which is fine off the UI thread.</summary>
    public int BatchSize { get; set; } = 15;

    /// <summary>Raised after a row is settled so the UI + semantic
    /// index can re-query.</summary>
    public event EventHandler<EmbeddedEventArgs>? RowSettled;

    /// <summary>Cycle-level failures (never per-row — those log and
    /// continue). For visibility only; the loop keeps going.</summary>
    public event EventHandler<Exception>? Errored;

    public EmbeddingSweeper(EntryRepository entries) => _entries = entries;

    public void Start()
    {
        if (_timer is not null) throw new InvalidOperationException(
            $"{nameof(EmbeddingSweeper)} already started");
        _cts = new CancellationTokenSource();
        _timer = new System.Threading.Timer(
            _ => _ = RunOnceAsync(null, _cts.Token),
            state: null,
            dueTime: TimeSpan.Zero,
            period: Interval);
    }

    public void Stop()
    {
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
    /// One sweep: embed up to <paramref name="overrideBatchSize"/> (or
    /// <see cref="BatchSize"/>) candidate rows. Reentrant-guarded so
    /// capture-wake and the periodic timer coalesce. Returns the number
    /// of rows settled (handy for the CLI's drain loop). Bails
    /// immediately if the model bundle isn't available.
    /// </summary>
    public async Task<int> RunOnceAsync(int? overrideBatchSize = null, CancellationToken ct = default)
    {
        if (!EmbeddingService.IsAvailable) return 0;
        if (!await _gate.WaitAsync(0, ct).ConfigureAwait(false)) return 0;
        try
        {
            var limit = overrideBatchSize ?? BatchSize;
            if (limit <= 0) return 0;

            var ids = _entries.EntriesNeedingEmbedding(
                EmbeddingService.ModelId, EmbeddingService.Revision, limit);
            if (ids.Count == 0) return 0;

            int settled = 0;
            foreach (var id in ids)
            {
                if (ct.IsCancellationRequested) break;
                try
                {
                    var text = _entries.GetEmbeddableText(id);
                    if (string.IsNullOrWhiteSpace(text)) continue;

                    // EmbeddingService.Compute serialises via the shared
                    // semaphore; run on a worker so the sweeper timer
                    // doesn't pin whatever thread it's on.
                    var vector = await Task.Run(() => EmbeddingService.Compute(text), ct).ConfigureAwait(false);
                    if (vector is null) continue;

                    var bytes = EmbeddingService.SerializeLittleEndian(vector);
                    _entries.SaveEmbedding(
                        entryId:  id,
                        modelId:  EmbeddingService.ModelId,
                        revision: EmbeddingService.Revision,
                        dims:     EmbeddingService.Dimensions,
                        vector:   bytes);
                    settled++;
                    RowSettled?.Invoke(this, new EmbeddedEventArgs(id));
                }
                catch (OperationCanceledException) { throw; }
                catch (Exception)
                {
                    // Never let one bad row abort the batch. A
                    // deterministically-failing entry will re-appear as
                    // a candidate next cycle; if it keeps failing we
                    // can add a retry cap later (mirroring
                    // v13_ai_enrichment_retry_cap on Mac). For now the
                    // sweeper stays log-and-continue.
                }
            }
            return settled;
        }
        catch (OperationCanceledException) { return 0; }
        catch (Exception ex)
        {
            Errored?.Invoke(this, ex);
            return 0;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// Kick a single sweep, fire-and-forget. Called from the capture
    /// pipeline after a text/link insert so a freshly-pasted clip
    /// becomes semantically searchable within a couple seconds instead
    /// of waiting on the periodic timer. Reentry-guarded via the same
    /// <see cref="_gate"/>, so a flurry of pastes coalesces into one
    /// batch.
    /// </summary>
    public void WakeForCapture()
    {
        var token = _cts?.Token ?? CancellationToken.None;
        _ = RunOnceAsync(null, token);
    }

    /// <summary>Drain everything in the queue, batched, capped by
    /// <paramref name="timeBudget"/>. Used by the CLI's
    /// <c>analyze-text</c>/<c>embed-backlog</c> command and by the
    /// first-boot warmup after v1.40's schema landed on a library
    /// that's never been embedded. Mirrors macOS
    /// <c>drainBacklog(batchLimit:timeBudget:)</c>.</summary>
    public async Task<int> DrainBacklogAsync(int batchLimit = 200, TimeSpan? timeBudget = null, CancellationToken ct = default)
    {
        var budget = timeBudget ?? TimeSpan.FromSeconds(30);
        var deadline = DateTimeOffset.UtcNow + budget;
        int total = 0;
        while (!ct.IsCancellationRequested && DateTimeOffset.UtcNow < deadline)
        {
            var settled = await RunOnceAsync(batchLimit, ct).ConfigureAwait(false);
            total += settled;
            if (settled == 0) break;  // queue empty
        }
        return total;
    }
}

public sealed class EmbeddedEventArgs : EventArgs
{
    public long EntryId { get; }
    public EmbeddedEventArgs(long entryId) => EntryId = entryId;
}
