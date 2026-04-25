using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;

namespace CpdbWin.Core.Service;

/// <summary>
/// End-to-end capture loop: subscribes to clipboard updates, takes a
/// snapshot, attributes it to the foreground app, and hands the result to
/// the <see cref="Ingestor"/>. The single class users of cpdb-win wire up
/// in their tray-app boot path.
///
/// Failures inside the capture path (busy clipboard, missing FG window,
/// transient SQLite lock) are swallowed — the listener thread MUST keep
/// pumping or we miss every subsequent event. Subscribe to
/// <see cref="Ingested"/> for visibility (UI badge, log line).
/// </summary>
public sealed class CaptureService : IDisposable
{
    private readonly Ingestor _ingestor;
    private readonly DeviceIdentity.Info _device;
    private ClipboardListener? _listener;

    public event EventHandler<IngestOutcome>? Ingested;
    public event EventHandler<Exception>? Errored;

    public CaptureService(Ingestor ingestor)
        : this(ingestor, DeviceIdentity.Read())
    { }

    public CaptureService(Ingestor ingestor, DeviceIdentity.Info device)
    {
        _ingestor = ingestor;
        _device = device;
    }

    public DeviceIdentity.Info Device => _device;

    public void Start()
    {
        if (_listener is not null) throw new InvalidOperationException("CaptureService already started");
        _listener = new ClipboardListener();
        _listener.ClipboardChanged += OnClipboardChanged;
        _listener.Start();
    }

    public void Dispose()
    {
        _listener?.Dispose();
        _listener = null;
    }

    private void OnClipboardChanged(object? sender, EventArgs e)
    {
        try
        {
            var snapshot = ClipboardSnapshot.Capture();
            if (snapshot.Flavors.Count == 0) return;

            var app = ForegroundApp.Detect();
            var outcome = _ingestor.Ingest(snapshot, app, _device);
            Ingested?.Invoke(this, outcome);
        }
        catch (Exception ex)
        {
            // Notify but never propagate — propagating would tear down the
            // message-pump thread and orphan the hidden window.
            try { Errored?.Invoke(this, ex); } catch { }
        }
    }
}
