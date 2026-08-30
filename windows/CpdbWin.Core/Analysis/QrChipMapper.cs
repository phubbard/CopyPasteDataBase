namespace CpdbWin.Core.Analysis;

/// <summary>
/// Turn decoded QR / barcode payload strings from <see cref="QrDecoder"/>
/// into <see cref="Chip"/>s. Windows port of macOS's
/// <c>QRChipMapper.swift</c> — same allowlist, same phone-number
/// heuristic, same fall-through-to-text default.
///
/// <para>
/// <b>Why a scheme allowlist</b>: <see cref="Uri.TryCreate"/> is lenient
/// enough to hand back a non-null scheme for plain key/value or labeled
/// text that was never meant as a URI (<c>"NOTE: call mom"</c>,
/// <c>"SN:12345-ABC"</c>). Accepting <em>any</em> parseable scheme would
/// misclassify a QR-encoded serial number as a URL chip whose tap
/// silently no-ops (Windows Launcher on a scheme with no handler)
/// instead of the generic text chip's copy-to-clipboard, which is the
/// one useful affordance that payload class actually has.
/// </para>
///
/// <para>
/// <b>Why the phone-number heuristic requires punctuation</b>: ZXing
/// decodes many symbologies, not just QR — a retail EAN-13 / UPC-A
/// barcode (<c>"4006381333931"</c>) or a bare 12-digit tracking number
/// is only digits and would otherwise satisfy the same 7-15-digit
/// window, misclassifying as a tap-to-call phone chip. Punctuation is
/// the only remaining signal that this payload was actually formatted
/// as a phone number rather than a plain digit run.
/// </para>
/// </summary>
public static class QrChipMapper
{
    /// <summary>Schemes worth treating as "this payload is a URL".
    /// Deliberately closed rather than "any real scheme"; see class
    /// doc. <c>tel</c> is handled separately before this set is
    /// consulted. Same allowlist as macOS's <c>recognizedURLSchemes</c>.</summary>
    private static readonly HashSet<string> RecognizedUrlSchemes = new(StringComparer.OrdinalIgnoreCase)
    {
        "http", "https", "mailto", "sms", "smsto", "geo", "wifi", "ftp",
    };

    /// <summary>Map a list of raw QR/barcode payloads into chips.
    /// Duplicates (on the trimmed raw payload) are dropped so a
    /// symbology that ZXing found twice for the same code doesn't
    /// double up. Whitespace-only payloads are skipped.</summary>
    public static IReadOnlyList<Chip> Chips(IReadOnlyList<string> payloads)
    {
        var chips = new List<Chip>(payloads.Count);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var raw in payloads)
        {
            var payload = raw?.Trim() ?? "";
            if (payload.Length == 0) continue;
            if (!seen.Add(payload)) continue;
            chips.Add(ForPayload(payload));
        }
        return chips;
    }

    private static Chip ForPayload(string payload)
    {
        // First: parse as URI + inspect scheme against the allowlist.
        if (Uri.TryCreate(payload, UriKind.Absolute, out var uri) && !string.IsNullOrEmpty(uri.Scheme))
        {
            var scheme = uri.Scheme.ToLowerInvariant();
            if (scheme == "tel")
            {
                // Strip the tel: prefix; the number is what the chip
                // click hands to the OS dialer.
                var number = payload.Substring(scheme.Length + 1);
                return new Chip(ChipType.Phone, number, number);
            }
            if (RecognizedUrlSchemes.Contains(scheme))
            {
                var display = (scheme == "http" || scheme == "https")
                    ? (string.IsNullOrEmpty(uri.Host) ? payload : uri.Host)
                    : payload;
                return new Chip(ChipType.Url, payload, display);
            }
            // Parsed with an unrecognized scheme — fall through to
            // the phone / text checks (see class doc for the
            // Uri.TryCreate leniency defense).
        }

        if (LooksLikePhoneNumber(payload))
            return new Chip(ChipType.Phone, payload, payload);

        // Text chip: truncate display at 60 chars so a giant QR
        // payload (Wi-Fi config, vCard, JSON blob) doesn't blow up
        // the row.
        var displayText = payload.Length > 60 ? payload.Substring(0, 60) + "…" : payload;
        return new Chip(ChipType.Text, payload, displayText);
    }

    /// <summary>Conservative bare-phone-number sniff. Requires:
    ///   (a) 7-15 digits total,
    ///   (b) only digits + <c>+-().  </c> characters,
    ///   (c) at least one non-digit phone-punctuation character —
    ///       the discriminator vs a plain digit run (EAN barcode,
    ///       12-digit tracking number).
    /// </summary>
    internal static bool LooksLikePhoneNumber(string s)
    {
        int digitCount = 0;
        bool hasPunct = false;
        foreach (var c in s)
        {
            if (char.IsDigit(c)) { digitCount++; continue; }
            if (c == '+' || c == '-' || c == '(' || c == ')' || c == '.' || c == ' ') { hasPunct = true; continue; }
            // Any other character disqualifies immediately.
            return false;
        }
        if (digitCount < 7 || digitCount > 15) return false;
        return hasPunct;
    }
}
