using Microsoft.Win32;

namespace CpdbWin.App;

/// <summary>
/// Per-user autostart entry under
/// <c>HKCU\Software\Microsoft\Windows\CurrentVersion\Run</c>. Writes the
/// full path of the currently-running executable, so an installed binary
/// re-launches itself on every login. The HKCU scope means no admin
/// elevation needed.
///
/// <para>
/// <b>Only a Velopack-installed build may register autostart.</b> The
/// Run value is a single key shared by every build of cpdb-win on the
/// machine. Without this guard a dev / Debug / portable run (e.g. a
/// build straight out of <c>bin\Debug</c> during testing) would
/// overwrite the value with its own throwaway path and <i>hijack the
/// installed app's autostart</i> — the user reboots and the wrong,
/// stale binary comes up. Mirrors <c>UpdateService</c>'s
/// "only act on a real install" philosophy.
/// </para>
/// </summary>
public static class AutoLaunch
{
    private const string RunKey   = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "CpdbWin";

    /// <summary>
    /// True when the running process lives inside the Velopack install
    /// root (<c>%LOCALAPPDATA%\CpdbWin\</c>). Dev / Debug / portable
    /// runs return false and must not touch the shared Run key.
    /// </summary>
    public static bool IsManagedInstall()
    {
        var localAppData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData);
        return IsUnderInstallRoot(Environment.ProcessPath, localAppData);
    }

    /// <summary>
    /// Pure path predicate (testable without a real install): is
    /// <paramref name="exePath"/> inside
    /// <c>&lt;localAppData&gt;\CpdbWin\</c>? Velopack unpacks the app
    /// under that root (<c>…\CpdbWin\current\CpdbWin.App.exe</c>); a
    /// dev build runs from the repo's <c>bin\Debug</c> and is not.
    /// </summary>
    public static bool IsUnderInstallRoot(string? exePath, string localAppData)
    {
        if (string.IsNullOrEmpty(exePath) || string.IsNullOrEmpty(localAppData))
            return false;
        var root = Path.Combine(localAppData, "CpdbWin")
                   + Path.DirectorySeparatorChar;
        return Path.GetFullPath(exePath)
            .StartsWith(root, StringComparison.OrdinalIgnoreCase);
    }

    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string;
        }
        catch
        {
            return false;
        }
    }

    public static void SetEnabled(bool enabled)
    {
        try
        {
            // Never let a non-installed build write the shared Run key —
            // it would hijack the real install's autostart. Disabling
            // (delete) is still allowed from any build so a bad entry
            // can always be cleaned up.
            if (enabled && !IsManagedInstall()) return;

            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (enabled)
            {
                var exe = Environment.ProcessPath;
                if (string.IsNullOrEmpty(exe)) return;
                // Quote the path so a Program Files install with spaces still
                // resolves correctly when shell-launched.
                key!.SetValue(ValueName, $"\"{exe}\"", RegistryValueKind.String);
            }
            else
            {
                key!.DeleteValue(ValueName, throwOnMissingValue: false);
            }
        }
        catch
        {
            // Best effort — registry permissions, locked-down VDI, etc.
            // The toggle in the tray menu just won't stick.
        }
    }

    /// <summary>
    /// Self-heal a stale autostart entry. If we're a managed install AND
    /// the Run-key value exists but points at a path that isn't our own
    /// <see cref="Environment.ProcessPath"/>, overwrite it with our path.
    ///
    /// <para>
    /// Covers the bug discovered in v1.36.0 user diagnosis: a pre-v1.17.0
    /// dev / Debug build (before <see cref="IsManagedInstall"/> gating
    /// landed) wrote its own <c>bin\Debug\…</c> path into the shared Run
    /// key. The user reboots → Windows launches the stale dev EXE →
    /// dev EXE grabs the single-instance Mutex first → the installed
    /// Velopack build exits silently → auto-updates never apply (the
    /// updater code only runs when the installed app is live) → the
    /// user has been frozen on v1.11 for weeks without noticing.
    /// </para>
    ///
    /// <para>
    /// This routine takes ownership of the Run key on every managed-
    /// install launch: idempotent when the value already points at us;
    /// a self-correcting overwrite when it points anywhere else under
    /// our own <c>ValueName</c>. The non-managed-install case (dev /
    /// Debug) is a no-op so a dev build can't re-hijack.
    /// </para>
    /// </summary>
    public static void HealAutostartIfStale()
    {
        try
        {
            if (!IsManagedInstall()) return;
            var exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe)) return;

            using var read = Registry.CurrentUser.OpenSubKey(RunKey);
            if (read?.GetValue(ValueName) is not string current) return;  // no entry → nothing to heal

            // Strip surrounding quotes added by SetEnabled, then normalize
            // both sides so a casing diff doesn't trigger a spurious write.
            var stripped = current.Trim().Trim('"');
            if (string.Equals(
                    Path.GetFullPath(stripped),
                    Path.GetFullPath(exe),
                    StringComparison.OrdinalIgnoreCase))
                return;

            using var write = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            write?.SetValue(ValueName, $"\"{exe}\"", RegistryValueKind.String);
        }
        catch
        {
            // Best effort. If we can't write, the next boot will still
            // launch whatever the stale value points at; user can
            // manually fix via Preferences → Startup toggle.
        }
    }
}
