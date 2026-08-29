using System.Text.Json;
using System.Text.Json.Serialization;

namespace CpdbWin.Core.Analysis;

/// <summary>
/// A single detected "data chip" — a structured signal pulled out of an
/// entry's text or image content (a date, an address, a phone number, a
/// URL, a shipment tracking number, a flight number, a money amount, or
/// generic barcode text) that the popup row renders as a small tappable
/// action affordance. Serialized as a JSON array into
/// <c>entries.chips_json</c> (v13_semantic_enrichment schema on Windows,
/// v12 on Mac — same column, same wire shape).
///
/// <para>
/// Windows port of <c>Sources/CpdbShared/Analysis/Chips.swift</c>.
/// Wire format is a plain JSON array of objects with three lowercase
/// single-letter keys — kept minimal so the column stays cheap on
/// every row read.
/// </para>
/// </summary>
public sealed class Chip : IEquatable<Chip>
{
    /// <summary>Chip-type tag — one of <see cref="ChipType"/>'s
    /// constants. Plain lowercase strings on the wire; readers should
    /// treat any unknown value as opaque (v3.3's QR pass adds
    /// <c>"text"</c> without a schema bump).</summary>
    [JsonPropertyName("t")]
    public string T { get; set; } = "";

    /// <summary>The raw value an action operates on (a URL string, a
    /// phone number, an ISO-8601 date, a tracking number, ...).</summary>
    [JsonPropertyName("v")]
    public string V { get; set; } = "";

    /// <summary>Human-readable label for the chip's face. Falls back to
    /// <see cref="V"/> when there's nothing shorter/prettier to show.</summary>
    [JsonPropertyName("s")]
    public string S { get; set; } = "";

    public Chip() { }

    public Chip(string t, string v, string s)
    {
        T = t;
        V = v;
        S = s;
    }

    public bool Equals(Chip? other)
        => other is not null && T == other.T && V == other.V && S == other.S;

    public override bool Equals(object? obj) => obj is Chip c && Equals(c);

    public override int GetHashCode() => HashCode.Combine(T, V, S);

    // ── JSON array helpers ─────────────────────────────────────────────

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        // Chip UI is not a security surface, but the column is dense
        // (one row per hit), so keep the payload tight.
        WriteIndented = false,
    };

    /// <summary>
    /// Decode a <c>chips_json</c> column value. Null / empty / corrupt
    /// JSON returns an empty list — a not-yet-scanned or malformed
    /// column value must never crash a row render. Mirrors Mac's
    /// <c>decodeArray</c>.
    /// </summary>
    public static List<Chip> DecodeArray(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return new List<Chip>();
        try
        {
            var parsed = JsonSerializer.Deserialize<List<Chip>>(json, JsonOpts);
            return parsed ?? new List<Chip>();
        }
        catch (JsonException)
        {
            return new List<Chip>();
        }
    }

    /// <summary>Encode an array of chips for the <c>chips_json</c>
    /// column. Empty array serialises as <c>"[]"</c>; on any encoder
    /// failure the fallback is also <c>"[]"</c> so a partially-
    /// constructed chip doesn't take the row's whole chip set down.</summary>
    public static string EncodeArray(IReadOnlyList<Chip> chips)
    {
        try
        {
            return JsonSerializer.Serialize(chips, JsonOpts);
        }
        catch
        {
            return "[]";
        }
    }

    /// <summary>
    /// Merge freshly detected chips into whatever's already stored for
    /// an entry, de-duplicating on <c>(t, v)</c> so re-running detection
    /// (a QR pass landing after a text pass on the same captioned image,
    /// a backfill re-scan) never doubles up a chip already recorded.
    /// Existing chips keep their original order; new ones append in
    /// detection order. Mirrors Mac's <c>merge(existingJson:adding:)</c>
    /// including the <c>nil</c> / <c>"[]"</c> equivalence (both start
    /// from an empty array).
    /// </summary>
    public static string Merge(string? existingJson, IReadOnlyList<Chip> newChips)
    {
        var result = DecodeArray(existingJson);
        var seen = new HashSet<string>(result.Select(DedupeKey), StringComparer.Ordinal);
        foreach (var chip in newChips)
        {
            var key = DedupeKey(chip);
            if (seen.Contains(key)) continue;
            seen.Add(key);
            result.Add(chip);
        }
        return EncodeArray(result);
    }

    /// <summary>NUL-separated <c>t</c>+<c>v</c> — the wire dedup key.
    /// Display string <c>s</c> intentionally not part of the key: a
    /// re-detected chip with a friendlier label shouldn't create a
    /// duplicate row.</summary>
    private static string DedupeKey(Chip chip) => chip.T + "\0" + chip.V;
}

/// <summary>Well-known chip-type tag constants. Not an enum: the wire
/// format is a plain lowercase string, and the column tolerates
/// unknown values (any reader should just skip them).</summary>
public static class ChipType
{
    public const string Date     = "date";
    public const string Address  = "address";
    public const string Phone    = "phone";
    public const string Url      = "url";
    public const string Tracking = "tracking";
    public const string Flight   = "flight";
    public const string Money    = "money";
    /// <summary>QR/barcode-only: a payload that isn't a recognizable
    /// URL or phone number. Ships alongside the QR-pass work
    /// (v1.44) — chips_json is an open JSON array, so this doesn't
    /// need a schema bump.</summary>
    public const string Text     = "text";
}
