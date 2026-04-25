using System.Runtime.InteropServices;

namespace CpdbWin.App;

/// <summary>
/// Shell notification-area (tray) icon. WinUI 3 has no built-in tray
/// support, so we host one ourselves on a dedicated message-only window
/// running on a background thread (same pattern as ClipboardListener).
///
/// Left-click raises <see cref="Activated"/>. Right-click shows a small
/// context menu whose entries raise <see cref="ShowRequested"/> /
/// <see cref="QuitRequested"/> / <see cref="AutoLaunchToggled"/>.
/// </summary>
public sealed class TrayIcon : IDisposable
{
    public event Action? Activated;
    public event Action? ShowRequested;
    public event Action? QuitRequested;
    public event Action<bool>? AutoLaunchToggled;

    public string Tooltip { get; init; } = "cpdb-win";
    public bool AutoLaunchChecked { get; set; }

    private const string ClassName = "CpdbWin.TrayIcon";
    private const uint WM_USER     = 0x0400;
    private const uint WM_TRAYICON = WM_USER + 1;
    private const uint WM_QUIT     = 0x0012;
    private const uint WM_LBUTTONUP    = 0x0202;
    private const uint WM_LBUTTONDBLCLK = 0x0203;
    private const uint WM_RBUTTONUP    = 0x0205;
    private const uint WM_CONTEXTMENU  = 0x007B;
    private const uint NIM_ADD    = 0;
    private const uint NIM_DELETE = 2;
    private const uint NIF_MESSAGE = 0x01;
    private const uint NIF_ICON    = 0x02;
    private const uint NIF_TIP     = 0x04;
    private const uint MF_STRING    = 0x000;
    private const uint MF_SEPARATOR = 0x800;
    private const uint MF_CHECKED   = 0x008;
    private const uint TPM_RETURNCMD   = 0x0100;
    private const uint TPM_RIGHTBUTTON = 0x0002;
    private const ushort IDI_APPLICATION = 32512;

    private const int IDM_SHOW         = 1001;
    private const int IDM_AUTO_LAUNCH  = 1002;
    private const int IDM_QUIT         = 1003;

    private static readonly IntPtr HWND_MESSAGE = new(-3);

    private Thread? _thread;
    private uint _threadId;
    private IntPtr _hwnd;
    private NotifyIconData _data;
    private Native.WndProc? _wndProc;
    private bool _disposed;

    public void Start()
    {
        if (_thread is not null) throw new InvalidOperationException("Tray icon already started");

        var ready = new ManualResetEventSlim(false);
        Exception? startErr = null;
        _thread = new Thread(() =>
        {
            try { Run(ready); }
            catch (Exception ex) { startErr = ex; ready.Set(); }
        })
        {
            IsBackground = true,
            Name = "CpdbTrayIcon",
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
        _wndProc = WndProc;

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

        var hIcon = Native.LoadIcon(IntPtr.Zero, IDI_APPLICATION);

        _data = new NotifyIconData
        {
            cbSize           = (uint)Marshal.SizeOf<NotifyIconData>(),
            hWnd             = _hwnd,
            uID              = 1,
            uFlags           = NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage = WM_TRAYICON,
            hIcon            = hIcon,
            szTip            = Tooltip,
            szInfo           = string.Empty,
            szInfoTitle      = string.Empty,
        };
        if (!Native.Shell_NotifyIconW(NIM_ADD, ref _data))
            ThrowLast(nameof(Native.Shell_NotifyIconW));

        ready.Set();

        while (Native.GetMessageW(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            Native.TranslateMessage(ref msg);
            Native.DispatchMessageW(ref msg);
        }

        Native.Shell_NotifyIconW(NIM_DELETE, ref _data);
        Native.DestroyWindow(_hwnd);
        Native.UnregisterClassW(ClassName, hInstance);
    }

    private IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_TRAYICON)
        {
            uint mouseMsg = (uint)(lParam.ToInt64() & 0xFFFF);
            switch (mouseMsg)
            {
                case WM_LBUTTONUP:
                case WM_LBUTTONDBLCLK:
                    try { Activated?.Invoke(); } catch { }
                    break;
                case WM_RBUTTONUP:
                case WM_CONTEXTMENU:
                    ShowMenu();
                    break;
            }
            return IntPtr.Zero;
        }
        return Native.DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    private void ShowMenu()
    {
        var menu = Native.CreatePopupMenu();
        Native.AppendMenuW(menu, MF_STRING,                  (UIntPtr)IDM_SHOW,        "Show cpdb-win");
        Native.AppendMenuW(menu, MF_STRING | (AutoLaunchChecked ? MF_CHECKED : 0),
                                                              (UIntPtr)IDM_AUTO_LAUNCH, "Launch on login");
        Native.AppendMenuW(menu, MF_SEPARATOR,                UIntPtr.Zero,             null);
        Native.AppendMenuW(menu, MF_STRING,                  (UIntPtr)IDM_QUIT,        "Quit");

        Native.GetCursorPos(out var pt);
        // Required so the menu disappears when the user clicks elsewhere.
        Native.SetForegroundWindow(_hwnd);
        int cmd = Native.TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
            pt.X, pt.Y, 0, _hwnd, IntPtr.Zero);
        Native.DestroyMenu(menu);
        // Sentinel post — Win32 menu-dismissal quirk.
        Native.PostMessageW(_hwnd, 0, IntPtr.Zero, IntPtr.Zero);

        try
        {
            switch (cmd)
            {
                case IDM_SHOW:        ShowRequested?.Invoke(); break;
                case IDM_AUTO_LAUNCH: AutoLaunchToggled?.Invoke(!AutoLaunchChecked); break;
                case IDM_QUIT:        QuitRequested?.Invoke(); break;
            }
        }
        catch { }
    }

    private static void ThrowLast(string what)
    {
        var err = Marshal.GetLastWin32Error();
        throw new InvalidOperationException($"{what} failed (Win32 {err})");
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uTimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

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

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool PostMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr LoadIcon(IntPtr hInstance, IntPtr lpIconName);
        public static IntPtr LoadIcon(IntPtr hInstance, ushort id) =>
            LoadIcon(hInstance, (IntPtr)id);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool GetCursorPos(out POINT lpPoint);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr CreatePopupMenu();

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool AppendMenuW(IntPtr hMenu, uint uFlags, UIntPtr uIDNewItem, string? lpNewItem);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool DestroyMenu(IntPtr hMenu);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern int TrackPopupMenu(IntPtr hMenu, uint uFlags, int x, int y, int nReserved, IntPtr hWnd, IntPtr prcRect);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool Shell_NotifyIconW(uint dwMessage, ref NotifyIconData lpData);
    }
}
