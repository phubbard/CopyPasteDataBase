using System.Text;
using CpdbWin.Core.Capture;

namespace CpdbWin.Core.Ingest;

/// <summary>
/// Derives <c>entries.title</c> and <c>entries.text_preview</c> from a
/// flavor list. Rules from docs/schema.md §Title derivation and §Text
/// preview:
/// <list type="bullet">
/// <item>title: first non-empty line of plain text, trimmed, ≤ 200 chars;
///       else public.file-url's filename; else null.</item>
/// <item>text_preview: full plain text truncated to 2048 chars; else null.
///       Never falls back to file URLs.</item>
/// </list>
/// </summary>
public static class TitleAndPreview
{
    public const int TitleMax = 200;
    public const int PreviewMax = 2048;

    public static (string? Title, string? TextPreview) Derive(IReadOnlyList<CanonicalHash.Flavor> flavors)
    {
        string? plain = null;
        foreach (var f in flavors)
        {
            if (f.Uti == "public.utf8-plain-text")
            {
                plain = Encoding.UTF8.GetString(f.Data.Span);
                break;
            }
        }

        var title = TitleFromPlain(plain) ?? TitleFromFileUrl(flavors);
        var preview = plain is null ? null
            : (plain.Length > PreviewMax ? plain[..PreviewMax] : plain);

        return (title, preview);
    }

    private static string? TitleFromPlain(string? plain)
    {
        if (plain is null) return null;

        // First non-empty line, trimmed of whitespace. \r\n and \r both count
        // as line breaks so Windows-native line endings work the same as Unix.
        foreach (var raw in plain.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            return line.Length > TitleMax ? line[..TitleMax] : line;
        }
        return null;
    }

    private static string? TitleFromFileUrl(IReadOnlyList<CanonicalHash.Flavor> flavors)
    {
        foreach (var f in flavors)
        {
            if (f.Uti != "public.file-url") continue;
            var s = Encoding.UTF8.GetString(f.Data.Span);
            // file:// URLs and bare paths both make sense here; macOS publishes
            // the former, but a Windows port may produce the latter.
            try
            {
                if (Uri.TryCreate(s, UriKind.Absolute, out var uri))
                {
                    var name = Path.GetFileName(Uri.UnescapeDataString(uri.LocalPath));
                    if (!string.IsNullOrEmpty(name)) return name;
                }
                else
                {
                    var name = Path.GetFileName(s);
                    if (!string.IsNullOrEmpty(name)) return name;
                }
            }
            catch
            {
                // Malformed URL — don't crash the ingest; just skip the title.
            }
        }
        return null;
    }
}
