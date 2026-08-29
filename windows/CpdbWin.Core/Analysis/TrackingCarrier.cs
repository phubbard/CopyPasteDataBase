using System.Text.RegularExpressions;

namespace CpdbWin.Core.Analysis;

/// <summary>
/// Shipment-carrier detection for tracking-number chips. Windows port of
/// <c>Sources/CpdbShared/Analysis/TrackingCarrier.swift</c>. Regex-only —
/// no Luhn / MOD-10 check — because the file's contract is "usually
/// right, safe to be wrong". A false positive renders one extra chip;
/// the click drops the user on Google search for the number, which is
/// still useful even when the carrier guess was off.
///
/// <para>
/// Patterns iterated in most-to-least distinctive order (UPS first —
/// the <c>1Z</c> prefix is unmistakable — then USPS's specific
/// prefixed 22-digit shape, then FedEx's plain 12/15-digit run). The
/// FedEx pattern will happily match anything roughly the right
/// length, which is why the detector's caller runs a context-keyword
/// gate before non-UPS patterns.
/// </para>
/// </summary>
public enum TrackingCarrier
{
    Ups,
    Fedex,
    Usps,
}

public static class TrackingCarrierExtensions
{
    /// <summary>Human-readable label used in <see cref="Chip.S"/>.
    /// Kept short so the pill face stays compact.</summary>
    public static string DisplayName(this TrackingCarrier c) => c switch
    {
        TrackingCarrier.Ups   => "UPS",
        TrackingCarrier.Fedex => "FedEx",
        TrackingCarrier.Usps  => "USPS",
        _ => "",
    };

    /// <summary>
    /// The web tracking URL a chip click should launch. Values are
    /// URL-encoded via <see cref="Uri.EscapeDataString"/> so any stray
    /// spaces or punctuation don't corrupt the query. Mac ships the
    /// same three URLs; changing either here or there requires a
    /// coordinated update.
    /// </summary>
    /// <summary>Non-nullable overload — extension resolution on
    /// <see cref="TrackingCarrier"/>? doesn't auto-apply to
    /// <see cref="TrackingCarrier"/>, so this thin forwarder keeps
    /// call sites clean.</summary>
    public static string TrackingUrl(this TrackingCarrier carrier, string value)
        => TrackingUrl((TrackingCarrier?)carrier, value);

    public static string TrackingUrl(this TrackingCarrier? carrier, string value)
    {
        var v = Uri.EscapeDataString(value);
        return carrier switch
        {
            TrackingCarrier.Ups   => $"https://www.ups.com/track?tracknum={v}",
            TrackingCarrier.Fedex => $"https://www.fedex.com/fedextrack/?trknbr={v}",
            TrackingCarrier.Usps  => $"https://tools.usps.com/go/TrackConfirmAction?tLabels={v}",
            // Unrecognized carrier: fall back to a generic search. Same
            // fallback macOS ships; keeps the click from being a dead
            // end when the pattern-based guess didn't stick a carrier.
            _                     => $"https://www.google.com/search?q=track+package+{v}",
        };
    }
}

/// <summary>Pattern registry — kept public so
/// <c>TextChipDetector</c> can iterate the same list without
/// re-declaring it.</summary>
public static class TrackingPatterns
{
    /// <summary>UPS. Case-SENSITIVE by contract: uppercase <c>1Z</c>
    /// prefix + 16 uppercase alphanumerics. Always safe to run —
    /// the <c>1Z</c> prefix essentially never appears otherwise.</summary>
    public static readonly Regex Ups = new(
        @"\b1Z[0-9A-Z]{16}\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>USPS. 22-digit total with one of five known
    /// prefixes. Distinctive enough on its own, but the
    /// context-keyword gate still applies to catch stray 22-digit
    /// numeric IDs that aren't shipments.</summary>
    public static readonly Regex Usps = new(
        @"\b(?:94|93|92|82|20)\d{20}\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>FedEx. Any 12- or 15-digit run — deliberately lax.
    /// Only run behind the shipping-context gate; without it every
    /// phone extension or invoice number becomes a tracking chip.</summary>
    public static readonly Regex Fedex = new(
        @"\b(?:\d{15}|\d{12})\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>Iterated in order by <see cref="TryDetect"/>: first
    /// match wins.</summary>
    public static IReadOnlyList<(TrackingCarrier Carrier, Regex Pattern)> All { get; } = new[]
    {
        (TrackingCarrier.Ups,   Ups),
        (TrackingCarrier.Usps,  Usps),
        (TrackingCarrier.Fedex, Fedex),
    };

    /// <summary>Return the carrier whose pattern accepts
    /// <paramref name="value"/> as a whole match, or null when
    /// nothing does. Convenience wrapper around <see cref="All"/>.</summary>
    public static TrackingCarrier? TryDetect(string value)
    {
        foreach (var (carrier, pattern) in All)
            if (pattern.IsMatch(value)) return carrier;
        return null;
    }
}
