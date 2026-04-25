using System.Runtime.InteropServices;
using CpdbWin.Core;
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

        _tray = new TrayIcon
        {
            Tooltip = CpdbVersion.Full,
            AutoLaunchChecked = AutoLaunch.IsEnabled(),
        };
        _tray.Activated         += () => _mainWindow.DispatcherQueue.TryEnqueue(BringMainToFront);
        _tray.ShowRequested     += () => _mainWindow.DispatcherQueue.TryEnqueue(BringMainToFront);
        _tray.QuitRequested     += () => _mainWindow.DispatcherQueue.TryEnqueue(QuitApp);
        _tray.AutoLaunchToggled += enabled =>
        {
            AutoLaunch.SetEnabled(enabled);
            _tray.AutoLaunchChecked = AutoLaunch.IsEnabled();
        };
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
