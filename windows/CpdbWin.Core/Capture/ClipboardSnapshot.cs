using System.Runtime.InteropServices;
using System.Text;

namespace CpdbWin.Core.Capture;

/// <summary>
/// One captured clipboard event, expressed as the ordered list of
/// <see cref="CanonicalHash.Flavor"/>s that survived translation. Feeds
/// straight into <see cref="CanonicalHash.Compute"/> for dedup-keying and
/// into the <c>entry_flavors</c> table for storage.
/// </summary>
public readonly record struct ClipboardSnapshot(IReadOnlyList<CanonicalHash.Flavor> Flavors)
{
    /// <summary>Order-independent SHA-256 over this snapshot's flavors.</summary>
    public byte[] ContentHash() =>
        CanonicalHash.Compute(new IReadOnlyList<CanonicalHash.Flavor>[] { Flavors });

    /// <summary>
    /// Read the system clipboard once. OpenClipboard can fail because
    /// another process holds it (Office, browser context menus, etc.); we
    /// retry a small number of times with a short backoff before giving up.
    /// Throws <see cref="ClipboardBusyException"/> if every retry fails.
    /// </summary>
    public static ClipboardSnapshot Capture(int retryAttempts = 5, int retryDelayMs = 30)
    {
        OpenWithRetry(retryAttempts, retryDelayMs);
        try
        {
            var flavors = new List<CanonicalHash.Flavor>();
            uint format = 0;
            while ((format = Native.EnumClipboardFormats(format)) != 0)
            {
                var raw = ReadFormat(format);
                if (raw is null) continue;

                string? name = null;
                if (format >= 0xC000)
                {
                    var buf = new StringBuilder(256);
                    int n = Native.GetClipboardFormatNameW(format, buf, buf.Capacity);
                    if (n > 0) name = buf.ToString();
                }

                var t = UtiTranslator.Translate(format, name, raw);
                if (t is null) continue;
                flavors.Add(new CanonicalHash.Flavor(t.Value.Uti, t.Value.Data));
            }
            return new ClipboardSnapshot(flavors);
        }
        finally
        {
            Native.CloseClipboard();
        }
    }

    private static void OpenWithRetry(int attempts, int delayMs)
    {
        for (int i = 0; i < attempts; i++)
        {
            if (Native.OpenClipboard(IntPtr.Zero)) return;
            if (i < attempts - 1) Thread.Sleep(delayMs);
        }
        var err = Marshal.GetLastWin32Error();
        throw new ClipboardBusyException(
            $"OpenClipboard failed after {attempts} attempts (Win32 {err}); " +
            "another process is holding the clipboard.");
    }

    private static byte[]? ReadFormat(uint format)
    {
        var h = Native.GetClipboardData(format);
        if (h == IntPtr.Zero) return null;

        var ptr = Native.GlobalLock(h);
        if (ptr == IntPtr.Zero) return null;
        try
        {
            ulong size = Native.GlobalSize(h).ToUInt64();
            if (size == 0) return Array.Empty<byte>();
            // Sanity cap before we even decide inline-vs-spillover: an app
            // claiming a multi-GB flavor is almost certainly broken or
            // adversarial. 64 MB is well above the largest screenshot we
            // expect and well below int32 bounds for Marshal.Copy.
            if (size > 64L * 1024 * 1024) return null;

            var buf = new byte[size];
            Marshal.Copy(ptr, buf, 0, (int)size);
            return buf;
        }
        finally
        {
            Native.GlobalUnlock(h);
        }
    }

    public sealed class ClipboardBusyException : Exception
    {
        public ClipboardBusyException(string message) : base(message) { }
    }

    private static class Native
    {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool OpenClipboard(IntPtr hWndNewOwner);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool CloseClipboard();

        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint EnumClipboardFormats(uint format);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr GetClipboardData(uint uFormat);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int GetClipboardFormatNameW(uint format, StringBuilder lpszFormatName, int cchMaxCount);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GlobalLock(IntPtr hMem);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GlobalUnlock(IntPtr hMem);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern UIntPtr GlobalSize(IntPtr hMem);
    }
}
