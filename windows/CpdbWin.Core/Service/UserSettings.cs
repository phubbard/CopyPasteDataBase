using System.Text.Json;
using System.Text.Json.Serialization;

namespace CpdbWin.Core.Service;

/// <summary>
/// Win32 RegisterHotKey modifier flags. Public so the App layer can
/// build / display them without redeclaring the bitmask.
/// </summary>
public static class HotkeyModifiers
{
    public const uint Alt     = 0x0001;
    public const uint Control = 0x0002;
    public const uint Shift   = 0x0004;
    public const uint Win     = 0x0008;
    public const uint NoRepeat = 0x4000;
}

/// <summary>
/// One user-configurable global hotkey: a modifier bitmask plus a Win32
/// virtual-key code. <c>Default</c> matches the hard-coded Ctrl+Shift+V
/// the original release shipped with.
/// </summary>
public sealed record HotkeyConfig(uint Modifiers, uint VirtualKey)
{
    public static HotkeyConfig Default { get; } =
        new(HotkeyModifiers.Control | HotkeyModifiers.Shift, 0x56 /* V */);
}

/// <summary>
/// JSON-serialised user prefs at <c>%LOCALAPPDATA%\cpdb\settings.json</c>.
/// Loaded on app boot, mutated through the preferences window, persisted
/// on Save. Failures (malformed JSON, missing file, locked-down filesystem)
/// fall back to defaults — no crash on first run.
/// </summary>
public sealed class UserSettings
{
    [JsonPropertyName("hotkey")]
    public HotkeyConfig Hotkey { get; set; } = HotkeyConfig.Default;

    /// <summary>
    /// One-shot bookkeeping for the "default to run-at-boot" first-run
    /// behavior. False on a brand-new settings.json; the App layer flips it
    /// to true after enabling the HKCU\…\Run autostart entry once. Subsequent
    /// launches see <c>true</c> and skip the auto-enable, so a user who has
    /// since disabled autostart via the tray menu doesn't get it silently
    /// re-enabled on every startup.
    /// </summary>
    [JsonPropertyName("autoLaunchInitialized")]
    public bool AutoLaunchInitialized { get; set; } = false;

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public static UserSettings Load(string path)
    {
        try
        {
            if (!File.Exists(path)) return new UserSettings();
            var json = File.ReadAllText(path);
            return JsonSerializer.Deserialize<UserSettings>(json, JsonOpts) ?? new UserSettings();
        }
        catch
        {
            return new UserSettings();
        }
    }

    public void Save(string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(this, JsonOpts));
        }
        catch
        {
            // Best effort. Misconfigured filesystem just loses the change
            // until next save.
        }
    }
}
