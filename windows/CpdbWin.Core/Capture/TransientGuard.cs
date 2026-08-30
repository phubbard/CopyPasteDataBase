using System.Runtime.InteropServices;

namespace CpdbWin.Core.Capture;

/// <summary>
/// Whole-clipboard-capture skip for password managers and other apps
/// that flag their write as "don't store". Windows port of Mac's
/// <c>Sources/CpdbShared/Capture/TransientGuard.swift</c> (`concealedUTIs`
/// idea, but backed by Windows' own two format-name markers instead of
/// NSPasteboard UTIs).
///
/// <para>
/// <b>Markers recognised</b> (both are string-registered clipboard
/// format names, so they get registered once at first use and reused
/// via cached format IDs):
/// </para>
/// <list type="bullet">
///   <item><description><b><c>ExcludeClipboardContentFromMonitorProcessing</c></b>
///     — canary flag. Any app that publishes this alongside its
///     payload is asking the OS + third-party monitors not to store
///     the clip. Presence alone is enough to skip; no value read
///     required. Historically set by 1Password, Bitwarden, and other
///     credential managers.</description></item>
///   <item><description><b><c>CanIncludeInClipboardHistory</c></b>
///     — the modern Windows Clipboard History gate. Format holds a
///     4-byte DWORD; value 0 means "exclude from history". If the
///     format is present, we read the DWORD; if it's 0 (or the
///     read failed, which we treat as "err on the privacy side"),
///     skip. This is the flag Chromium sets on Incognito copies.</description></item>
/// </list>
///
/// <para>
/// <b>Enforcement seam</b>: <see cref="ClipboardSnapshot.Capture"/>
/// probes both markers inside its already-open clipboard window and
/// stores the outcome as <see cref="ClipboardSnapshot.HasTransientMarker"/>.
/// <see cref="ShouldReject"/> then just reads that bool — no second
/// <c>OpenClipboard</c> call. <see cref="Ingest.Ingestor.Ingest"/>
/// consults <see cref="ShouldReject"/> before hashing / DB work, so
/// every capture path (live watcher, importer, tests, future sync
/// pull) inherits the skip automatically. Mirrors the Swift Ingestor
/// wiring: guarded once at the choke-point, no per-caller opt-in.
/// </para>
///
/// <para>
/// <b>Fail-safe direction</b>: if the marker probe itself throws
/// (Win32 error registering a format, GlobalLock hiccup, etc.), we
/// return <c>false</c> — i.e. err toward capturing rather than
/// silently dropping. Password managers care about the marker
/// being present, and the two format names have shipped for years
/// without breaking; a persistent probe failure would be more likely
/// caused by us and shouldn't punish the user's clipboard history.
/// The one exception: if <c>CanIncludeInClipboardHistory</c> is
/// present but its DWORD read fails, we treat it as 0 (skip) — the
/// bit was intentionally set, we just can't confirm its value, and
/// respecting the intent beats respecting our uncertainty.
/// </para>
/// </summary>
public static class TransientGuard
{
    /// <summary>
    /// Canary format — any app publishing this alongside its payload
    /// intends the clip to be excluded from monitors. Presence alone
    /// = skip. Format name is the Microsoft-documented string per
    /// the "Clipboard formats" reference.
    /// </summary>
    public const string ExcludeFormatName = "ExcludeClipboardContentFromMonitorProcessing";

    /// <summary>
    /// Modern Windows Clipboard History opt-out. Format carries a
    /// 4-byte DWORD; 0 = exclude, non-zero = include. Present in
    /// Chromium Incognito copies + assorted password managers.
    /// </summary>
    public const string CanIncludeFormatName = "CanIncludeInClipboardHistory";

    /// <summary>
    /// Probe the two markers while the clipboard is already open.
    /// MUST be called from inside a <see cref="ClipboardSnapshot.Capture"/>
    /// -style <c>OpenClipboard</c> block — the availability + data
    /// reads are undefined without one. Returns <c>true</c> if the
    /// current clipboard content should be skipped.
    /// </summary>
    /// <remarks>
    /// The format-id registrations are cached in file-static fields;
    /// on first call they resolve to a stable <c>uint</c> that stays
    /// valid for the process lifetime (per Win32 docs).
    /// </remarks>
    public static bool ProbeOpenClipboard()
    {
        try
        {
            var cfExclude = GetOrRegisterFormat(ExcludeFormatName, ref _cfExclude);
            if (cfExclude != 0 && Native.IsClipboardFormatAvailable(cfExclude))
                return true;

            var cfCanInclude = GetOrRegisterFormat(CanIncludeFormatName, ref _cfCanInclude);
            if (cfCanInclude != 0 && Native.IsClipboardFormatAvailable(cfCanInclude))
                return ReadCanIncludeDword(cfCanInclude) == 0;

            return false;
        }
        catch
        {
            // Registration or IsClipboardFormatAvailable failed — err
            // toward capture rather than silent drop (see class doc).
            return false;
        }
    }

    /// <summary>
    /// Post-capture check the ingestor calls. Reads the bool set at
    /// probe time — no clipboard I/O here, so it's safe for any
    /// caller (tests, importers) that constructs a snapshot without
    /// the live clipboard being open.
    /// </summary>
    public static bool ShouldReject(ClipboardSnapshot snapshot) =>
        snapshot.HasTransientMarker;

    // Cached registered format IDs. 0 means "not yet registered
    // successfully"; we retry on the next call rather than caching a
    // failure state — registration failures should be transient.
    private static uint _cfExclude;
    private static uint _cfCanInclude;

    private static uint GetOrRegisterFormat(string name, ref uint cache)
    {
        if (cache != 0) return cache;
        cache = Native.RegisterClipboardFormatW(name);
        return cache;
    }

    private static uint ReadCanIncludeDword(uint format)
    {
        var h = Native.GetClipboardData(format);
        // Format is present per the caller's IsClipboardFormatAvailable
        // check, but the HGLOBAL can still fail to lock (rare). If we
        // can't read it, err on the privacy side: treat as 0 (skip).
        if (h == IntPtr.Zero) return 0;
        var ptr = Native.GlobalLock(h);
        if (ptr == IntPtr.Zero) return 0;
        try
        {
            var size = Native.GlobalSize(h).ToUInt64();
            if (size < 4) return 0;
            return unchecked((uint)Marshal.ReadInt32(ptr));
        }
        finally
        {
            Native.GlobalUnlock(h);
        }
    }

    private static class Native
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint RegisterClipboardFormatW(string lpszFormat);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool IsClipboardFormatAvailable(uint format);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr GetClipboardData(uint uFormat);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GlobalLock(IntPtr hMem);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GlobalUnlock(IntPtr hMem);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern UIntPtr GlobalSize(IntPtr hMem);
    }
}
