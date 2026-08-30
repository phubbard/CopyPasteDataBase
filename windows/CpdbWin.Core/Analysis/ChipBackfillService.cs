using CpdbWin.Core.Store;

namespace CpdbWin.Core.Analysis;

/// <summary>
/// Background action-chip pass for text + link entries — the Windows
/// analogue of macOS <c>TextChipBackfiller</c>. Same shape as the
/// other sweepers (periodic timer + capture-wake + reentry gate):
/// scans <c>text_preview</c> via <see cref="TextChipDetector"/> and
/// writes a merged <c>chips_json</c> via
/// <see cref="EntryRepository.SetChipsIfUnset"/>.
///
/// <para>
/// Idempotence + drain: <c>EntriesNeedingChips</c> returns rows with
/// <c>chips_json IS NULL</c>. A row that came back with zero chips
/// still writes <c>"[]"</c> (not NULL) so it stops being a candidate.
/// Re-scanning after a detector improvement is a separate operation
/// (a future "Re-scan chips" maintenance action, mirroring "Re-OCR
/// images" / "Refetch all link titles").
/// </para>
/// </summary>
public sealed class ChipBackfillService : IDisposable
{
    private readonly EntryRepository _entries;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private System.Threading.Timer? _timer;
    private CancellationTokenSource? _cts;

    /// <summary>Periodic sweep cadence. Chip detection is cheap
    /// (regex, no ML, no network) so we can run more often than the
    /// embedding sweeper.</summary>
    public TimeSpan Interval { get; set; } = TimeSpan.FromMinutes(2);

    /// <summary>Rows per cycle. Mac uses 50; keeping that value here
    /// so cross-platform sweep behaviour stays predictable.</summary>
    public int BatchSize { get; set; } = 50;

    /// <summary>Raised after a row is settled so the UI can re-query
    /// (chip pills should surface on the just-scanned row).</summary>
    public event EventHandler<ChipsScannedEventArgs>? RowSettled;

    /// <summary>Cycle-level failures. Per-row failures log and
    /// continue.</summary>
    public event EventHandler<Exception>? Errored;

    public ChipBackfillService(EntryRepository entries) => _entries = entries;

    public void Start()
    {
        if (_timer is not null) throw new InvalidOperationException(
            $"{nameof(ChipBackfillService)} already started");
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

    /// <summary>Sweep up to <paramref name="overrideBatchSize"/> (or
    /// <see cref="BatchSize"/>) NULL-chips rows. Reentrant-guarded so
    /// capture-wake and the periodic timer coalesce. Returns the
    /// number of rows settled.</summary>
    public async Task<int> RunOnceAsync(int? overrideBatchSize = null, CancellationToken ct = default)
    {
        if (!await _gate.WaitAsync(0, ct).ConfigureAwait(false)) return 0;
        try
        {
            var limit = overrideBatchSize ?? BatchSize;
            if (limit <= 0) return 0;

            var ids = _entries.EntriesNeedingChips(limit);
            if (ids.Count == 0) return 0;

            int settled = 0;
            foreach (var id in ids)
            {
                if (ct.IsCancellationRequested) break;
                try
                {
                    // Detection is fast regex work — run inline on the
                    // sweep thread rather than paying Task.Run overhead
                    // per row. If a specific detector call ever gets
                    // slow (large paragraph → many phone matches, say)
                    // we can revisit.
                    var text = _entries.GetChipScanText(id);
                    var chips = TextChipDetector.Detect(text);
                    var json = Chip.Merge(existingJson: null, newChips: chips);
                    _entries.SetChipsIfUnset(id, json);
                    settled++;
                    RowSettled?.Invoke(this, new ChipsScannedEventArgs(id, chips.Count));
                }
                catch (OperationCanceledException) { throw; }
                catch (Exception)
                {
                    // One bad row doesn't abort the batch — same
                    // policy the OCR + embed sweepers use. NULL stays,
                    // the row shows up as a candidate next tick.
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

    /// <summary>Kick a single sweep, fire-and-forget. Called from the
    /// capture pipeline after a text/link insert so freshly-pasted
    /// content picks up chip pills within a couple seconds instead of
    /// waiting on the periodic timer.</summary>
    public void WakeForCapture()
    {
        var token = _cts?.Token ?? CancellationToken.None;
        _ = RunOnceAsync(null, token);
    }
}

public sealed class ChipsScannedEventArgs : EventArgs
{
    public long EntryId { get; }
    public int  ChipCount { get; }
    public ChipsScannedEventArgs(long entryId, int chipCount)
    {
        EntryId = entryId;
        ChipCount = chipCount;
    }
}
