using System.Runtime.InteropServices;
using System.Text;

namespace CpdbWin.Core.Capture;

/// <summary>
/// Writes a list of (uti, bytes) flavors back onto the system clipboard so
/// the user can paste a history entry into another app. v1 maps the
/// flavors cpdb actually stores:
/// <list type="bullet">
///   <item>public.utf8-plain-text → CF_UNICODETEXT</item>
///   <item>public.url             → CF_UNICODETEXT (most apps accept it)</item>
///   <item>public.png             → registered "PNG"</item>
///   <item>public.jpeg            → registered "JFIF"</item>
/// </list>
/// CF_HDROP / CF_HTML round-trips are intentionally deferred — the
/// receiving end of file copies wants real shell items, not just paths,
/// and CF_HTML re-emission needs the offset header rebuilt around the
/// fragment.
/// </summary>
public static class ClipboardWriter
{
    private const uint CF_UNICODETEXT = 13;
    private const uint GHND = 0x0042; // GMEM_MOVEABLE | GMEM_ZEROINIT

    /// <summary>
    /// Replace the clipboard contents with the given flavors. Throws
    /// <see cref="InvalidOperationException"/> if OpenClipboard fails after
    /// retry, or if any required Win32 step returns 0.
    /// </summary>
    public static void Write(IEnumerable<(string Uti, byte[] Data)> flavors)
    {
        OpenWithRetry();
        try
        {
            if (!Native.EmptyClipboard()) ThrowLast(nameof(Native.EmptyClipboard));
            foreach (var (uti, data) in flavors) WriteOne(uti, data);
        }
        finally
        {
            Native.CloseClipboard();
        }
    }

    public static void WriteText(string text) =>
        Write(new[] { ("public.utf8-plain-text", Encoding.UTF8.GetBytes(text)) });

    private static void WriteOne(string uti, byte[] data)
    {
        switch (uti)
        {
            case "public.utf8-plain-text":
            case "public.url":
                PutUnicodeText(Encoding.UTF8.GetString(data));
                break;
            case "public.png":
                PutRegistered("PNG", data);
                break;
            case "public.jpeg":
                PutRegistered("JFIF", data);
                break;
            // Other UTIs are silently skipped in v1.
        }
    }

    private static void PutUnicodeText(string text)
    {
        // CF_UNICODETEXT must end with a single NUL UTF-16 code unit.
        var bytes = Encoding.Unicode.GetBytes(text + "\0");
        var hMem = AllocCopy(bytes);
        if (Native.SetClipboardData(CF_UNICODETEXT, hMem) == IntPtr.Zero)
            ThrowLast(nameof(Native.SetClipboardData));
    }

    private static void PutRegistered(string formatName, byte[] data)
    {
        uint formatId = Native.RegisterClipboardFormatW(formatName);
        if (formatId == 0) ThrowLast(nameof(Native.RegisterClipboardFormatW));

        var hMem = AllocCopy(data);
        if (Native.SetClipboardData(formatId, hMem) == IntPtr.Zero)
            ThrowLast(nameof(Native.SetClipboardData));
    }

    private static IntPtr AllocCopy(byte[] data)
    {
        var hMem = Native.GlobalAlloc(GHND, (UIntPtr)(uint)data.Length);
        if (hMem == IntPtr.Zero) ThrowLast(nameof(Native.GlobalAlloc));
        var ptr = Native.GlobalLock(hMem);
        if (ptr == IntPtr.Zero) ThrowLast(nameof(Native.GlobalLock));
        Marshal.Copy(data, 0, ptr, data.Length);
        Native.GlobalUnlock(hMem);
        return hMem;
    }

    private static void OpenWithRetry()
    {
        for (int i = 0; i < 5; i++)
        {
            if (Native.OpenClipboard(IntPtr.Zero)) return;
            Thread.Sleep(30);
        }
        ThrowLast(nameof(Native.OpenClipboard));
    }

    private static void ThrowLast(string what)
    {
        var err = Marshal.GetLastWin32Error();
        throw new InvalidOperationException($"{what} failed (Win32 {err})");
    }

    private static class Native
    {
        [DllImport("user32.dll", SetLastError = true)] public static extern bool OpenClipboard(IntPtr hWnd);
        [DllImport("user32.dll")]                      public static extern bool CloseClipboard();
        [DllImport("user32.dll", SetLastError = true)] public static extern bool EmptyClipboard();
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint RegisterClipboardFormatW(string lpszFormat);

        [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GlobalLock(IntPtr hMem);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GlobalUnlock(IntPtr hMem);
    }
}
