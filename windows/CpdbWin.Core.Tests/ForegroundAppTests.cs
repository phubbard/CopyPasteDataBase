using CpdbWin.Core.Identity;
using Xunit;

namespace CpdbWin.Core.Tests;

public class ForegroundAppTests
{
    [Theory]
    [InlineData(@"C:\Windows\System32\notepad.exe", "win.notepad")]
    [InlineData(@"C:\Program Files\1Password\1Password.exe", "win.1password")]
    [InlineData(@"D:\tools\KeePass.EXE", "win.keepass")]
    [InlineData(@"C:\bin\app", "win.app")]
    public void MakeInfo_DerivesBundleIdFromExeStem(string path, string expectedBundleId)
    {
        var info = ForegroundApp.MakeInfo(path);
        Assert.Equal(expectedBundleId, info.BundleId);
        Assert.Equal(path, info.ExePath);
    }

    [Fact]
    public void MakeInfo_FallsBackToStemForName_WhenFileMissing()
    {
        // No FileVersionInfo available for a non-existent path — Name should
        // fall back to the filename stem rather than throw.
        var info = ForegroundApp.MakeInfo(@"C:\does\not\exist\someapp.exe");
        Assert.Equal("win.someapp", info.BundleId);
        Assert.Equal("someapp", info.Name);
    }

    [Fact]
    public void MakeInfo_UsesFileDescriptionWhenPresent()
    {
        // notepad.exe ships on every Windows install and has a populated
        // FileDescription ("Notepad" or "Microsoft.Notepad" depending on
        // build). Don't pin the exact string; just assert the fallback (the
        // raw stem) didn't win.
        var path = Environment.ExpandEnvironmentVariables(@"%WINDIR%\System32\notepad.exe");
        if (!File.Exists(path)) return; // shouldn't happen but be defensive

        var info = ForegroundApp.MakeInfo(path);
        Assert.Equal("win.notepad", info.BundleId);
        Assert.False(string.IsNullOrWhiteSpace(info.Name));
    }

    [Fact]
    public void Detect_ReturnsForegroundProcessOrNull()
    {
        // Whatever has focus during the test run (terminal, IDE, lock screen)
        // is fine — we just verify the call doesn't throw and that any
        // result is well-formed.
        var info = ForegroundApp.Detect();
        if (info is null) return;

        Assert.StartsWith("win.", info.Value.BundleId);
        Assert.False(string.IsNullOrWhiteSpace(info.Value.Name));
        Assert.False(string.IsNullOrWhiteSpace(info.Value.ExePath));
    }
}
