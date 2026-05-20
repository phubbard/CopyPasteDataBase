using CpdbWin.Core.Store;

namespace CpdbWin.Core.Analysis;

/// <summary>
/// Background OCR pass for image entries — the Windows analogue of the
/// macOS Vision analysis loop. Mirrors <see cref="LinkBackfillService"/>'s
/// shape (periodic timer + capture-wake + reentry gate + a settled
/// event) but is simpler: OCR is local, deterministic and one-shot, so
/// there is no connectivity gate and no retry/backoff. Every processed
/// row gets <c>analyzed_at</c> stamped exactly once via
/// <see cref="EntryRepository.SettleImageOcr"/> — including the
/// "no text / undecodable" case — so nothing is re-OCR'd forever.
///
/// <para>
/// Image classification (macOS <c>VNClassifyImageRequest</c>) has no
/// built-in Windows equivalent and is out of scope here;
/// <c>image_tags</c> stays NULL (⏳ in <c>docs/parity.md</c>).
/// </para>
/// </summary>
public sealed class ImageAnalysisService : IDisposable
{
    private readonly EntryRepository _entries;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private System.Threading.Timer? _timer;
    private CancellationTokenSource? _cts;

    /// <summary>Periodic sweep cadence. First tick fires on Start to
    /// drain whatever accumulated while the app wasn't running.</summary>
    public TimeSpan Interval { get; set; } = TimeSpan.FromMinutes(15);

    /// <summary>Images per cycle. Smaller than the link batch — decode +
    /// OCR is heavier than an HTTP head, and capture-wake keeps the
    /// freshly-pasted screenshot prompt anyway.</summary>
    public int BatchSize { get; set; } = 3;

    /// <summary>Raised after a row is settled so the UI can re-query
    /// (the screenshot is now searchable by its text).</summary>
    public event EventHandler<ImageAnalyzedEventArgs>? RowSettled;

    /// <summary>Cycle-level failures (never per-image — those settle as
    /// "no text"). For visibility/logging only; the loop keeps going.</summary>
    public event EventHandler<Exception>? Errored;

    public ImageAnalysisService(EntryRepository entries) => _entries = entries;

    public void Start()
    {
        if (_timer is not null) throw new InvalidOperationException(
            $"{nameof(ImageAnalysisService)} already started");
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
    /// One sweep: OCR up to <paramref name="overrideBatchSize"/> (or
    /// <see cref="BatchSize"/>) un-analyzed images. Reentrant-guarded so
    /// capture-wake and the periodic timer coalesce. Returns the number
    /// of rows settled (handy for the CLI's drain loop).
    /// </summary>
    public async Task<int> RunOnceAsync(int? overrideBatchSize = null, CancellationToken ct = default)
    {
        if (!await _gate.WaitAsync(0, ct).ConfigureAwait(false)) return 0;
        int settled = 0;
        try
        {
            var ids = _entries.NextImageAnalysisCandidates(
                overrideBatchSize ?? BatchSize);
            foreach (var id in ids)
            {
                if (ct.IsCancellationRequested) break;

                // Largest available raster flavor. Capture stores PNG
                // (incl. DIB→PNG conversion); JPEG is the browser-drag
                // fallback. If neither resolves, settle as "no text" so
                // the row stops being a candidate.
                var bytes = _entries.GetFlavorBytes(id, "public.png")
                          ?? _entries.GetFlavorBytes(id, "public.jpeg");

                string? text = null;
                string? tags = null;
                if (bytes is not null)
                {
                    // OCR + classify run sequentially, not in parallel —
                    // both are CPU-bound on the same core in practice and
                    // sequencing keeps memory low (no two decoded
                    // bitmaps live at once).
                    text = await ImageOcr.RecognizeAsync(bytes, ct).ConfigureAwait(false);
                    tags = await ImageClassifier.ClassifyAsync(bytes, topK: 3, ct: ct)
                        .ConfigureAwait(false);
                }

                _entries.SettleImageAnalysis(id, text, tags);
                settled++;
                try { RowSettled?.Invoke(this, new ImageAnalyzedEventArgs(id, text, tags)); }
                catch { /* UI handler must not break the loop */ }
            }
        }
        catch (OperationCanceledException)
        {
            // Stop / Dispose — not an error.
        }
        catch (Exception ex)
        {
            try { Errored?.Invoke(this, ex); } catch { }
        }
        finally
        {
            try { _gate.Release(); } catch (ObjectDisposedException) { }
        }
        return settled;
    }

    /// <summary>
    /// Hint that a fresh kind=image capture landed — OCR it now rather
    /// than waiting for the periodic tick. Coalesces through the gate.
    /// </summary>
    public void WakeForCapture()
    {
        var token = _cts?.Token ?? CancellationToken.None;
        _ = RunOnceAsync(null, token);
    }

    /// <summary>
    /// Drain every pending image (used by the CLI, which has no periodic
    /// timer). Loops until a sweep settles nothing.
    /// </summary>
    public async Task<int> DrainAsync(CancellationToken ct = default)
    {
        int total = 0, n;
        do { n = await RunOnceAsync(BatchSize, ct).ConfigureAwait(false); total += n; }
        while (n > 0 && !ct.IsCancellationRequested);
        return total;
    }
}

public sealed class ImageAnalyzedEventArgs : EventArgs
{
    public long EntryId { get; }
    /// <summary>The recognised text, or null when none was found.</summary>
    public string? OcrText { get; }
    /// <summary>Space-separated classifier labels, or null when the
    /// classifier was unavailable / produced no usable tags.</summary>
    public string? ImageTags { get; }
    public ImageAnalyzedEventArgs(long entryId, string? ocrText, string? imageTags = null)
    {
        EntryId   = entryId;
        OcrText   = ocrText;
        ImageTags = imageTags;
    }
}
