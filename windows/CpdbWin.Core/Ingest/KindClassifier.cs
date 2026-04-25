using CpdbWin.Core.Capture;

namespace CpdbWin.Core.Ingest;

/// <summary>
/// Pure flavor-set → <c>entries.kind</c>. Rules from docs/schema.md
/// §Kind classification, first match wins:
/// <list type="number">
/// <item>public.url present → link</item>
/// <item>Substantive image flavor (≥ 1024 bytes) → image</item>
/// <item>public.file-url present → file</item>
/// <item>color UTI present → color</item>
/// <item>any plain-text flavor → text</item>
/// <item>else → other</item>
/// </list>
/// The 1024-byte image threshold matters because some apps advertise empty
/// image flavors as breadcrumbs alongside the real payload.
/// </summary>
public static class KindClassifier
{
    public const int MinImageBytes = 1024;

    public static string Classify(IReadOnlyList<CanonicalHash.Flavor> flavors)
    {
        if (flavors.Any(f => f.Uti == "public.url")) return "link";
        if (flavors.Any(IsSubstantiveImage))         return "image";
        if (flavors.Any(f => f.Uti == "public.file-url")) return "file";
        if (flavors.Any(IsColor))                    return "color";
        if (flavors.Any(f => f.Uti == "public.utf8-plain-text")) return "text";
        return "other";
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
