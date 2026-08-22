using System.Diagnostics;
using System.Text;

namespace CpdbWin.App;

/// <summary>
/// Permanent instrumentation for the popup-summon path — one info-level
/// line per summon with per-stage timings + per-item counters. Mirrors
/// the Mac's <c>popup-perf</c> line (see
/// <c>docs/handoffs/windows-popup-perf.md</c>) so cross-platform log
/// parsers see the same shape.
///
/// <para>
/// One summon owns one <see cref="Session"/>. The hotkey / tray / show
/// entry point calls <see cref="Begin"/>, each stage boundary calls
/// <see cref="Stage"/>, and the first-frame handler (usually a
/// <c>DispatcherQueuePriority.Low</c> callback enqueued after
/// <c>Refresh()</c>) calls <see cref="EndAndEmit"/>. All timings are
/// wall-clock milliseconds relative to the previous stage.
/// </para>
///
/// <para>
/// The log lives at <c>%LOCALAPPDATA%\cpdb\popup-perf.log</c> and
/// self-rotates at 1 MB — same convention as <c>image-preview.log</c>,
/// <c>update.log</c>, <c>gc.log</c>. Perf lines are cheap enough
/// (single formatted string, single append) to keep on forever, so
/// future regressions land in a log filter rather than a hunch.
/// </para>
/// </summary>
public static class PopupPerf
{
    /// <summary>Live summon in flight (null between summons). WinUI's
    /// summon path is inherently single-threaded on the UI dispatcher,
    /// so a static slot is safe — a new <see cref="Begin"/> replaces
    /// whatever's there, which harmlessly drops a summon that never
    /// completed (e.g. because the window was hidden mid-refresh).</summary>
    public static Session? Current;

    /// <summary>Total row-card thumbnail decodes since app-start, and the
    /// wall-clock ms spent on them. Incremented by <c>ThumbnailFrom</c>;
    /// Refresh() snapshots the deltas around its own body so the
    /// per-refresh cost is attributed to that refresh, not to the summon
    /// (Refresh runs on ingest / filter change / search too, not just
    /// summon). Also aggregated onto the active summon <see cref="Session"/>
    /// when one is in flight so the summon line reports its share.</summary>
    public static int GlobalThumbLoads;
    public static long GlobalThumbMs;

    public static Session Begin(string trigger, bool wasVisible)
    {
        Current = new Session(trigger, wasVisible);
        return Current;
    }

    public sealed class Session
    {
        private readonly Stopwatch _sw = Stopwatch.StartNew();
        private long _lastMs;
        private readonly List<(string Name, long Ms)> _stages = new();

        public string Trigger { get; }
        /// <summary>True when the popup was already visible at
        /// <see cref="Begin"/> — matches Mac's cold/warm distinction.
        /// The already-visible re-summon skips work the cold path does
        /// (window creation, first layout) so its numbers belong in a
        /// separate bucket.</summary>
        public bool WasVisible { get; }

        // Per-item counters — the Mac equivalents of `storeOpens`,
        // `thumbLoads`, `thumbMs`. Reset here and mutated from the
        // hot path via public field access (no method-call overhead).
        public int RowsShown;
        public int ThumbLoads;
        public long ThumbMs;

        internal Session(string trigger, bool wasVisible)
        {
            Trigger = trigger;
            WasVisible = wasVisible;
        }

        /// <summary>Record the elapsed time since the previous stage
        /// under <paramref name="name"/>. Names are terse
        /// (<c>show</c>, <c>refresh</c>, <c>activate</c>,
        /// <c>firstFrame</c>) so the log line stays scannable.</summary>
        public void Stage(string name)
        {
            var now = _sw.ElapsedMilliseconds;
            _stages.Add((name, now - _lastMs));
            _lastMs = now;
        }

        /// <summary>Terminate the session, emit the perf line, and
        /// clear <see cref="Current"/>. Safe to call more than once
        /// on the same session — subsequent calls are no-ops.</summary>
        public void EndAndEmit()
        {
            if (_sw.IsRunning) _sw.Stop();
            if (Current == this) Current = null;

            var sb = new StringBuilder();
            sb.Append("summon");
            sb.Append("  trigger=").Append(Trigger);
            sb.Append("  kind=").Append(WasVisible ? "warm" : "cold");
            sb.Append("  total=").Append(_sw.ElapsedMilliseconds).Append("ms");
            foreach (var (name, ms) in _stages)
                sb.Append("  ").Append(name).Append('=').Append(ms);
            sb.Append("  rows=").Append(RowsShown);
            sb.Append("  thumbLoads=").Append(ThumbLoads);
            sb.Append("  thumbMs=").Append(ThumbMs);
            Log(sb.ToString());
        }
    }

    /// <summary>Standalone refresh-cost line, emitted from every
    /// <c>MainWindow.Refresh()</c> call — including the constructor's
    /// initial populate, ingest wakes, filter changes, and search-box
    /// typing. Independent from summon sessions because Refresh runs
    /// outside them too, and its cost is what determines whether the
    /// list feels fresh vs stale to the user.</summary>
    public static void LogRefresh(
        int rows, long queryMs, long vmMs, long assignMs, long totalMs,
        int thumbLoads, long thumbMs)
    {
        Log(
            $"refresh  rows={rows}  total={totalMs}ms  query={queryMs}  vm={vmMs}  assign={assignMs}  "
          + $"thumbLoads={thumbLoads}  thumbMs={thumbMs}");
    }

    /// <summary>Append one line to <c>%LOCALAPPDATA%\cpdb\popup-perf.log</c>
    /// with a timestamp prefix, rotating the file at 1 MB. Best-effort:
    /// perf instrumentation must never break the UI, so all I/O errors
    /// are swallowed silently.</summary>
    private static void Log(string message)
    {
        try
        {
            var path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "cpdb", "popup-perf.log");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path) && new FileInfo(path).Length > 1_000_000)
                File.WriteAllText(path, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] (rotated)\n");
            File.AppendAllText(path,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}\n");
        }
        catch { /* never break the UI for instrumentation */ }
    }
}
