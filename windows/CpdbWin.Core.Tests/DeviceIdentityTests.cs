using CpdbWin.Core.Identity;
using Xunit;

namespace CpdbWin.Core.Tests;

public class DeviceIdentityTests
{
    [Fact]
    public void Read_ReturnsKindWinAndCurrentMachineName()
    {
        var info = DeviceIdentity.Read();

        Assert.Equal("win", info.Kind);
        Assert.Equal(Environment.MachineName, info.Name);
    }

    [Fact]
    public void Read_IdentifierIsNonEmpty()
    {
        var info = DeviceIdentity.Read();
        Assert.False(string.IsNullOrWhiteSpace(info.Identifier));
    }

    [Fact]
    public void Read_IsStableAcrossCalls()
    {
        // The whole point of using MachineGuid is per-install stability —
        // two calls in a row must produce the same identifier or dedup
        // across devices breaks.
        var a = DeviceIdentity.Read();
        var b = DeviceIdentity.Read();
        Assert.Equal(a, b);
    }

    [Fact]
    public void Read_IdentifierLooksLikeMachineGuid_WhenRegistryReadable()
    {
        // On any non-tampered Windows install, MachineGuid is a 36-char
        // GUID string. Tolerate the fallback shape for sandboxes.
        var info = DeviceIdentity.Read();
        var id = info.Identifier;
        var isGuid = Guid.TryParseExact(id, "D", out _);
        var isFallback = id.StartsWith("win-fallback-");
        Assert.True(isGuid || isFallback,
            $"identifier '{id}' is neither a GUID nor the fallback form");
    }
}
