using System.Text;
using CpdbWin.Core.Capture;

namespace CpdbWin.Core.Ingest;

/// <summary>
/// Pure flavor-set → <c>entries.kind</c>. First match wins:
/// <list type="number">
/// <item>Substantive image flavor (≥ 1024 bytes) → image</item>
/// <item>public.url present → link</item>
/// <item>public.file-url present → file</item>
/// <item>color UTI present → color</item>
/// <item>plain text that <em>is</em> a single http(s):// URL → link</item>
/// <item>any plain-text flavor → text</item>
/// <item>else → other</item>
/// </list>
/// The substantive-image rule wins over both <c>public.url</c> and
/// <c>public.file-url</c>: browsers emit a source URL alongside "Copy
/// image", and screenshot tools like CleanShot publish a file-url
/// alongside the inline PNG. In both cases the image bytes are the
/// payload; the URL is breadcrumb metadata.
///
/// The 1024-byte image threshold catches the inverse — apps that
/// advertise empty image flavors alongside non-image content as
/// breadcrumbs, where the image flavor is metadata, not the payload.
///
/// <para>
/// The URL-shaped-plain-text rule (#5) catches captures where the
/// source app shipped only <c>public.utf8-plain-text</c> with a URL
/// in it — the Windows clipboard often does this for a "Copy address"
/// out of Edge / Chrome where the browser doesn't put a CF_HDROP /
/// public.url flavor. Without this, the link-metadata backfill query
/// (which gates on <c>kind='link'</c>) misses every such row. Mirrors
/// Mac <c>PasteboardSnapshot.kind</c>'s <c>looksLikeURL</c> check.
/// </para>
/// </summary>
public static class KindClassifier
{
    public const int MinImageBytes = 1024;

    /// <summary>
    /// Cap on the plain-text length we'll consider as a URL. Beyond this
    /// the row is almost certainly prose that happens to start with
    /// "http://" — keeping the limit prevents a 4 KB blob from being
    /// mis-classified.
    /// </summary>
    public const int MaxUrlLength = 2048;

    public static string Classify(IReadOnlyList<CanonicalHash.Flavor> flavors)
    {
        if (flavors.Any(IsSubstantiveImage))                     return "image";
        if (flavors.Any(f => f.Uti == "public.url"))             return "link";
        if (flavors.Any(f => f.Uti == "public.file-url"))        return "file";
        if (flavors.Any(IsColor))                                return "color";

        var plainText = FindPlainText(flavors);
        if (plainText is not null && LooksLikeUrl(plainText))    return "link";
        if (plainText is not null)                               return "text";
        return "other";
    }

    /// <summary>
    /// True iff <paramref name="s"/> trims to a single http(s):// URL
    /// with a non-null host and no embedded whitespace, length ≤
    /// <see cref="MaxUrlLength"/>. Conservative on purpose — the cost
    /// of a false positive is one wasted backfill request; the cost of
    /// a false negative is the URL never enriches.
    /// </summary>
    public static bool LooksLikeUrl(string s)
    {
        var trimmed = s.Trim();
        if (trimmed.Length == 0 || trimmed.Length > MaxUrlLength) return false;
        if (!(trimmed.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
           || trimmed.StartsWith("https://", StringComparison.OrdinalIgnoreCase)))
        {
            return false;
        }
        // Embedded whitespace = it's a sentence containing a URL, not a URL.
        foreach (var c in trimmed) if (char.IsWhiteSpace(c)) return false;
        return Uri.TryCreate(trimmed, UriKind.Absolute, out var url)
            && !string.IsNullOrEmpty(url.Host);
    }

    private static string? FindPlainText(IReadOnlyList<CanonicalHash.Flavor> flavors)
    {
        foreach (var f in flavors)
            if (f.Uti == "public.utf8-plain-text")
                return Encoding.UTF8.GetString(f.Data.Span);
        return null;
    }

    private static bool IsSubstantiveImage(CanonicalHash.Flavor f)
    {
        if (f.Data.Length < MinImageBytes) return false;
        var u = f.Uti;
        return u.StartsWith("public.png", StringComparison.Ordinal)
            || u.StartsWith("public.jpeg", StringComparison.Ordinal)
            || u.StartsWith("public.tiff", StringComparison.Ordinal)
            || u == "public.heic"
            || u == "public.heif"
            || u == "public.image";
    }

    private static bool IsColor(CanonicalHash.Flavor f) =>
        f.Uti is "com.apple.cocoa.pasteboard.color" or "public.color";
}
