using CpdbWin.Core.Analysis;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Pure-function coverage for the chip → URI resolver used by the row-
/// template chip pills. Every chip type gets a pinned expectation so a
/// mis-map (wrong scheme, wrong carrier) is caught at test time rather
/// than user-report time.
/// </summary>
public class ChipActionResolverTests
{
    [Fact]
    public void Url_ReturnsAbsoluteUri()
    {
        var uri = ChipActionResolver.ToUri(new Chip(ChipType.Url, "https://example.com/x", "example.com/x"));
        Assert.NotNull(uri);
        Assert.Equal("https://example.com/x", uri!.AbsoluteUri);
    }

    [Fact]
    public void Url_MalformedValue_ReturnsNull()
    {
        Assert.Null(ChipActionResolver.ToUri(new Chip(ChipType.Url, "not a url at all", "not a url")));
    }

    [Fact]
    public void Phone_StripsWhitespace_YieldsTelUri()
    {
        var uri = ChipActionResolver.ToUri(new Chip(ChipType.Phone, "(555) 555-0100", "(555) 555-0100"));
        Assert.NotNull(uri);
        Assert.Equal("tel", uri!.Scheme);
        Assert.DoesNotContain(" ", uri.OriginalString);
    }

    [Fact]
    public void Tracking_UpsNumber_YieldsUpsUrl()
    {
        var uri = ChipActionResolver.ToUri(new Chip(ChipType.Tracking, "1Z999AA10123456784", "UPS 1Z999AA10..."));
        Assert.NotNull(uri);
        Assert.Contains("ups.com", uri!.Host);
        Assert.Contains("1Z999AA10123456784", uri.Query);
    }

    [Fact]
    public void Tracking_UspsNumber_YieldsUspsUrl()
    {
        var uri = ChipActionResolver.ToUri(new Chip(ChipType.Tracking, "9400111899223197123456", "USPS 9400..."));
        Assert.NotNull(uri);
        Assert.Contains("usps.com", uri!.Host);
    }

    [Fact]
    public void Tracking_FedexNumber_YieldsFedexUrl()
    {
        var uri = ChipActionResolver.ToUri(new Chip(ChipType.Tracking, "123456789012", "FedEx 123..."));
        Assert.NotNull(uri);
        Assert.Contains("fedex.com", uri!.Host);
    }

    [Fact]
    public void Tracking_UnknownCarrier_FallsBackToGoogleSearch()
    {
        var uri = ChipActionResolver.ToUri(new Chip(ChipType.Tracking, "mystery-number", "Mystery"));
        Assert.NotNull(uri);
        Assert.Contains("google.com", uri!.Host);
    }

    [Fact]
    public void Date_YieldsNoUri_ByDesign()
    {
        Assert.Null(ChipActionResolver.ToUri(new Chip(ChipType.Date, "2026-08-29", "Aug 29, 2026")));
    }

    [Fact]
    public void ReducedFidelityTypes_YieldNoUri()
    {
        Assert.Null(ChipActionResolver.ToUri(new Chip(ChipType.Address, "1600 Pennsylvania Ave", "1600 Pennsylvania Ave")));
        Assert.Null(ChipActionResolver.ToUri(new Chip(ChipType.Flight,  "UA1234",                "UA 1234")));
        Assert.Null(ChipActionResolver.ToUri(new Chip(ChipType.Money,   "$19.99",                "$19.99")));
        Assert.Null(ChipActionResolver.ToUri(new Chip(ChipType.Text,    "opaque payload",        "opaque payload")));
    }
}
