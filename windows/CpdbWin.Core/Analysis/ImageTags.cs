namespace CpdbWin.Core.Analysis;

/// <summary>
/// Helpers for the <c>entries.image_tags</c> column. Pure functions —
/// no WinRT, no SQLite — so they're reusable from Core tests, the App
/// view-model, and the CLI without dragging UI dependencies along.
/// </summary>
public static class ImageTags
{
    /// <summary>
    /// Split the stored <c>image_tags</c> string into individual labels.
    /// Accepts:
    /// <list type="bullet">
    /// <item>The canonical v1.25.0+ form — comma+space-separated
    ///       (<c>"great white shark, laptop, keyboard"</c>). Multi-word
    ///       ImageNet labels survive intact.</item>
    /// <item>The legacy v1.24.0 form — space-separated
    ///       (<c>"laptop keyboard mouse"</c>). Only correct for
    ///       single-word labels; multi-word labels can't be
    ///       disambiguated retroactively. Re-running OCR overwrites
    ///       with the canonical form.</item>
    /// </list>
    /// Returns an empty list for null / whitespace input. FTS5 search by
    /// any single word still works against either format (the unicode61
    /// tokenizer splits on both whitespace and punctuation).
    /// </summary>
    public static IReadOnlyList<string> Parse(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return Array.Empty<string>();

        var parts = raw.Split(',',
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        // One chunk + embedded spaces → legacy v1.24.0 data; fall back
        // to whitespace split. (A genuine single multi-word label has
        // no comma either, but the canonical writer always emits
        // commas now, so a single chunk with spaces is legacy.)
        if (parts.Length <= 1 && raw.Contains(' '))
        {
            parts = raw.Split(' ',
                StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        }
        return parts.Length == 0 ? Array.Empty<string>() : parts;
    }
}
