using Microsoft.Win32;

namespace CpdbWin.App;

/// <summary>
/// Per-user autostart entry under
/// <c>HKCU\Software\Microsoft\Windows\CurrentVersion\Run</c>. Writes the
/// full path of the currently-running executable, so an installed binary
/// re-launches itself on every login. The HKCU scope means no admin
/// elevation needed.
/// </summary>
public static class AutoLaunch
{
    private const string RunKey   = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "CpdbWin";

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
}
