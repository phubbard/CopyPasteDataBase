using System.Text;

namespace CpdbWin.Core.Capture;

/// <summary>
/// Parses the CF_HDROP clipboard format (file/folder copies from Explorer)
/// into the file paths it carries. Layout:
/// <code>
/// DROPFILES {
///   DWORD pFiles;   // offset of file list within the blob
///   POINT pt;       // 8 bytes drop point — unused
///   BOOL  fNC;      // 4 bytes — unused
///   BOOL  fWide;    // 1 = UTF-16 LE list, 0 = ANSI
/// }
/// // at offset pFiles: sequence of null-terminated path strings,
/// // terminated by an extra null. Always wide on modern Windows.
/// </code>
/// We require <c>fWide == 1</c>; ANSI HDROP hasn't been seen in the wild
/// since the XP era.
/// </summary>
public static class HdropParser
{
    private const int DropfilesHeaderSize = 20;

    public static IReadOnlyList<string> ParsePaths(ReadOnlySpan<byte> raw)
    {
        if (raw.Length < DropfilesHeaderSize) return Array.Empty<string>();

        int pFiles = BitConverter.ToInt32(raw[..4]);
        // skip pt (offsets 4..12) and fNC (12..16)
        bool fWide = BitConverter.ToInt32(raw[16..20]) != 0;

        if (!fWide) return Array.Empty<string>();
        if (pFiles < DropfilesHeaderSize || pFiles >= raw.Length) return Array.Empty<string>();

        var list = raw[pFiles..];
        var paths = new List<string>();
        int p = 0;
        while (p + 1 < list.Length)
        {
            // Each path is UTF-16 LE, null-terminated. Find the next 00 00.
            int nameEnd = p;
            while (nameEnd + 1 < list.Length)
            {
                if (list[nameEnd] == 0 && list[nameEnd + 1] == 0) break;
                nameEnd += 2;
            }
            if (nameEnd == p) break; // empty path = the list-end null pair
            paths.Add(Encoding.Unicode.GetString(list[p..nameEnd]));
            p = nameEnd + 2;
        }
        return paths;
    }

    /// <summary>
    /// Convert a Windows path to a <c>file://</c> URL (the on-clipboard form
    /// that <c>public.file-url</c> stores). Returns null for paths the URI
    /// builder can't represent.
    /// </summary>
    public static string? ToFileUrl(string path)
    {
        try
        {
            return new Uri(path).AbsoluteUri;
        }
        catch
        {
            return null;
        }
    }
}
