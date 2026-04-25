using Microsoft.UI.Xaml;

namespace CpdbWin.App;

/// <summary>
/// WinUI 3 application entry point. <see cref="AppHost"/> owns all the
/// engine state (DB, blob store, ingestor, capture service); the UI layer
/// just reads from it.
///
/// On launch we also boot a tray icon so the app keeps capturing after
/// the user closes the main window. Quit-via-tray is the only path that
/// actually shuts the process down.
/// </summary>
public partial class App : Application
{
    public static AppHost? Host { get; private set; }
    private MainWindow? _mainWindow;
    private TrayIcon? _tray;
    private GlobalHotkey? _hotkey;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Host = AppHost.Bootstrap();
        _mainWindow = new MainWindow(Host);
        _mainWindow.Activate();

        _tray = new TrayIcon { Tooltip = "cpdb-win" };
        _tray.Activated      += () => _mainWindow.DispatcherQueue.TryEnqueue(BringMainToFront);
        _tray.ShowRequested  += () => _mainWindow.DispatcherQueue.TryEnqueue(BringMainToFront);
        _tray.QuitRequested  += () => _mainWindow.DispatcherQueue.TryEnqueue(QuitApp);
        _tray.Start();

        // Ctrl+Shift+V — system-wide. Win+V is owned by the OS clipboard
        // history. If the hotkey is already taken by another app the
        // RegisterHotKey call throws; swallow it so the rest of the app
        // still launches.
        _hotkey = new GlobalHotkey();
        _hotkey.Pressed += () => _mainWindow.DispatcherQueue.TryEnqueue(BringMainToFront);
        try { _hotkey.Start(); }
        catch (InvalidOperationException) { _hotkey = null; }
    }

    private void BringMainToFront()
    {
        if (_mainWindow is null) return;
        _mainWindow.AppWindow.Show();
        _mainWindow.Activate();
    }

    private void QuitApp()
    {
        _hotkey?.Dispose();
        _tray?.Dispose();
        Host?.Dispose();
        Exit();
    }
}
