namespace CpdbWin.App;

/// <summary>
/// Process-wide single-instance guard. cpdb-win is a background
/// clipboard daemon: a second copy means two capture loops racing,
/// two global hotkeys fighting over the same chord, and two writers
/// on one SQLite file. The common trigger is innocuous — "Launch on
/// login" brings one up at boot, then the user double-clicks the
/// Start-menu shortcut and gets a second.
///
/// <para>
/// Mechanism: a named <see cref="Mutex"/> — the first process to
/// create it owns the singleton for its lifetime. A second launch
/// finds the mutex already exists, pokes a named auto-reset
/// <see cref="EventWaitHandle"/> so the live instance surfaces its
/// window, and exits before opening the DB or creating any UI (so a
/// duplicate launch feels like "bring to front", not a no-op). The
/// live instance runs a tiny listener thread that fires
/// <see cref="ShowRequested"/> whenever that event is set.
/// </para>
///
/// <para>
/// Names live in the <c>Local\</c> namespace (per-session, per-user)
/// — that is exactly the scope we want to deduplicate. The OS frees
/// the named mutex when the owning process exits, so a crash can't
/// wedge the singleton, and Velopack's update-restart (old process
/// fully exits before Update.exe launches the new one) is unaffected.
/// </para>
/// </summary>
public sealed class SingleInstance : IDisposable
{
    private const string MutexName     = @"Local\cpdb-win-singleton";
    private const string ShowEventName = @"Local\cpdb-win-show";

    private readonly Mutex _mutex;
    private readonly EventWaitHandle _showEvent;
    private readonly EventWaitHandle _stopEvent;
    private Thread? _listener;
    private bool _disposed;

    /// <summary>
    /// Raised (on the listener thread) when another launch asked the
    /// running instance to surface. Subscribers must marshal to the UI
    /// thread themselves.
    /// </summary>
    public event Action? ShowRequested;

    private SingleInstance(Mutex mutex, EventWaitHandle showEvent, EventWaitHandle stopEvent)
    {
        _mutex = mutex;
        _showEvent = showEvent;
        _stopEvent = stopEvent;
    }

    /// <summary>
    /// Claim the singleton. Returns the owning <see cref="SingleInstance"/>
    /// if this process is the first; returns <c>null</c> if another
    /// instance already owns it — in which case that instance has been
    /// poked to show its window and the caller MUST exit immediately
    /// without bootstrapping anything.
    /// </summary>
    public static SingleInstance? Acquire()
    {
        var mutex = new Mutex(initiallyOwned: true, MutexName, out bool createdNew);
        if (!createdNew)
        {
            // Another instance owns the singleton. Best-effort poke so
            // it brings its window forward, then we bow out.
            try
            {
                if (EventWaitHandle.TryOpenExisting(ShowEventName, out var ev))
                {
                    ev.Set();
                    ev.Dispose();
                }
            }
            catch { /* surfacing the other window is best-effort */ }
            mutex.Dispose();
            return null;
        }

        var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        var stopEvent = new EventWaitHandle(false, EventResetMode.ManualReset);
        var si = new SingleInstance(mutex, showEvent, stopEvent);
        si.StartListener();
        return si;
    }

    private void StartListener()
    {
        _listener = new Thread(() =>
        {
            var handles = new WaitHandle[] { _showEvent, _stopEvent };
            while (true)
            {
                // index 0 = a duplicate launch asked us to surface;
                // index 1 = we're shutting down.
                if (WaitHandle.WaitAny(handles) == 1) return;
                try { ShowRequested?.Invoke(); } catch { }
            }
        })
        {
            IsBackground = true,
            Name = "CpdbSingleInstanceListener",
        };
        _listener.Start();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try { _stopEvent.Set(); } catch { }
        _listener?.Join(1000);
        try { _mutex.ReleaseMutex(); } catch { }
        _mutex.Dispose();
        _showEvent.Dispose();
        _stopEvent.Dispose();
    }
}
