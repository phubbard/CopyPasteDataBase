using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace CpdbWin.Core.Identity;

/// <summary>
/// Resolves the currently-focused window to the (bundle_id, name, exePath)
/// triple that <c>apps</c> rows want. Bundle id convention from
/// docs/schema.md §apps: <c>win.&lt;process-image-name-without-extension&gt;</c>,
/// lowercased. Name comes from the EXE's FileDescription if present,
/// otherwise the bare filename.
///
/// Uses PROCESS_QUERY_LIMITED_INFORMATION + QueryFullProcessImageName so it
/// keeps working against elevated processes; PROCESS_QUERY_INFORMATION
/// (what Process.MainModule wants) is rejected by UAC for many of them.
/// </summary>
public static class ForegroundApp
{
    public readonly record struct Info(string BundleId, string Name, string ExePath);

    public static Info? Detect()
    {
        var hwnd = Native.GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return null;

        Native.GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == 0) return null;

        var handle = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (handle == IntPtr.Zero) return null;
        try
        {
            var buf = new StringBuilder(1024);
            uint size = (uint)buf.Capacity;
            if (!Native.QueryFullProcessImageNameW(handle, 0, buf, ref size)) return null;
            return MakeInfo(buf.ToString(0, (int)size));
        }
        finally
        {
            Native.CloseHandle(handle);
        }
    }

    /// <summary>
    /// Pure derivation from an exe path. Exposed for tests and for callers
    /// that already have the path from another source (e.g., ETW, AppLocker).
    /// </summary>
    public static Info MakeInfo(string exePath)
    {
        var stem = Path.GetFileNameWithoutExtension(exePath);
        if (string.IsNullOrEmpty(stem)) stem = "unknown";
        var bundleId = "win." + stem.ToLowerInvariant();

        string name = stem;
        try
        {
            var v = FileVersionInfo.GetVersionInfo(exePath);
            if (!string.IsNullOrWhiteSpace(v.FileDescription))
                name = v.FileDescription!;
        }
        catch
        {
            // File missing / unreadable — bundle id is still useful.
        }

        return new Info(bundleId, name, exePath);
    }

    private static class Native
    {
        public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool QueryFullProcessImageNameW(IntPtr handle, uint flags, StringBuilder buf, ref uint size);
    }
}
