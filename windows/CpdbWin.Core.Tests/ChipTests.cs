using CpdbWin.Core.Analysis;
using Xunit;

namespace CpdbWin.Core.Tests;

public class ChipTests
{
    [Fact]
    public void DecodeArray_NullOrEmpty_ReturnsEmptyList()
    {
        Assert.Empty(Chip.DecodeArray(null));
        Assert.Empty(Chip.DecodeArray(""));
        Assert.Empty(Chip.DecodeArray("   "));
        // A row scanned once and found nothing still writes "[]"; the
        // decoder must not treat that as an error.
        Assert.Empty(Chip.DecodeArray("[]"));
    }

    [Fact]
    public void DecodeArray_CorruptJson_ReturnsEmptyListNotThrow()
    {
        // A stray write from a mid-crash or a manual DB edit must never
        // crash a row render. Contract mirrors Mac's decodeArray.
        Assert.Empty(Chip.DecodeArray("{not json"));
        Assert.Empty(Chip.DecodeArray("[{\"t\":"));
    }

    [Fact]
    public void EncodeDecode_RoundTrip()
    {
        var chips = new List<Chip>
        {
            new(ChipType.Url,      "https://example.com/x", "example.com"),
            new(ChipType.Phone,    "+15555550100",           "(555) 555-0100"),
            new(ChipType.Tracking, "1Z999AA10123456784",     "UPS: 1Z999AA10..."),
        };
        var json = Chip.EncodeArray(chips);
        // Sanity-check that the wire-format is the three tight
        // single-letter keys — a change here is a cross-platform
        // wire-format change (v13_semantic_enrichment).
        Assert.Contains("\"t\":", json);
        Assert.Contains("\"v\":", json);
        Assert.Contains("\"s\":", json);
        var round = Chip.DecodeArray(json);
        Assert.Equal(chips.Count, round.Count);
        for (int i = 0; i < chips.Count; i++) Assert.Equal(chips[i], round[i]);
    }

    [Fact]
    public void Merge_NullExisting_StartsFromEmpty()
    {
        var fresh = new List<Chip>
        {
            new(ChipType.Url, "https://x.com/", "x.com"),
        };
        var json = Chip.Merge(existingJson: null, newChips: fresh);
        Assert.Equal(fresh, Chip.DecodeArray(json));
    }

    [Fact]
    public void Merge_EmptyExisting_StartsFromEmpty()
    {
        // "[]" and null must both round-trip to the same result — the
        // sentinel distinction between "never scanned" and "scanned,
        // found nothing" lives in the caller (chips_json IS NULL vs
        // "[]"), not in Chip.Merge.
        var fresh = new List<Chip> { new(ChipType.Phone, "+15555550100", "555-0100") };
        var fromNull  = Chip.Merge(null, fresh);
        var fromEmpty = Chip.Merge("[]", fresh);
        Assert.Equal(Chip.DecodeArray(fromNull), Chip.DecodeArray(fromEmpty));
    }

    [Fact]
    public void Merge_DedupesByTypeAndValue()
    {
        var existing = Chip.EncodeArray(new[]
        {
            new Chip(ChipType.Url, "https://x.com/", "x.com"),
        });
        // Same t + v, different s — still a duplicate. New entry
        // dropped; existing s survives.
        var merged = Chip.Merge(existing, new[]
        {
            new Chip(ChipType.Url, "https://x.com/", "x.com (relabelled)"),
        });
        var decoded = Chip.DecodeArray(merged);
        Assert.Single(decoded);
        Assert.Equal("x.com", decoded[0].S);
    }

    [Fact]
    public void Merge_DifferentValuesKeepBoth()
    {
        // Same type, different values → both survive.
        var existing = Chip.EncodeArray(new[] { new Chip(ChipType.Url, "https://a.com/", "a.com") });
        var merged   = Chip.Merge(existing, new[] { new Chip(ChipType.Url, "https://b.com/", "b.com") });
        Assert.Equal(2, Chip.DecodeArray(merged).Count);
    }

    [Fact]
    public void Merge_PreservesExistingOrderAndAppendsNew()
    {
        var existing = Chip.EncodeArray(new[]
        {
            new Chip(ChipType.Url,      "https://a.com/", "a.com"),
            new Chip(ChipType.Phone,    "+15555550100",   "555-0100"),
        });
        var fresh = new[]
        {
            new Chip(ChipType.Tracking, "1Z999",          "UPS"),
            new Chip(ChipType.Url,      "https://a.com/", "a.com dup"),  // dedup
        };
        var decoded = Chip.DecodeArray(Chip.Merge(existing, fresh));
        Assert.Equal(3, decoded.Count);
        Assert.Equal("https://a.com/", decoded[0].V);
        Assert.Equal("+15555550100",   decoded[1].V);
        Assert.Equal("1Z999",          decoded[2].V);
    }
}
