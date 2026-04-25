namespace CpdbWin.Core.Service;

/// <summary>
/// Renders a <see cref="HotkeyConfig"/> as the standard Windows-style
/// readable string (e.g. <c>Ctrl+Shift+V</c>) for display in the
/// preferences window and the tray tooltip.
/// </summary>
public static class HotkeyFormatter
{
    public static string Format(HotkeyConfig hotkey)
    {
        var parts = new List<string>(5);
        if ((hotkey.Modifiers & HotkeyModifiers.Control) != 0) parts.Add("Ctrl");
        if ((hotkey.Modifiers & HotkeyModifiers.Alt)     != 0) parts.Add("Alt");
        if ((hotkey.Modifiers & HotkeyModifiers.Shift)   != 0) parts.Add("Shift");
        if ((hotkey.Modifiers & HotkeyModifiers.Win)     != 0) parts.Add("Win");
        parts.Add(KeyName(hotkey.VirtualKey));
        return string.Join("+", parts);
    }

    private static string KeyName(uint vk) => vk switch
    {
        >= 0x30 and <= 0x39 => ((char)vk).ToString(),                // 0-9
        >= 0x41 and <= 0x5A => ((char)vk).ToString(),                // A-Z
        >= 0x70 and <= 0x7B => $"F{vk - 0x6F}",                      // F1..F12
        0x20 => "Space",
        0x09 => "Tab",
        0x0D => "Enter",
        0x1B => "Esc",
        0x08 => "Backspace",
        0x2E => "Delete",
        _    => $"VK_{vk:X2}",
    };
}
