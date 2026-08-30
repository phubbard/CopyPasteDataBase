using System.Globalization;
using System.Text.RegularExpressions;

namespace CpdbWin.Core.Analysis;

/// <summary>
/// Regex-based detector for action chips in an entry's text. Windows
/// port of <c>Sources/CpdbShared/Analysis/TextChipDetector.swift</c>.
///
/// <para>
/// <b>Reduced fidelity vs the Mac:</b> Mac uses
/// <c>NSDataDetector</c> + <c>DataDetection</c> for natural-language
/// dates, addresses, phone-number normalization, transit information,
/// and money amounts. None of those have a cheap Windows equivalent
/// — <see cref="System.Globalization.CultureInfo"/> doesn't parse
/// "next Friday at 3pm", and there's no free "is this a price"
/// classifier. The Windows port ships the deterministic-regex subset:
/// </para>
///
/// <list type="table">
///   <item><term>date</term><description>numeric formats only
///     (<c>M/D/YYYY</c>, <c>YYYY-MM-DD</c>, <c>Month D[, YYYY]</c>)
///     — no NL parsing.</description></item>
///   <item><term>phone</term><description>US-ish
///     <c>(555) 555-0100</c> / <c>+1 555-555-0100</c> — no E.164
///     normalization; <c>v</c> is the raw match.</description></item>
///   <item><term>url</term><description>explicit scheme
///     (<c>http(s)://</c>) or <c>www.</c>-anchored bare host. Skips
///     scheme-less bare-domain detection that
///     <c>NSDataDetector</c> does.</description></item>
///   <item><term>tracking</term><description>UPS / USPS / FedEx — see
///     <see cref="TrackingPatterns"/>. Full-fidelity vs
///     Mac.</description></item>
///   <item><term>address / flight / money</term><description>Not
///     ported. Chips_json is an open JSON array — a Mac reader
///     encountering a Windows row just sees those types absent, not
///     malformed.</description></item>
/// </list>
///
/// <para>
/// Chips are returned in detection order with no cross-type overlap
/// suppression — <see cref="Chip.Merge"/> at the call site handles
/// deduplication.
/// </para>
/// </summary>
public static class TextChipDetector
{
    /// <summary>Hard character cap the detector processes. Same as
    /// macOS's <c>maxScanLength</c>; keeps the regex passes bounded
    /// even for a giant pasted document.</summary>
    public const int MaxScanLength = 10_000;

    /// <summary>Context-keyword gate applied before non-UPS tracking
    /// patterns run. Verbatim from macOS. Case-insensitive substring
    /// match — the surrounding text must mention shipping for a bare
    /// 12/15-digit run to become a FedEx tracking chip.</summary>
    private static readonly string[] ShippingContextKeywords =
    {
        "tracking", "track", "shipment", "shipped", "package", "parcel",
        "delivery", "fedex", "ups", "usps",
    };

    /// <summary>Case-insensitive time-of-day sniffer used to decide
    /// whether a date chip's display should include a clock. Mirrors
    /// macOS's <c>timeTokenPattern</c>.</summary>
    private static readonly Regex TimeTokenRegex = new(
        @"\b\d{1,2}(:\d{2})?\s*(am|pm)\b|\b\d{1,2}:\d{2}\b",
        RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    // ── Chip-type regexes ──────────────────────────────────────────────

    // http(s) or www. URL. Deliberately narrow to keep the port
    // deterministic across locales; `NSDataDetector`'s bare-domain
    // guess isn't reproducible.
    private static readonly Regex UrlRegex = new(
        @"\bhttps?://[^\s<>""']+|\bwww\.[a-z0-9][a-z0-9.\-]*\.[a-z]{2,}(?:/[^\s<>""']*)?",
        RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    // Loose US-shaped phone. Optional +1 / 1 prefix; optional
    // parentheses on the area code; . - or space separators between
    // groups. Not designed to also catch international numbers —
    // NSDataDetector on Mac handles those; Windows opts out to keep
    // the regex reliable.
    private static readonly Regex PhoneRegex = new(
        @"(?:\+?1[-. ]?)?\(?\d{3}\)?[-. ]?\d{3}[-. ]?\d{4}\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    // ISO 8601 date (year first) or US m/d/y[yy] with 1-2 digit
    // month/day. Loose on year width (2 or 4). Time-of-day is
    // independent (see TimeTokenRegex).
    private static readonly Regex IsoDateRegex = new(
        @"\b(\d{4})-(0?[1-9]|1[0-2])-(0?[1-9]|[12]\d|3[01])\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex UsDateRegex = new(
        @"\b(0?[1-9]|1[0-2])/(0?[1-9]|[12]\d|3[01])/(\d{2}|\d{4})\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    // "Month D[, YYYY]" e.g. "January 5" / "Jan 5, 2026". Month names
    // pinned to English — the surface locale of the whole app —
    // matching Windows' current search + preferences UX.
    private static readonly Regex MonthNameDateRegex = new(
        @"\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|"
      + @"Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"
      + @"\s+(0?[1-9]|[12]\d|3[01])(?:,\s*(\d{4}))?\b",
        RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    // ── Public API ─────────────────────────────────────────────────────

    /// <summary>
    /// Scan <paramref name="fullText"/> for action chips. Text longer
    /// than <see cref="MaxScanLength"/> is truncated. Returns chips
    /// in detection order (URL → phone → date → tracking). No dedup
    /// or overlap suppression — caller runs <see cref="Chip.Merge"/>.
    /// </summary>
    public static IReadOnlyList<Chip> Detect(string? fullText)
    {
        if (string.IsNullOrWhiteSpace(fullText)) return Array.Empty<Chip>();
        var text = fullText.Length > MaxScanLength
            ? fullText.Substring(0, MaxScanLength)
            : fullText;

        var chips = new List<Chip>();
        DetectUrls(text, chips);
        DetectPhones(text, chips);
        DetectDates(text, chips);
        DetectTracking(text, chips);
        return chips;
    }

    // ── Per-type detectors ────────────────────────────────────────────

    private static void DetectUrls(string text, List<Chip> chips)
    {
        foreach (Match m in UrlRegex.Matches(text))
        {
            // Trim trailing punctuation that regex greed swept up but
            // isn't part of the URL ("...", ")", ".", ",", ";").
            var raw = TrimTrailingPunct(m.Value);
            var v = raw.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? raw : "https://" + raw;
            // Uri.TryCreate is the sanity net — a match that regex
            // grabbed but the URI parser rejects doesn't become a
            // chip. Reduced surface vs NSDataDetector but doesn't
            // ship broken URLs.
            if (!Uri.TryCreate(v, UriKind.Absolute, out var uri)) continue;
            var display = uri.Host + (uri.AbsolutePath is "/" or "" ? "" : uri.AbsolutePath);
            chips.Add(new Chip(ChipType.Url, uri.AbsoluteUri, display));
        }
    }

    private static void DetectPhones(string text, List<Chip> chips)
    {
        foreach (Match m in PhoneRegex.Matches(text))
        {
            var raw = m.Value.Trim();
            if (raw.Length == 0) continue;
            chips.Add(new Chip(ChipType.Phone, raw, raw));
        }
    }

    private static void DetectDates(string text, List<Chip> chips)
    {
        // Track (chip.v, chip.s) tuples we've already emitted so
        // overlapping regexes (an ISO date is also parsable as a
        // month-name date? no, but the US and month-name shapes can
        // co-fire on rare inputs) don't produce duplicate chips.
        var seen = new HashSet<string>(StringComparer.Ordinal);
        void Emit(string v, string s)
        {
            var key = v + "\0" + s;
            if (seen.Add(key)) chips.Add(new Chip(ChipType.Date, v, s));
        }

        foreach (Match m in IsoDateRegex.Matches(text))
        {
            if (!DateTime.TryParseExact(m.Value, "yyyy-M-d",
                    CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt)) continue;
            EmitDated(dt, m, text, Emit);
        }
        foreach (Match m in UsDateRegex.Matches(text))
        {
            var year = m.Groups[3].Value.Length == 2 ? "20" + m.Groups[3].Value : m.Groups[3].Value;
            var normalized = $"{year}-{m.Groups[1].Value.PadLeft(2, '0')}-{m.Groups[2].Value.PadLeft(2, '0')}";
            if (!DateTime.TryParseExact(normalized, "yyyy-MM-dd",
                    CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt)) continue;
            EmitDated(dt, m, text, Emit);
        }
        foreach (Match m in MonthNameDateRegex.Matches(text))
        {
            var day = m.Groups[1].Value;
            var year = m.Groups[2].Success ? m.Groups[2].Value : DateTime.UtcNow.Year.ToString(CultureInfo.InvariantCulture);
            // Use the full match text for a permissive parse — culture
            // invariant tolerates "Jan 5" and "January 5, 2026" alike.
            if (!DateTime.TryParse($"{m.Value.Trim()}, {year}", CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeLocal, out var dt))
            {
                // Fall back to constructed date if the free-form parse balked.
                var monthName = m.Value.Substring(0, m.Value.IndexOf(' '));
                if (!DateTime.TryParseExact($"{monthName} {day} {year}", "MMMM d yyyy",
                        CultureInfo.InvariantCulture, DateTimeStyles.None, out dt) &&
                    !DateTime.TryParseExact($"{monthName} {day} {year}", "MMM d yyyy",
                        CultureInfo.InvariantCulture, DateTimeStyles.None, out dt))
                    continue;
            }
            EmitDated(dt, m, text, Emit);
        }
    }

    private static void EmitDated(DateTime dt, Match m, string text, Action<string, string> emit)
    {
        // ISO 8601 date for the v (wire) field; localized medium form
        // for the s (display) field. Time detection is a heuristic:
        // if any time-of-day token appears within 30 chars of the
        // date match, we assume the date "has a time" and include the
        // day-of-week + short-form clock in the display string.
        int windowStart = Math.Max(0, m.Index - 30);
        int windowEnd   = Math.Min(text.Length, m.Index + m.Length + 30);
        var window = text.Substring(windowStart, windowEnd - windowStart);
        var hasTime = TimeTokenRegex.IsMatch(window);
        var v = dt.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var s = hasTime
            ? dt.ToString("ddd, MMM d, yyyy", CultureInfo.InvariantCulture)
            : dt.ToString("MMM d, yyyy",       CultureInfo.InvariantCulture);
        emit(v, s);
    }

    private static void DetectTracking(string text, List<Chip> chips)
    {
        // UPS pattern is distinctive enough (1Z prefix) to run without
        // the context gate. Non-UPS patterns are gated because their
        // 12/15/22-digit shapes match all sorts of numeric IDs that
        // aren't shipments.
        AddTrackingMatches(text, TrackingCarrier.Ups, TrackingPatterns.Ups, chips);
        if (!TextMentionsShipping(text)) return;
        AddTrackingMatches(text, TrackingCarrier.Usps,  TrackingPatterns.Usps,  chips);
        AddTrackingMatches(text, TrackingCarrier.Fedex, TrackingPatterns.Fedex, chips);
    }

    private static void AddTrackingMatches(string text, TrackingCarrier carrier, Regex pattern, List<Chip> chips)
    {
        foreach (Match m in pattern.Matches(text))
        {
            var value = m.Value;
            // Per-value dedup within tracking so two carriers don't
            // both claim the same literal number. The two-pass merge
            // in Chip.Merge would catch it anyway, but keeping it
            // local matches Mac's semantics.
            if (chips.Any(c => c.T == ChipType.Tracking && c.V == value)) continue;
            chips.Add(new Chip(ChipType.Tracking, value, $"{carrier.DisplayName()} {value}"));
        }
    }

    private static bool TextMentionsShipping(string text)
    {
        var lower = text.ToLowerInvariant();
        foreach (var kw in ShippingContextKeywords)
            if (lower.Contains(kw, StringComparison.Ordinal)) return true;
        return false;
    }

    private static string TrimTrailingPunct(string s)
    {
        int end = s.Length;
        while (end > 0)
        {
            char c = s[end - 1];
            if (c == '.' || c == ',' || c == ';' || c == ')' || c == ']' || c == '!' || c == '?') end--;
            else break;
        }
        return s.Substring(0, end);
    }
}
