using CpdbWin.Core.Analysis;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Pure-function coverage for the QR payload → chip mapper. Pinned
/// against the same allowlist + phone heuristic macOS uses, so a
/// change on either platform gets caught here.
/// </summary>
public class QrChipMapperTests
{
    [Fact]
    public void HttpsPayload_YieldsUrlChip_DisplayIsHost()
    {
        var chip = Assert.Single(QrChipMapper.Chips(new[] { "https://example.com/x" }));
        Assert.Equal(ChipType.Url, chip.T);
        Assert.Equal("https://example.com/x", chip.V);
        Assert.Equal("example.com", chip.S);
    }

    [Fact]
    public void HttpPayload_YieldsUrlChip()
    {
        var chip = Assert.Single(QrChipMapper.Chips(new[] { "http://example.org/" }));
        Assert.Equal(ChipType.Url, chip.T);
        Assert.Equal("example.org", chip.S);
    }

    [Fact]
    public void TelPayload_YieldsPhoneChipWithSchemeStripped()
    {
        var chip = Assert.Single(QrChipMapper.Chips(new[] { "tel:+15555550100" }));
        Assert.Equal(ChipType.Phone, chip.T);
        Assert.Equal("+15555550100", chip.V);
    }

    [Fact]
    public void MailtoPayload_YieldsUrlChip_KeepsFullPayload()
    {
        // mailto is in the allowlist; display keeps the full payload
        // rather than pulling a "host" (mailto has no meaningful host
        // component).
        var chip = Assert.Single(QrChipMapper.Chips(new[] { "mailto:hello@example.com" }));
        Assert.Equal(ChipType.Url, chip.T);
        Assert.Equal("mailto:hello@example.com", chip.V);
        Assert.Equal("mailto:hello@example.com", chip.S);
    }

    [Fact]
    public void UnrecognizedScheme_FallsThroughToText_NotUrl()
    {
        // The whole reason we have an allowlist: Uri.TryCreate accepts
        // "NOTE:call mom" as scheme=note, but there's no note: handler
        // registered on Windows, so a URL chip whose tap silently no-ops
        // is strictly worse than a text chip that at least copies.
        var chip = Assert.Single(QrChipMapper.Chips(new[] { "NOTE:call mom" }));
        Assert.Equal(ChipType.Text, chip.T);
        Assert.Equal("NOTE:call mom", chip.V);
    }

    [Fact]
    public void LabeledPayload_ParseableAsScheme_StillText()
    {
        var chip = Assert.Single(QrChipMapper.Chips(new[] { "SN:12345-ABC" }));
        Assert.Equal(ChipType.Text, chip.T);
    }

    [Fact]
    public void BarePhoneNumber_WithPunctuation_YieldsPhoneChip()
    {
        var chip = Assert.Single(QrChipMapper.Chips(new[] { "(555) 555-0100" }));
        Assert.Equal(ChipType.Phone, chip.T);
    }

    [Fact]
    public void PlainDigitRun_YieldsTextChip_NotPhone()
    {
        // The reason phone heuristic REQUIRES punctuation: a bare
        // 12-digit run is far more likely to be an EAN-13 / UPC or a
        // FedEx tracking number than a phone. Text-chip default lets
        // the user copy it and figure it out.
        var chip = Assert.Single(QrChipMapper.Chips(new[] { "4006381333931" }));
        Assert.Equal(ChipType.Text, chip.T);
    }

    [Fact]
    public void LongTextPayload_DisplayTruncatedAt60()
    {
        var payload = new string('x', 200);
        var chip = Assert.Single(QrChipMapper.Chips(new[] { payload }));
        Assert.Equal(ChipType.Text, chip.T);
        Assert.Equal(200, chip.V.Length);       // v preserves full payload
        Assert.Equal(61, chip.S.Length);        // display = 60 chars + ellipsis
        Assert.EndsWith("…", chip.S);
    }

    [Fact]
    public void EmptyOrWhitespacePayloads_Skipped()
    {
        Assert.Empty(QrChipMapper.Chips(new[] { "", "   ", "\n" }));
    }

    [Fact]
    public void DuplicatePayloads_DedupedOnRawValue()
    {
        var chips = QrChipMapper.Chips(new[]
        {
            "https://example.com/",
            "  https://example.com/  ",  // whitespace-trimmed to same payload
            "https://example.com/",
        });
        Assert.Single(chips);
    }

    [Fact]
    public void LooksLikePhoneNumber_HeuristicBoundaries()
    {
        // Under 7 digits: no.
        Assert.False(QrChipMapper.LooksLikePhoneNumber("(555) 12"));
        // Over 15 digits: no.
        Assert.False(QrChipMapper.LooksLikePhoneNumber("+1234567890123456"));
        // 7-15 digits + at least one punct char: yes.
        Assert.True(QrChipMapper.LooksLikePhoneNumber("+15555550100"));
        Assert.True(QrChipMapper.LooksLikePhoneNumber("555-1234567"));
        Assert.True(QrChipMapper.LooksLikePhoneNumber("555.555.0100"));
        // Digits only, no punctuation: no (EAN/tracking disambiguation).
        Assert.False(QrChipMapper.LooksLikePhoneNumber("15555550100"));
        // Non-phone-punctuation character: no.
        Assert.False(QrChipMapper.LooksLikePhoneNumber("555*555*0100"));
    }
}
