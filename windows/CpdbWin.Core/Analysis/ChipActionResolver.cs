namespace CpdbWin.Core.Analysis;

/// <summary>
/// Turns a <see cref="Chip"/> into the <see cref="Uri"/> its click
/// should launch. Kept in its own file so the mapping is unit-testable
/// without a running UI. Contract:
///
/// <list type="table">
///   <item><term>url</term>    <description><c>chip.V</c> itself.</description></item>
///   <item><term>phone</term>  <description><c>tel:&lt;digits&gt;</c>.</description></item>
///   <item><term>tracking</term><description>Carrier-specific URL via
///     <see cref="TrackingCarrierExtensions.TrackingUrl"/>, with a
///     Google-search fallback when the pattern didn't match a known
///     carrier.</description></item>
///   <item><term>date</term>   <description>No launch — Windows doesn't
///     have a canonical "open in calendar" URI scheme that every user
///     will have wired. A future release may add <c>webcal:</c> /
///     Outlook interop; for now the chip is display-only.</description></item>
///   <item><term>text</term>   <description>QR/barcode payload that
///     wasn't a URL or phone — no default action. Chip still renders
///     for copy affordance (user can right-click).</description></item>
/// </list>
///
/// Returns null when the chip type has no meaningful action; the UI
/// surfaces a status note rather than launching a broken scheme.
/// </summary>
public static class ChipActionResolver
{
    public static Uri? ToUri(Chip chip)
    {
        switch (chip.T)
        {
            case ChipType.Url:
                return Uri.TryCreate(chip.V, UriKind.Absolute, out var u) ? u : null;

            case ChipType.Phone:
                // tel: accepts almost anything — the OS's phone/skype
                // handler is the one that parses. Strip whitespace so a
                // "(555) 555-0100" match doesn't confuse the URI parser.
                var digits = new string(chip.V.Where(c => !char.IsWhiteSpace(c)).ToArray());
                return Uri.TryCreate($"tel:{digits}", UriKind.Absolute, out var t) ? t : null;

            case ChipType.Tracking:
                // Re-detect the carrier so we pick the right URL even if
                // the chip's display string was manually altered
                // (defensive — the sweeper writes it and it round-trips
                // through JSON, so this is normally cheap).
                var carrier = TrackingPatterns.TryDetect(chip.V);
                return new Uri(carrier.TrackingUrl(chip.V));

            case ChipType.Date:
            case ChipType.Text:
            case ChipType.Address:
            case ChipType.Flight:
            case ChipType.Money:
            default:
                return null;
        }
    }
}
