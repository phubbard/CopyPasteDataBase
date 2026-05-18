using System.Runtime.InteropServices;
using CpdbWin.Core;
using CpdbWin.Core.Service;
using CpdbWin.Core.Store;
using Microsoft.UI.Xaml;
using Velopack;
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
        try { OnLaunchedCore(args); }
        catch (Exception ex)
        {
            try
            {
                var path = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "cpdb", "startup-crash.log");
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path,
                    $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] OnLaunched threw\n\n" +
                    ex.ToString());
            }
            catch { /* best effort */ }
            throw;
        }
    }

    private void OnLaunchedCore(LaunchActivatedEventArgs args)
    {
        // Velopack hooks: when Setup.exe / squirrel-flavoured commands
        // invoke our exe with --veloapp-* args, Run() handles the
        // install / uninstall / update lifecycle and exits before any
        // UI is shown. On a normal launch it returns immediately.
        // Lives at the top of OnLaunched (rather than in a custom Main)
        // so we don't have to fight the WinAppSDK auto-generated Main +
        // bootstrap sequence; one less moving part to break.
        VelopackApp.Build().Run();

        Host = AppHost.Bootstrap();
        _settingsPath = Path.Combine(Host.Paths.Root, "settings.json");
        _settings = UserSettings.Load(_settingsPath);

        // First-run default: enable autostart so the app comes back up after
        // a reboot without the user having to remember the tray-menu toggle.
        // Idempotent — once we've initialized once, the user's later choice
        // (off, in particular) sticks. The flag lives in settings.json next
        // to the rest of the prefs.
        if (!_settings.AutoLaunchInitialized)
        {
            AutoLaunch.SetEnabled(true);
            _settings.AutoLaunchInitialized = true;
            _settings.Save(_settingsPath);
        }

        _mainWindow = new MainWindow(Host);
        _ourMainHwnd = WindowNative.GetWindowHandle(_mainWindow);
        InstallForegroundHook();
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
        _prefsWindow = new PreferencesWindow(_settings, _settingsPath, RegisterHotkey, Host!);
        _prefsWindow.Closed += (_, _) => _prefsWindow = null;
        _prefsWindow.Activate();
    }

    /// <summary>
    /// HWND of whatever app held the foreground most recently — but never
    /// cpdb-win itself. Continuously updated by a global
    /// <see cref="SetWinEventHook"/> on <c>EVENT_SYSTEM_FOREGROUND</c>,
    /// which means it stays correct whether the user summoned us via
    /// hotkey, tray click, click-on-an-already-visible window, or any
    /// other path. The paste-back code reads + clears this when it
    /// dispatches Ctrl+V back to the source app.
    /// </summary>
    public static IntPtr LastForegroundHwnd { get; private set; }

    // Keep a strong reference to the delegate so the GC doesn't collect
    // the callback target while the OS is still calling into it.
    private static WinEventDelegate? _foregroundHookDelegate;
    private static IntPtr _foregroundHookHandle;
    private static IntPtr _ourMainHwnd;

    /// <summary>
    /// Install a global <see cref="SetWinEventHook"/> for
    /// <c>EVENT_SYSTEM_FOREGROUND</c> so we know which window the user
    /// was looking at right before they summoned cpdb-win — regardless
    /// of how they summoned it (hotkey, tray click, click-on-already-
    /// visible window). The callback updates
    /// <see cref="LastForegroundHwnd"/> on every foreground change that
    /// isn't our own window. Without this, the paste-back path silently
    /// fails the first time the user clicks back to a still-open
    /// cpdb-win window after a previous paste cleared the captured HWND.
    /// </summary>
    private void InstallForegroundHook()
    {
        // Hold the delegate in a static field so the GC doesn't reclaim
        // it while the OS holds an unmanaged callback reference.
        _foregroundHookDelegate = OnForegroundChanged;
        _foregroundHookHandle = SetWinEventHook(
            EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
            IntPtr.Zero, _foregroundHookDelegate, 0, 0,
            WINEVENT_OUTOFCONTEXT);
    }

    private static void OnForegroundChanged(
        IntPtr hWinEventHook, uint eventType, IntPtr hwnd,
        int idObject, int idChild, uint dwEventThread, uint dwmsEventTime)
    {
        if (hwnd == IntPtr.Zero) return;
        if (hwnd == _ourMainHwnd) return; // ignore self-foreground events
        // Only top-level windows (idObject == OBJID_WINDOW = 0,
        // idChild == CHILDID_SELF = 0). Skip menu / button / etc.
        if (idObject != 0 || idChild != 0) return;
        LastForegroundHwnd = hwnd;
    }

    private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    private const uint WINEVENT_OUTOFCONTEXT = 0x0000;

    private delegate void WinEventDelegate(
        IntPtr hWinEventHook, uint eventType, IntPtr hwnd,
        int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);

    [DllImport("user32.dll")]
    private static extern IntPtr SetWinEventHook(
        uint eventMin, uint eventMax, IntPtr hmodWinEventProc,
        WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);

    private void BringMainToFront()
    {
        if (_mainWindow is null) return;

        // Capture the current foreground HWND BEFORE we steal focus —
        // belt-and-braces alongside the global SetWinEventHook installed
        // in InstallForegroundHook(). Skip if it's our own window
        // already (the user just clicked our tray when our window was
        // already up).
        var ourHwnd = WindowNative.GetWindowHandle(_mainWindow);
        _ourMainHwnd = ourHwnd;
        var prev = GetForegroundWindow();
        if (prev != IntPtr.Zero && prev != ourHwnd)
        {
            LastForegroundHwnd = prev;
        }

        _mainWindow.AppWindow.Show();

        // WinUI's Window.Activate() doesn't reliably steal the foreground
        // when called from a background-thread event (tray click /
        // WM_HOTKEY) — Windows' foreground rules block silent z-order
        // changes from non-foreground processes. The portable workaround
        // is the AttachThreadInput trick: temporarily attach our input
        // queue to the current foreground window's thread so the focus
        // transition counts as "from the same input context."
        ForceForeground(ourHwnd);
        _mainWindow.Activate();
    }

    /// <summary>
    /// Hide our window, restore the previously-foreground app, then send
    /// it Ctrl+V so the just-copied flavor pastes immediately. Called by
    /// MainWindow after a successful clipboard write. If we have no
    /// captured HWND (cold start, app launched without a prior foreground),
    /// just hide and leave it to the user to paste manually.
    /// </summary>
    public static async void HideAndPasteToPreviousForeground(Window win)
    {
        var prev = LastForegroundHwnd;
        LastForegroundHwnd = IntPtr.Zero;

        win.AppWindow.Hide();
        WritePasteLog($"hide; prevHwnd=0x{prev.ToInt64():X}");

        if (prev == IntPtr.Zero)
        {
            WritePasteLog("no captured prevHwnd — manual paste");
            return;
        }

        // The hide message hasn't settled by the time we return from
        // AppWindow.Hide(); without a yield, SetForegroundWindow runs
        // while our window still owns the foreground and silently fails
        // (Windows blocks foreground steals from the same process that
        // just had it). Dispatch back via the queue + a small Task.Delay
        // so the foreground transition completes first.
        await Task.Delay(50).ConfigureAwait(true);

        // Hand focus back. AttachThreadInput is the same trick we use
        // on the way IN — it lets SetForegroundWindow / SetFocus
        // succeed across thread boundaries by temporarily fusing the
        // input queues. Without it, modern Windows ignores the request
        // when the source process isn't the just-active one.
        var ourThread = GetCurrentThreadId();
        var prevThread = GetWindowThreadProcessId(prev, IntPtr.Zero);
        bool attached = false;
        if (prevThread != 0 && prevThread != ourThread)
        {
            attached = AttachThreadInput(ourThread, prevThread, true);
        }
        bool fgOk = false;
        bool wasIconic = IsIconic(prev);
        try
        {
            // Only un-minimize when the previous window is actually
            // minimized. Calling SW_RESTORE on a normal window can
            // toggle z-order / snap state and move it visually — that's
            // what was making the user's foreground app "jump."
            if (wasIconic) ShowWindow(prev, SW_RESTORE);
            fgOk = SetForegroundWindow(prev);
            SetFocus(prev);
        }
        finally
        {
            if (attached) AttachThreadInput(ourThread, prevThread, false);
        }
        WritePasteLog($"SetForegroundWindow → {fgOk} (attached={attached}, wasIconic={wasIconic})");

        // One more tiny yield so the keystroke lands after focus
        // actually transitions. SendInput targets whatever has the
        // keyboard focus *at the moment SendInput is called*, not the
        // window we just asked to be foreground.
        await Task.Delay(30).ConfigureAwait(true);

        // Drain any modifiers the user may still be holding from the
        // hotkey chord. Without this, Ctrl+Shift+V is still partially
        // pressed when we SendInput our own Ctrl+V — the OS sees
        // Ctrl+Shift+V again, re-fires our hotkey, and we pop the
        // window back up instead of pasting. We send key-ups for
        // Shift / Alt / Win (Ctrl is fine because we're about to send
        // Ctrl-down ourselves and then key-up at the end).
        ReleaseModifiers();

        // Sanity-check the clipboard right before SendInput — if it
        // doesn't contain the expected text, something raced us
        // (another clipboard manager, our own listener, …) and the
        // paste-back is going to land empty. Diagnostic only; we still
        // fire SendInput even if the readback is empty.
        var fgAfter = GetForegroundWindow();
        var fgClass = ClassName(fgAfter);
        WritePasteLog($"  fg before SendInput: 0x{fgAfter.ToInt64():X} class='{fgClass}' clipText='{Trunc(ReadClipboardTextSafe(), 40)}'");

        SendCtrlV();
        WritePasteLog("SendInput Ctrl+V");
    }

    /// <summary>
    /// Best-effort clipboard text readback. Diagnostic surface — never
    /// thrown; returns empty on any failure. Synchronous because we
    /// call from the dispatcher thread and the data is already in the
    /// clipboard our own ClipboardWriter just wrote.
    /// </summary>
    private static string ReadClipboardTextSafe()
    {
        try
        {
            var dp = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
            if (dp.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text))
            {
                return dp.GetTextAsync().AsTask().GetAwaiter().GetResult() ?? "";
            }
            return "(non-text clipboard)";
        }
        catch (Exception ex) { return $"(error: {ex.Message})"; }
    }

    private static string Trunc(string s, int max) =>
        s is null ? "" : (s.Length <= max ? s : s.Substring(0, max) + "…");

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);

    private static string ClassName(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return "";
        var sb = new System.Text.StringBuilder(256);
        GetClassName(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    /// <summary>
    /// Synthesize key-up events for Shift / Alt / Win so a still-held
    /// hotkey chord doesn't recombine with our incoming
    /// <see cref="SendCtrlV"/>. We don't release Ctrl because Ctrl+V's
    /// chord-down/up sequence handles it.
    /// </summary>
    private static void ReleaseModifiers()
    {
        const ushort VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1;
        const ushort VK_LMENU  = 0xA4, VK_RMENU  = 0xA5;   // Alt
        const ushort VK_LWIN   = 0x5B, VK_RWIN   = 0x5C;
        var ups = new[]
        {
            MakeKey(VK_LSHIFT, keyUp: true),
            MakeKey(VK_RSHIFT, keyUp: true),
            MakeKey(VK_LMENU,  keyUp: true),
            MakeKey(VK_RMENU,  keyUp: true),
            MakeKey(VK_LWIN,   keyUp: true),
            MakeKey(VK_RWIN,   keyUp: true),
        };
        SendInput((uint)ups.Length, ups, Marshal.SizeOf<INPUT>());
    }

    /// <summary>
    /// Append one line per paste-back attempt to
    /// <c>%LOCALAPPDATA%\cpdb\paste-back.log</c>. Best-effort diagnostic
    /// surface only — failures here must never propagate. Self-rotates
    /// at 1 MB. Internal so <c>MainWindow</c> can log entry-side events
    /// (which path called ActivateEntry, whether the clipboard write
    /// succeeded) into the same file.
    /// </summary>
    internal static void WritePasteLog(string message)
    {
        try
        {
            var path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "cpdb", "paste-back.log");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path) && new FileInfo(path).Length > 1_000_000)
            {
                File.WriteAllText(path, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] (rotated)\n");
            }
            File.AppendAllText(path,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}\n");
        }
        catch { }
    }

    /// <summary>
    /// Synthesize a Ctrl+V keystroke via SendInput. Targets whatever has
    /// keyboard focus right now — caller must SetForegroundWindow first.
    /// Logs the return value so future "no paste even though log is
    /// green" mysteries leave a breadcrumb.
    /// </summary>
    private static void SendCtrlV()
    {
        // VK_CONTROL = 0x11, V = 0x56. Down-down-up-up so receivers that
        // match on Ctrl+V (vs separate Ctrl-then-V) see the chord.
        var inputs = new INPUT[4];
        inputs[0] = MakeKey(0x11, keyUp: false);  // Ctrl down
        inputs[1] = MakeKey(0x56, keyUp: false);  // V    down
        inputs[2] = MakeKey(0x56, keyUp: true);   // V    up
        inputs[3] = MakeKey(0x11, keyUp: true);   // Ctrl up
        var size = Marshal.SizeOf<INPUT>();
        var injected = SendInput((uint)inputs.Length, inputs, size);
        var err = injected == inputs.Length ? 0 : Marshal.GetLastWin32Error();
        WritePasteLog($"  SendInput injected={injected}/{inputs.Length} cbSize={size} lastError={err}");
    }

    private static INPUT MakeKey(ushort vk, bool keyUp)
    {
        const uint INPUT_KEYBOARD = 1;
        const uint KEYEVENTF_KEYUP = 0x0002;
        return new INPUT
        {
            type = INPUT_KEYBOARD,
            U = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = vk,
                    wScan = 0,
                    dwFlags = keyUp ? KEYEVENTF_KEYUP : 0,
                    time = 0,
                    dwExtraInfo = IntPtr.Zero,
                }
            }
        };
    }

    // SendInput's native INPUT struct contains a union sized to its
    // largest member, MOUSEINPUT (28 bytes on x64). If we only declare
    // KEYBDINPUT (24 bytes) the managed struct size mismatches what
    // SendInput expects for cbSize, and the OS silently rejects every
    // event without injecting a single keystroke. Spell the full union
    // out so Marshal.SizeOf<INPUT>() returns the correct value (40 on
    // x64, 28 on x86).
    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public InputUnion U; }
    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT    mi;
        [FieldOffset(0)] public KEYBDINPUT    ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int    dx;
        public int    dy;
        public uint   mouseData;
        public uint   dwFlags;
        public uint   time;
        public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint   dwFlags;
        public uint   time;
        public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint   uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs,
        [MarshalAs(UnmanagedType.LPArray)] INPUT[] pInputs, int cbSize);

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
    [DllImport("user32.dll")]   private static extern bool IsIconic(IntPtr hWnd);
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
