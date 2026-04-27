using CpdbWin.Core;
using Xunit;

namespace CpdbWin.Core.Tests;

public class CpdbVersionTests
{
    [Fact]
    public void Number_IsNonEmpty() =>
        Assert.False(string.IsNullOrWhiteSpace(CpdbVersion.Number));

    [Fact]
    public void Number_LooksLikeSemver()
    {
        // Stripped of any +commit-sha suffix.
        Assert.Matches(@"^\d+\.\d+\.\d+(?:[\.-][\w\.]+)?$", CpdbVersion.Number);
    }

    [Fact]
    public void Full_StartsWithDescription() =>
        Assert.StartsWith(CpdbVersion.Description + " ", CpdbVersion.Full);
}
