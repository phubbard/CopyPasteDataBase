using CpdbWin.Core.Service;
using Xunit;

namespace CpdbWin.Core.Tests;

public class UserSettingsTests : IDisposable
{
    private readonly string _path;

    public UserSettingsTests()
    {
        _path = Path.Combine(Path.GetTempPath(),
            $"cpdb-settings-{Guid.NewGuid():N}.json");
    }

    public void Dispose()
    {
        if (File.Exists(_path)) File.Delete(_path);
    }

    [Fact]
    public void Load_MissingFile_ReturnsDefaults()
    {
        var settings = UserSettings.Load(_path);
        Assert.Equal(HotkeyConfig.Default, settings.Hotkey);
    }

    [Fact]
    public void Load_MalformedJson_ReturnsDefaults()
    {
        File.WriteAllText(_path, "{ this is not json");
        var settings = UserSettings.Load(_path);
        Assert.Equal(HotkeyConfig.Default, settings.Hotkey);
    }

    [Fact]
    public void Save_RoundTripsThroughLoad()
    {
        var s = new UserSettings
        {
            Hotkey = new HotkeyConfig(
                HotkeyModifiers.Control | HotkeyModifiers.Alt,
                0x70 /* F1 */),
        };
        s.Save(_path);

        var loaded = UserSettings.Load(_path);
        Assert.Equal(s.Hotkey, loaded.Hotkey);
    }

    [Fact]
    public void Save_CreatesDirectoryIfMissing()
    {
        var nested = Path.Combine(Path.GetTempPath(),
            $"cpdb-settings-dir-{Guid.NewGuid():N}", "settings.json");
        try
        {
            new UserSettings().Save(nested);
            Assert.True(File.Exists(nested));
        }
        finally
        {
            try { Directory.Delete(Path.GetDirectoryName(nested)!, true); } catch { }
        }
    }
}

public class HotkeyFormatterTests
{
    [Fact]
    public void Format_DefaultIsCtrlShiftV() =>
        Assert.Equal("Ctrl+Shift+V", HotkeyFormatter.Format(HotkeyConfig.Default));

    [Fact]
    public void Format_AllModifiersInOrder() =>
        Assert.Equal("Ctrl+Alt+Shift+Win+A",
            HotkeyFormatter.Format(new HotkeyConfig(
                HotkeyModifiers.Control | HotkeyModifiers.Alt
                | HotkeyModifiers.Shift | HotkeyModifiers.Win,
                0x41 /* A */)));

    [Theory]
    [InlineData(0x30, "0")]
    [InlineData(0x39, "9")]
    [InlineData(0x41, "A")]
    [InlineData(0x5A, "Z")]
    [InlineData(0x70, "F1")]
    [InlineData(0x7B, "F12")]
    [InlineData(0x20, "Space")]
    [InlineData(0x1B, "Esc")]
    public void Format_NamesCommonKeys(uint vk, string expected) =>
        Assert.EndsWith(expected,
            HotkeyFormatter.Format(new HotkeyConfig(HotkeyModifiers.Control, vk)));
}
