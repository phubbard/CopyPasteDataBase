using System.Runtime.InteropServices;
using System.Text;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Writes to the system clipboard from a test process. Used to drive
/// ClipboardSnapshot / ClipboardListener round-trip tests; the production
/// path doesn't need a writer in v1.
/// </summary>
internal static class TestClipboardWriter
{
    private const uint CF_UNICODETEXT = 13;
    private const uint GHND = 0x0042; // GMEM_MOVEABLE | GMEM_ZEROINIT

    public static void SetUnicodeText(string text)
    {
        // CF_UNICODETEXT requires UTF-16 LE with a trailing \0 code unit;
        // the receiving side strips it.
        var bytes = Encoding.Unicode.GetBytes(text + "\0");

        OpenWithRetry();
        try
        {
            EmptyClipboard();

            var hMem = GlobalAlloc(GHND, (UIntPtr)(uint)bytes.Length);
            if (hMem == IntPtr.Zero) throw new InvalidOperationException("GlobalAlloc failed");

            var ptr = GlobalLock(hMem);
            if (ptr == IntPtr.Zero) throw new InvalidOperationException("GlobalLock failed");
            Marshal.Copy(bytes, 0, ptr, bytes.Length);
            GlobalUnlock(hMem);

            // SetClipboardData transfers ownership of hMem to the system; do not free.
            if (SetClipboardData(CF_UNICODETEXT, hMem) == IntPtr.Zero)
                throw new InvalidOperationException(
                    $"SetClipboardData failed (Win32 {Marshal.GetLastWin32Error()})");
        }
        finally
        {
            CloseClipboard();
        }
    }

    public static void Empty()
    {
        if (!OpenClipboard(IntPtr.Zero)) return;
        try { EmptyClipboard(); }
        finally { CloseClipboard(); }
    }

    private static void OpenWithRetry()
    {
        for (int i = 0; i < 5; i++)
        {
            if (OpenClipboard(IntPtr.Zero)) return;
            Thread.Sleep(30);
        }
        throw new InvalidOperationException(
            $"OpenClipboard failed (Win32 {Marshal.GetLastWin32Error()})");
    }

    [DllImport("user32.dll", SetLastError = true)] private static extern bool OpenClipboard(IntPtr hWnd);
    [DllImport("user32.dll")]                      private static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError = true)] private static extern bool EmptyClipboard();
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalLock(IntPtr hMem);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool   GlobalUnlock(IntPtr hMem);
}
