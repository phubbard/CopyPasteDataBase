using System.Runtime.InteropServices;
using System.Text;

namespace CpdbWin.Core.Capture;

/// <summary>
/// One captured clipboard event, expressed as the ordered list of
/// <see cref="CanonicalHash.Flavor"/>s that survived translation. Feeds
/// straight into <see cref="CanonicalHash.Compute"/> for dedup-keying and
/// into the <c>entry_flavors</c> table for storage.
///
/// <para>
/// <see cref="HasTransientMarker"/> is set during <see cref="Capture"/>
/// while the clipboard is still open — see <see cref="TransientGuard"/>.
/// It defaults to <c>false</c> for the record-struct positional
/// constructor so tests / importers that build a snapshot without a
/// live clipboard aren't accidentally opting into a skip path.
/// </para>
/// </summary>
public readonly record struct ClipboardSnapshot(
    IReadOnlyList<CanonicalHash.Flavor> Flavors,
    bool HasTransientMarker = false)
{
    /// <summary>Legacy v1 (full-set) SHA-256. Kept for the rare caller
    /// that needs to compute v1 explicitly; production capture should
    /// use <see cref="ContentIdentityV2"/> so dedup converges with
    /// macOS / iOS on the same semantic identity.</summary>
    public byte[] ContentHash() =>
        CanonicalHash.Compute(new IReadOnlyList<CanonicalHash.Flavor>[] { Flavors });

    /// <summary>Canonical-hash v2 identity: returns the rung tag (stored
    /// in <c>entries.identity_tag</c>) and the 32-byte SHA-256 used as
    /// the dedup key. See <see cref="ContentIdentity"/> for the
    /// rung-chain spec and the shared cross-platform vectors.</summary>
    public (ContentIdentity.Tag Tag, byte[] Hash) ContentIdentityV2() =>
        ContentIdentity.Compute(Flavors);

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
            // Probe transient markers first — cheap (two format
            // lookups) and lets a password-manager clip short-circuit
            // the whole flavor decode. The check must live inside the
            // OpenClipboard window; the resulting bool is carried on
            // the snapshot so downstream callers don't need to re-open.
            var transient = TransientGuard.ProbeOpenClipboard();

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

                foreach (var t in UtiTranslator.TranslateMulti(format, name, raw))
                    flavors.Add(new CanonicalHash.Flavor(t.Uti, t.Data));
            }
            return new ClipboardSnapshot(flavors, transient);
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
