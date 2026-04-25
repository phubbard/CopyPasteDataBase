using System.Runtime.InteropServices;

namespace CpdbWin.App;

/// <summary>
/// System-wide keyboard shortcut. Default is <c>Ctrl+Shift+V</c> — Win+V
/// is reserved by the OS clipboard history, so we steer clear. Hosted on
/// a dedicated hidden window so WM_HOTKEY is delivered cleanly without
/// fighting WinUI's UI thread.
///
/// <see cref="Pressed"/> fires from the listener thread; subscribers
/// MUST marshal to the UI thread themselves.
/// </summary>
public sealed class GlobalHotkey : IDisposable
{
    public event Action? Pressed;

    public uint Modifiers  { get; init; } = MOD_CONTROL | MOD_SHIFT;
    public uint VirtualKey { get; init; } = VK_V;

    public const uint MOD_ALT      = 0x0001;
    public const uint MOD_CONTROL  = 0x0002;
    public const uint MOD_SHIFT    = 0x0004;
    public const uint MOD_WIN      = 0x0008;
    public const uint MOD_NOREPEAT = 0x4000;
    public const uint VK_V         = 0x56;

    private const string ClassName = "CpdbWin.GlobalHotkey";
    private const uint WM_HOTKEY = 0x0312;
    private const uint WM_QUIT   = 0x0012;
    private const int  HOTKEY_ID = 1;

    private static readonly IntPtr HWND_MESSAGE = new(-3);

    private Thread? _thread;
    private uint _threadId;
    private IntPtr _hwnd;
    private Native.WndProc? _wndProc;
    private bool _disposed;

    public void Start()
    {
        if (_thread is not null) throw new InvalidOperationException("Hotkey already started");

        var ready = new ManualResetEventSlim(false);
        Exception? startErr = null;
        _thread = new Thread(() =>
        {
            try { Run(ready); }
            catch (Exception ex) { startErr = ex; ready.Set(); }
        })
        {
            IsBackground = true,
            Name = "CpdbGlobalHotkey",
        };
        _thread.Start();
        ready.Wait();
        if (startErr is not null) throw startErr;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_threadId != 0)
            Native.PostThreadMessageW(_threadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
        _thread?.Join();
    }

    private void Run(ManualResetEventSlim ready)
    {
        _threadId = Native.GetCurrentThreadId();
        _wndProc  = WndProc;

        var hInstance = Native.GetModuleHandleW(null);
        var wc = new Native.WNDCLASSEXW
        {
            cbSize        = (uint)Marshal.SizeOf<Native.WNDCLASSEXW>(),
            lpfnWndProc   = Marshal.GetFunctionPointerForDelegate(_wndProc),
            hInstance     = hInstance,
            lpszClassName = ClassName,
        };
        if (Native.RegisterClassExW(ref wc) == 0) ThrowLast(nameof(Native.RegisterClassExW));

        _hwnd = Native.CreateWindowExW(
            0, ClassName, ClassName, 0,
            0, 0, 0, 0,
            HWND_MESSAGE, IntPtr.Zero, hInstance, IntPtr.Zero);
        if (_hwnd == IntPtr.Zero) ThrowLast(nameof(Native.CreateWindowExW));

        if (!Native.RegisterHotKey(_hwnd, HOTKEY_ID, Modifiers | MOD_NOREPEAT, VirtualKey))
            ThrowLast(nameof(Native.RegisterHotKey));

        ready.Set();

        while (Native.GetMessageW(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            Native.TranslateMessage(ref msg);
            Native.DispatchMessageW(ref msg);
        }

        Native.UnregisterHotKey(_hwnd, HOTKEY_ID);
        Native.DestroyWindow(_hwnd);
        Native.UnregisterClassW(ClassName, hInstance);
    }

    private IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_HOTKEY)
        {
            try { Pressed?.Invoke(); } catch { }
            return IntPtr.Zero;
        }
        return Native.DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    private static void ThrowLast(string what)
    {
        var err = Marshal.GetLastWin32Error();
        throw new InvalidOperationException(
            $"{what} failed (Win32 {err}). Another app may already have the hotkey.");
    }

    private static class Native
    {
        public delegate IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct MSG
        {
            public IntPtr hwnd;
            public uint   message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint   time;
            public int    pt_x, pt_y;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct WNDCLASSEXW
        {
            public uint   cbSize;
            public uint   style;
            public IntPtr lpfnWndProc;
            public int    cbClsExtra;
            public int    cbWndExtra;
            public IntPtr hInstance;
            public IntPtr hIcon;
            public IntPtr hCursor;
            public IntPtr hbrBackground;
            [MarshalAs(UnmanagedType.LPWStr)] public string? lpszMenuName;
            [MarshalAs(UnmanagedType.LPWStr)] public string  lpszClassName;
            public IntPtr hIconSm;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr GetModuleHandleW(string? lpModuleName);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint GetCurrentThreadId();

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern ushort RegisterClassExW(ref WNDCLASSEXW lpwcx);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool UnregisterClassW(string lpClassName, IntPtr hInstance);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateWindowExW(
            uint dwExStyle, string lpClassName, string lpWindowName, uint dwStyle,
            int X, int Y, int nWidth, int nHeight,
            IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool DestroyWindow(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int GetMessageW(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

        [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG lpMsg);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr DispatchMessageW(ref MSG lpMsg);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool PostThreadMessageW(uint idThread, uint Msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    }
}
