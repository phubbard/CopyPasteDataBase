using CpdbWin.Core.Analysis;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Regex-behaviour tests for <see cref="TextChipDetector"/>. Pins the
/// reduced-fidelity contract for the Windows port (see the detector's
/// class-level doc) — anything Mac's NSDataDetector recognises that
/// Windows doesn't is expected to yield zero chips here.
/// </summary>
public class TextChipDetectorTests
{
    // ── URL ────────────────────────────────────────────────────────────

    [Fact]
    public void Detect_HttpsUrl_YieldsUrlChip()
    {
        var chips = TextChipDetector.Detect("See https://example.com/path for details.");
        var url = Assert.Single(chips, c => c.T == ChipType.Url);
        Assert.Equal("https://example.com/path", url.V);
        Assert.Equal("example.com/path", url.S);
    }

    [Fact]
    public void Detect_WwwHost_YieldsUrlChipWithHttpsScheme()
    {
        var chips = TextChipDetector.Detect("Visit www.example.com!");
        var url = Assert.Single(chips, c => c.T == ChipType.Url);
        Assert.StartsWith("https://", url.V);
        Assert.Contains("example.com", url.V);
    }

    [Fact]
    public void Detect_UrlWithTrailingPunctuation_TrimsPunctuation()
    {
        var chips = TextChipDetector.Detect("See https://example.com/x.");
        var url = Assert.Single(chips, c => c.T == ChipType.Url);
        Assert.EndsWith("/x", url.V);
    }

    [Fact]
    public void Detect_BareDomain_YieldsNoUrlChip_ReducedFidelityFromMac()
    {
        // Mac's NSDataDetector would autodetect "example.com" as a link.
        // Windows deliberately doesn't — the pattern requires http(s)://
        // or www. anchor to keep detection deterministic across locales.
        var chips = TextChipDetector.Detect("Visit example.com for info");
        Assert.DoesNotContain(chips, c => c.T == ChipType.Url);
    }

    // ── Phone ──────────────────────────────────────────────────────────

    [Fact]
    public void Detect_UsPhone_YieldsPhoneChip()
    {
        foreach (var candidate in new[]
        {
            "(555) 555-0100",
            "555-555-0100",
            "555.555.0100",
            "+1 555-555-0100",
            "+15555550100",
        })
        {
            var chips = TextChipDetector.Detect($"Call {candidate} today");
            Assert.Contains(chips, c => c.T == ChipType.Phone);
        }
    }

    // ── Date ───────────────────────────────────────────────────────────

    [Fact]
    public void Detect_IsoDate_YieldsDateChip()
    {
        var chips = TextChipDetector.Detect("Meeting on 2026-08-29 in Portland.");
        var date = Assert.Single(chips, c => c.T == ChipType.Date);
        Assert.Equal("2026-08-29", date.V);
    }

    [Fact]
    public void Detect_UsDate_YieldsDateChipInIsoV()
    {
        var chips = TextChipDetector.Detect("Delivery 3/15/2026.");
        var date = Assert.Single(chips, c => c.T == ChipType.Date);
        Assert.Equal("2026-03-15", date.V);
    }

    [Fact]
    public void Detect_MonthNameDate_YieldsDateChip()
    {
        var chips = TextChipDetector.Detect("Party January 5, 2026 at the park.");
        var date = Assert.Single(chips, c => c.T == ChipType.Date);
        Assert.Equal("2026-01-05", date.V);
    }

    [Fact]
    public void Detect_DateWithTime_IncludesDayOfWeekInDisplay()
    {
        var chips = TextChipDetector.Detect("Deadline 2026-08-29 at 3pm sharp");
        var date  = Assert.Single(chips, c => c.T == ChipType.Date);
        // Time-token nearby → display gets the weekday prefix.
        Assert.StartsWith("Sat", date.S);  // 2026-08-29 is a Saturday
    }

    // ── Tracking ───────────────────────────────────────────────────────

    [Fact]
    public void Detect_UpsTrackingNumber_YieldsTrackingChip_EvenWithoutShippingContext()
    {
        // UPS's 1Z prefix is distinctive enough that the context gate
        // doesn't apply — this is the one carrier where a bare
        // occurrence still becomes a chip.
        var chips = TextChipDetector.Detect("1Z999AA10123456784");
        var chip = Assert.Single(chips, c => c.T == ChipType.Tracking);
        Assert.Equal("1Z999AA10123456784", chip.V);
        Assert.StartsWith("UPS ", chip.S);
    }

    [Fact]
    public void Detect_FedexNumber_WithoutContext_YieldsNoChip()
    {
        // A bare 12-digit numeric run without any shipping keyword
        // must NOT become a tracking chip — otherwise every phone
        // extension / invoice ID would light up. Context gate lives
        // here to catch exactly this.
        var chips = TextChipDetector.Detect("Order id 123456789012");
        Assert.DoesNotContain(chips, c => c.T == ChipType.Tracking);
    }

    [Fact]
    public void Detect_FedexNumber_WithShippingContext_YieldsTrackingChip()
    {
        var chips = TextChipDetector.Detect("Your FedEx package tracking: 123456789012");
        var chip = Assert.Single(chips, c => c.T == ChipType.Tracking);
        Assert.Equal("123456789012", chip.V);
        Assert.StartsWith("FedEx ", chip.S);
    }

    [Fact]
    public void Detect_UspsNumber_WithShippingContext_YieldsTrackingChip()
    {
        // 22 digits, USPS prefix (94...).
        var chips = TextChipDetector.Detect("USPS tracking 9400111899223197123456");
        var chip = Assert.Single(chips, c => c.T == ChipType.Tracking);
        Assert.StartsWith("USPS ", chip.S);
    }

    // ── Truncation + boundary ─────────────────────────────────────────

    [Fact]
    public void Detect_LongText_TruncatesAtMaxScanLength()
    {
        // A chip past the 10k cap must NOT be detected. Guards against
        // a giant paste blowing up detection cost.
        var padding = new string('x', TextChipDetector.MaxScanLength);
        var text = padding + " 1Z999AA10123456784";  // UPS number beyond the cap
        var chips = TextChipDetector.Detect(text);
        Assert.DoesNotContain(chips, c => c.T == ChipType.Tracking);
    }

    [Fact]
    public void Detect_NullOrEmpty_YieldsNoChips()
    {
        Assert.Empty(TextChipDetector.Detect(null));
        Assert.Empty(TextChipDetector.Detect(""));
        Assert.Empty(TextChipDetector.Detect("   \n"));
    }

    // ── Address / flight / money — reduced-fidelity gap ───────────────

    [Fact]
    public void Detect_MacOnlyChipTypes_YieldNothing_ByDesign()
    {
        // These would fire on Mac via NSDataDetector; Windows opts out.
        // Test pins the contract so a future accidental regex doesn't
        // start emitting reduced-quality address/flight/money chips.
        var chips = TextChipDetector.Detect("Ship to 123 Main St, Springfield, IL 62701, flight UA 1234, $19.99");
        Assert.DoesNotContain(chips, c => c.T == ChipType.Address);
        Assert.DoesNotContain(chips, c => c.T == ChipType.Flight);
        Assert.DoesNotContain(chips, c => c.T == ChipType.Money);
    }

    // ── TrackingCarrier ────────────────────────────────────────────────

    [Fact]
    public void TrackingPatterns_DetectByCarrier()
    {
        Assert.Equal(TrackingCarrier.Ups,   TrackingPatterns.TryDetect("1Z999AA10123456784"));
        Assert.Equal(TrackingCarrier.Usps,  TrackingPatterns.TryDetect("9400111899223197123456"));
        Assert.Equal(TrackingCarrier.Fedex, TrackingPatterns.TryDetect("123456789012"));
        Assert.Null(TrackingPatterns.TryDetect("not-a-tracking-number"));
    }

    [Fact]
    public void TrackingUrl_UsesCorrectCarrierEndpoint()
    {
        Assert.Contains("ups.com",   TrackingCarrier.Ups.TrackingUrl("1Z999"));
        Assert.Contains("fedex.com", TrackingCarrier.Fedex.TrackingUrl("123456789012"));
        Assert.Contains("usps.com",  TrackingCarrier.Usps.TrackingUrl("9400"));
        // Null carrier → Google fallback so a wrong pattern-guess still
        // gives the user a useful click.
        Assert.Contains("google.com", ((TrackingCarrier?)null).TrackingUrl("mystery"));
    }
}
