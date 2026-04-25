using System.Runtime.InteropServices;

namespace CpdbWin.Core.Capture;

/// <summary>
/// Subscribes to clipboard updates via a hidden message-only window +
/// AddClipboardFormatListener. Raises <see cref="ClipboardChanged"/> on the
/// listener's dedicated background thread once per WM_CLIPBOARDUPDATE.
///
/// The handler should be cheap: take a <see cref="ClipboardSnapshot"/> and
/// hand it to a queue. Anything heavier (OCR, DB writes) should run off
/// this thread so the message pump stays responsive.
/// </summary>
public sealed class ClipboardListener : IDisposable
{
    public event EventHandler? ClipboardChanged;

    private const string ClassName = "CpdbWin.ClipboardListener";
    private const uint WM_CLIPBOARDUPDATE = 0x031D;
    private const uint WM_QUIT = 0x0012;
    private static readonly IntPtr HWND_MESSAGE = new(-3);

    private Thread? _thread;
    private uint _threadId;
    private bool _disposed;
    // The Win32 WndProc gets stored as a function pointer in the WNDCLASS;
    // GC must not move or collect the delegate while the window exists.
    private Native.WndProc? _wndProc;

    public void Start()
    {
        if (_thread is not null) throw new InvalidOperationException("Listener already started");

        var ready = new ManualResetEventSlim(false);
        Exception? startError = null;

        _thread = new Thread(() =>
        {
            try { RunMessageLoop(ready); }
            catch (Exception ex) { startError = ex; ready.Set(); }
        })
        {
            IsBackground = true,
            Name = "CpdbClipboardListener",
        };
        _thread.Start();
        ready.Wait();

        if (startError is not null) throw startError;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        if (_threadId != 0)
            Native.PostThreadMessageW(_threadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
        _thread?.Join();
    }

    private void RunMessageLoop(ManualResetEventSlim ready)
    {
        _threadId = Native.GetCurrentThreadId();
        _wndProc = WndProc;

        var hInstance = Native.GetModuleHandleW(null);
        var wc = new Native.WNDCLASSEXW
        {
            cbSize       = (uint)Marshal.SizeOf<Native.WNDCLASSEXW>(),
            lpfnWndProc  = Marshal.GetFunctionPointerForDelegate(_wndProc),
            hInstance    = hInstance,
            lpszClassName = ClassName,
        };
        if (Native.RegisterClassExW(ref wc) == 0) ThrowLast(nameof(Native.RegisterClassExW));

        var hwnd = Native.CreateWindowExW(
            0, ClassName, ClassName, 0,
            0, 0, 0, 0,
            HWND_MESSAGE, IntPtr.Zero, hInstance, IntPtr.Zero);
        if (hwnd == IntPtr.Zero) ThrowLast(nameof(Native.CreateWindowExW));

        if (!Native.AddClipboardFormatListener(hwnd))
            ThrowLast(nameof(Native.AddClipboardFormatListener));

        ready.Set();

        while (Native.GetMessageW(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            Native.TranslateMessage(ref msg);
            Native.DispatchMessageW(ref msg);
        }

        Native.RemoveClipboardFormatListener(hwnd);
        Native.DestroyWindow(hwnd);
        Native.UnregisterClassW(ClassName, hInstance);
    }

    private IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_CLIPBOARDUPDATE)
        {
            // Swallow handler exceptions so a buggy subscriber can't kill
            // the message pump. The handler is responsible for its own
            // logging.
            try { ClipboardChanged?.Invoke(this, EventArgs.Empty); }
            catch { }
            return IntPtr.Zero;
        }
        return Native.DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    private static void ThrowLast(string what)
    {
        var err = Marshal.GetLastWin32Error();
        throw new InvalidOperationException($"{what} failed (Win32 {err})");
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

        [DllImport("user32.dll")]
        public static extern bool TranslateMessage(ref MSG lpMsg);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr DispatchMessageW(ref MSG lpMsg);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool PostThreadMessageW(uint idThread, uint Msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool AddClipboardFormatListener(IntPtr hwnd);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
    }
}
