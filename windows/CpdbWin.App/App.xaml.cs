using System.Runtime.InteropServices;
using CpdbWin.Core;
using CpdbWin.Core.Service;
using CpdbWin.Core.Store;
using Microsoft.UI.Xaml;
using WinRT.Interop;

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
    private PreferencesWindow? _prefsWindow;
    private TrayIcon? _tray;
    private GlobalHotkey? _hotkey;
    private UserSettings _settings = new();
    private string _settingsPath = string.Empty;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Host = AppHost.Bootstrap();
        _settingsPath = Path.Combine(Host.Paths.Root, "settings.json");
        _settings = UserSettings.Load(_settingsPath);

        _mainWindow = new MainWindow(Host);
        _mainWindow.Activate();

        _tray = new TrayIcon
        {
            Tooltip = $"{CpdbVersion.Full} — {HotkeyFormatter.Format(_settings.Hotkey)}",
            AutoLaunchChecked = AutoLaunch.IsEnabled(),
        };
        _tray.Activated            += () => _mainWindow.DispatcherQueue.TryEnqueue(BringMainToFront);
        _tray.ShowRequested        += () => _mainWindow.DispatcherQueue.TryEnqueue(BringMainToFront);
        _tray.PreferencesRequested += () => _mainWindow.DispatcherQueue.TryEnqueue(OpenPreferences);
        _tray.QuitRequested        += () => _mainWindow.DispatcherQueue.TryEnqueue(QuitApp);
        _tray.AutoLaunchToggled    += enabled =>
        {
            AutoLaunch.SetEnabled(enabled);
            _tray.AutoLaunchChecked = AutoLaunch.IsEnabled();
        };
        _tray.Start();

        RegisterHotkey(_settings.Hotkey);
    }

    private void RegisterHotkey(HotkeyConfig cfg)
    {
        _hotkey?.Dispose();
        _hotkey = new GlobalHotkey { Modifiers = cfg.Modifiers, VirtualKey = cfg.VirtualKey };
        _hotkey.Pressed += () => _mainWindow!.DispatcherQueue.TryEnqueue(BringMainToFront);
        try
        {
            _hotkey.Start();
        }
        catch (InvalidOperationException)
        {
            // Combo already taken / OS-reserved — leave the listener null;
            // the user will notice the hotkey doesn't work and can pick
            // another via Preferences.
            _hotkey = null;
        }
        // Tray tooltip only reflects the hotkey at launch time — updating
        // the tray icon's text after Shell_NotifyIcon NIM_ADD requires
        // NIM_MODIFY plumbing on the tray's message-pump thread, deferred.
    }

    private void OpenPreferences()
    {
        if (_prefsWindow is not null)
        {
            _prefsWindow.AppWindow.Show();
            _prefsWindow.Activate();
            return;
        }
        _prefsWindow = new PreferencesWindow(_settings, _settingsPath, RegisterHotkey);
        _prefsWindow.Closed += (_, _) => _prefsWindow = null;
        _prefsWindow.Activate();
    }

    private void BringMainToFront()
    {
        if (_mainWindow is null) return;
        _mainWindow.AppWindow.Show();

        // WinUI's Window.Activate() doesn't reliably steal the foreground
        // when called from a background-thread event (tray click /
        // WM_HOTKEY) — Windows' foreground rules block silent z-order
        // changes from non-foreground processes. The portable workaround
        // is the AttachThreadInput trick: temporarily attach our input
        // queue to the current foreground window's thread so the focus
        // transition counts as "from the same input context."
        var hwnd = WindowNative.GetWindowHandle(_mainWindow);
        ForceForeground(hwnd);
        _mainWindow.Activate();
    }

    private static void ForceForeground(IntPtr hwnd)
    {
        var thisThread = GetCurrentThreadId();
        var fg = GetForegroundWindow();
        uint fgThread = fg != IntPtr.Zero ? GetWindowThreadProcessId(fg, IntPtr.Zero) : 0;

        bool attached = false;
        if (fgThread != 0 && fgThread != thisThread)
            attached = AttachThreadInput(fgThread, thisThread, true);

        try
        {
            ShowWindow(hwnd, SW_RESTORE);
            SetForegroundWindow(hwnd);
            SetActiveWindow(hwnd);
            SetFocus(hwnd);
        }
        finally
        {
            if (attached) AttachThreadInput(fgThread, thisThread, false);
        }
    }

    private const int SW_RESTORE = 9;

    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]   private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]   private static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr processId);
    [DllImport("user32.dll")]   private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")]   private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]   private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]   private static extern IntPtr SetActiveWindow(IntPtr hWnd);
    [DllImport("user32.dll")]   private static extern IntPtr SetFocus(IntPtr hWnd);

    private void QuitApp()
    {
        _hotkey?.Dispose();
        _tray?.Dispose();
        Host?.Dispose();
        Exit();
    }
}
