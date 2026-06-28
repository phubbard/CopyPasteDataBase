using System.Security.Cryptography;
using System.Text;

namespace CpdbWin.Core.Capture;

/// <summary>
/// Canonical content identity, v2 (<c>idv2-r1</c>). Windows port of
/// <c>Sources/CpdbShared/Capture/ContentIdentity.swift</c> /
/// <c>Tools/gen_hash_vectors.py</c>.
///
/// <para>
/// Entry identity = SHA-256 of the <b>primary</b> content only, chosen by a
/// rung chain: image → file → url → normalized text → color →
/// full-set fallback. Identity matches user-perceived content so a copy
/// captured on two devices converges with no coordination; volatile sidecar
/// formats (Chromium session tokens, Universal Clipboard re-publication
/// noise, link-preview metadata, encoding variants) jitter byte-for-byte
/// between otherwise-identical copies and the old full-set hash forked one
/// logical clip into many rows.
/// </para>
///
/// <para>
/// THIS FILE IS A PORT OF THE REFERENCE IMPLEMENTATION
/// <c>Tools/gen_hash_vectors.py</c>. The authoritative test vectors live in
/// <c>Tests/Fixtures/hash-vectors-v2.json</c>; <c>ContentIdentityVectorsTests</c>
/// asserts every expect_hex. Prose spec: <c>docs/canonical-hash-v2.md</c> §2.
/// Where code and prose disagree, the vectors JSON wins. Any change here is
/// a wire-format change: bump <see cref="Revision"/>, regenerate the
/// vectors via the Python script, and update Swift in lockstep.
/// </para>
/// </summary>
public static class ContentIdentity
{
    /// <summary>Logged with every computed hash; never a hash input.</summary>
    public const string Revision = "idv2-r1";

    /// <summary>The rung that produced an identity. Stored in
    /// <c>entries.identity_tag</c>.</summary>
    public enum Tag
    {
        Image,
        File,
        Url,
        Text,
        Color,
        Fallback,
    }

    /// <summary>Lowercase canonical tag string (used as a hash input).
    /// Stable wire form — never reformat.</summary>
    public static string TagString(Tag t) => t switch
    {
        Tag.Image    => "image",
        Tag.File     => "file",
        Tag.Url      => "url",
        Tag.Text     => "text",
        Tag.Color    => "color",
        Tag.Fallback => "fallback",
        _ => throw new ArgumentOutOfRangeException(nameof(t), t, null),
    };

    /// <summary>Parse a tag string back to the enum. Returns null for any
    /// unrecognised input (forward-compatible if Mac adds new rungs).</summary>
    public static Tag? ParseTag(string? s) => s switch
    {
        "image"    => Tag.Image,
        "file"     => Tag.File,
        "url"      => Tag.Url,
        "text"     => Tag.Text,
        "color"    => Tag.Color,
        "fallback" => Tag.Fallback,
        _          => null,
    };

    public static int RungIndex(Tag t) => t switch
    {
        Tag.Image    => 1,
        Tag.File     => 2,
        Tag.Url      => 3,
        Tag.Text     => 4,
        Tag.Color    => 5,
        Tag.Fallback => 6,
        _ => throw new ArgumentOutOfRangeException(nameof(t), t, null),
    };

    // ── Pinned constants (mirror docs §2.3 + gen_hash_vectors.py exactly) ──

    public const string SharedPasteboardMarker =
        "group.com.apple.coreservices.useractivityd/shared-pasteboard/";

    /// <summary>U+0020 space, U+0009 tab, U+000A LF, U+000D CR, U+00A0 NBSP.
    /// Exhaustive — no locale, no Unicode "whitespace" class.</summary>
    public static readonly HashSet<char> UrlTrimSet = new()
    {
        (char)0x20, (char)0x09, (char)0x0A, (char)0x0D, (char)0xA0,
    };

    public static readonly string[] ImageUtis =
        { "public.png", "public.jpeg", "public.tiff", "public.heic", "public.heif", "public.image" };

    public const int ImageMinBytes = 1024;

    public static readonly string[] ColorUtis =
        { "com.apple.cocoa.pasteboard.color", "public.color" };

    public static readonly string[] TextUtf8Utis = { "public.utf8-plain-text", "public.plain-text" };
    public const string TextUtf16External = "public.utf16-external-plain-text";
    public const string TextUtf16         = "public.utf16-plain-text";
    public const string TextHtmlLastResort = "public.html";

    /// <summary>Fallback rung only. Excluded from the v1-style emission.
    /// The semantic rungs make this list irrelevant everywhere except
    /// <c>kind=other</c> junk — that inversion is the point: a new
    /// volatile UTI in 2027 needs zero code change.</summary>
    public static readonly HashSet<string> VolatileExact = new(StringComparer.Ordinal)
    {
        "public.text",
        "com.apple.is-remote-clipboard",
        "com.apple.traditional-mac-plain-text",
        "org.chromium.source-url",
        "org.chromium.internal.source-rfh-token",
        "com.apple.WebKit.custom-pasteboard-data",
        "com.apple.linkpresentation.metadata",
        "com.apple.icns",
        "com.raycast.RestoredType",
        "com.apple.security.sandbox-extension-dict",
        "public.utf16-plain-text",
        "public.utf16-external-plain-text",
    };

    public static readonly string[] VolatilePrefixes = { "com.apple.iWork.pasteboardState.", "dyn." };

    public static bool IsVolatile(string uti)
        => VolatileExact.Contains(uti)
        || VolatilePrefixes.Any(p => uti.StartsWith(p, StringComparison.Ordinal));

    // ── Public API ──────────────────────────────────────────────────────

    /// <summary>Compute identity over a list of pasteboard items (each a
    /// flavor list). Returns the rung tag and the 32-byte SHA-256
    /// <c>content_hash</c> the migrator + ingestor + importer all use.</summary>
    public static (Tag Tag, byte[] Hash) Compute(IReadOnlyList<IReadOnlyList<CanonicalHash.Flavor>> items)
    {
        var flat = Flatten(items);
        var (tag, value) = Identity(flat);
        using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        h.AppendData(Encoding.UTF8.GetBytes(TagString(tag)));
        h.AppendData(new byte[] { 0x00 });
        h.AppendData(value);
        return (tag, h.GetHashAndReset());
    }

    /// <summary>Convenience: single-item snapshot.</summary>
    public static (Tag Tag, byte[] Hash) Compute(IReadOnlyList<CanonicalHash.Flavor> flavors)
        => Compute(new[] { flavors });

    // ── Flattening (§2.2 — first occurrence of each UTI wins) ────────────

    internal static Dictionary<string, byte[]> Flatten(
        IReadOnlyList<IReadOnlyList<CanonicalHash.Flavor>> items)
    {
        var flat = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (var item in items)
            foreach (var f in item)
                if (!flat.ContainsKey(f.Uti))
                    flat[f.Uti] = f.Data.ToArray();
        return flat;
    }

    // ── The rung chain (§2.3) ────────────────────────────────────────────

    internal static (Tag Tag, byte[] Value) Identity(Dictionary<string, byte[]> flat)
    {
        // Rung 1 — IMAGE
        foreach (var uti in ImageUtis)
        {
            if (flat.TryGetValue(uti, out var b) && b.Length >= ImageMinBytes)
                return (Tag.Image, b);
        }

        // Rung 2 — FILE
        if (flat.TryGetValue("public.file-url", out var fb))
        {
            var s = StrictUtf8(fb);
            if (s is not null && !s.Contains(SharedPasteboardMarker, StringComparison.Ordinal))
            {
                var decoded = StripOneTrailingSlash(PercentDecode(s));
                return (Tag.File, Encoding.UTF8.GetBytes(decoded));
            }
            // decode failure OR shared-pasteboard echo: stored, not identity
        }

        // Rung 3 — URL
        if (flat.TryGetValue("public.url", out var ub))
        {
            var s0 = StrictUtf8(ub);
            if (s0 is not null)
            {
                var s = StripOneTrailingSlash(TrimUrlSet(s0));
                if (s.Length > 0)
                    return (Tag.Url, Encoding.UTF8.GetBytes(s));
            }
        }

        // Rung 4 — TEXT (with URL-shaped-text promotion)
        var raw = BestText(flat);
        if (raw is not null)
        {
            var t = NormalizeText(raw);
            if (t.Length > 0)
            {
                var p = TrimUrlSet(t);
                if (LooksLikeUrlPortable(p))
                    return (Tag.Url, Encoding.UTF8.GetBytes(StripOneTrailingSlash(p)));
                return (Tag.Text, Encoding.UTF8.GetBytes(t));
            }
            // empty after normalization: fall to fallback (avoids the
            // sha256("text\0") mega-cluster the audit found)
        }

        // Rung 5 — COLOR
        foreach (var uti in ColorUtis)
        {
            if (flat.TryGetValue(uti, out var cb))
                return (Tag.Color, cb);
        }

        // Rung 6 — FALLBACK
        var kept = flat.Where(kv => !IsVolatile(kv.Key))
                       .Select(kv => new CanonicalHash.Flavor(kv.Key, kv.Value))
                       .ToList();
        if (kept.Count == 0)
            kept = flat.Select(kv => new CanonicalHash.Flavor(kv.Key, kv.Value)).ToList();
        // Use the RAW v1 emission bytes; the outer Compute() above wraps
        // them with one SHA-256 over "fallback" || 0x00 || EmitV1(...).
        // Calling CanonicalHash.Compute here would double-hash.
        return (Tag.Fallback, CanonicalHash.EmitV1(new[] { (IReadOnlyList<CanonicalHash.Flavor>)kept }));
    }

    // ── Primitives (mirror gen_hash_vectors.py one-for-one) ──────────────

    /// <summary>Strict UTF-8: null on any invalid sequence (never substitutes
    /// U+FFFD).</summary>
    internal static string? StrictUtf8(byte[] bytes)
    {
        try
        {
            var enc = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
            return enc.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    /// <summary>Decode a UTF-16 flavor per §2.3. BOM present → use its
    /// endianness and strip it; BOM-less → little-endian everywhere.
    /// Strict: odd length or any unpaired surrogate → null. Manual
    /// code-unit walk so Swift/C#/Python agree exactly.</summary>
    internal static string? DecodeUtf16(byte[] bytes)
    {
        if (bytes.Length % 2 != 0) return null;
        bool bigEndian;
        int idx;
        if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
        { bigEndian = false; idx = 2; }
        else if (bytes.Length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF)
        { bigEndian = true;  idx = 2; }
        else
        { bigEndian = false; idx = 0; }  // BOM-less default

        var sb = new StringBuilder((bytes.Length - idx) / 2);

        ushort Unit(int i)
        {
            byte lo = bytes[i], hi = bytes[i + 1];
            return bigEndian ? (ushort)((lo << 8) | hi) : (ushort)((hi << 8) | lo);
        }

        while (idx + 1 < bytes.Length)
        {
            ushort u = Unit(idx); idx += 2;
            if (u >= 0xD800 && u <= 0xDBFF)
            {
                // high surrogate: must be followed by a low surrogate
                if (idx + 1 >= bytes.Length) return null;
                ushort low = Unit(idx);
                if (low < 0xDC00 || low > 0xDFFF) return null;
                idx += 2;
                int code = 0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00);
                sb.Append(char.ConvertFromUtf32(code));
            }
            else if (u >= 0xDC00 && u <= 0xDFFF)
            {
                return null;  // lone low surrogate
            }
            else
            {
                sb.Append((char)u);
            }
        }
        return sb.ToString();
    }

    /// <summary>Rung-4 decode ladder. A source that fails strict decode is
    /// skipped (not substituted).</summary>
    internal static string? BestText(Dictionary<string, byte[]> flat)
    {
        foreach (var uti in TextUtf8Utis)
        {
            if (flat.TryGetValue(uti, out var b))
            {
                var s = StrictUtf8(b);
                if (s is not null) return s;
            }
        }
        if (flat.TryGetValue(TextUtf16External, out var u16e))
        {
            var s = DecodeUtf16(u16e);
            if (s is not null) return s;
        }
        if (flat.TryGetValue(TextUtf16, out var u16))
        {
            var s = DecodeUtf16(u16);
            if (s is not null) return s;
        }
        if (flat.TryGetValue(TextHtmlLastResort, out var html))
        {
            var s = StrictUtf8(html);
            if (s is not null) return s;
        }
        return null;
    }

    /// <summary>Byte-level normalization after strict validation: strip ONE
    /// leading BOM (U+FEFF), CRLF → LF, lone CR → LF. No outer trim. No
    /// Unicode NFC (platform-divergence risk).</summary>
    internal static string NormalizeText(string s)
    {
        if (s.Length > 0 && s[0] == (char)0xFEFF) s = s.Substring(1);
        s = s.Replace("\r\n", "\n").Replace("\r", "\n");
        return s;
    }

    /// <summary>Strip leading/trailing codepoints in
    /// <see cref="UrlTrimSet"/> only.</summary>
    internal static string TrimUrlSet(string s)
    {
        int i = 0, j = s.Length;
        while (i < j && UrlTrimSet.Contains(s[i])) i++;
        while (j > i && UrlTrimSet.Contains(s[j - 1])) j--;
        return s.Substring(i, j - i);
    }

    /// <summary>Remove exactly one trailing '/' unless the string ends with
    /// "://".</summary>
    internal static string StripOneTrailingSlash(string s)
    {
        if (s.EndsWith("/", StringComparison.Ordinal) && !s.EndsWith("://", StringComparison.Ordinal))
            return s.Substring(0, s.Length - 1);
        return s;
    }

    /// <summary><paramref name="p"/> is already URL-trimmed. Portable
    /// lowercase-exact http(s) check used for the text→url promotion.
    /// Deliberately narrow so Swift/C#/Python never diverge.</summary>
    internal static bool LooksLikeUrlPortable(string p)
    {
        if (p.Length > 2048) return false;
        if (!(p.StartsWith("http://",  StringComparison.Ordinal)
           || p.StartsWith("https://", StringComparison.Ordinal))) return false;
        for (int i = 0; i < p.Length; i++)
            if (UrlTrimSet.Contains(p[i])) return false;
        int scheme = p.IndexOf("://", StringComparison.Ordinal);
        if (scheme < 0) return false;
        int afterStart = scheme + 3;
        // authority = up to first of / ? # (or end); must be non-empty.
        int cut = p.Length;
        foreach (var sep in new[] { '/', '?', '#' })
        {
            int k = p.IndexOf(sep, afterStart);
            if (k >= 0 && k < cut) cut = k;
        }
        return cut > afterStart;
    }

    /// <summary>Percent-decode matching Python's
    /// <c>urllib.parse.unquote(s, errors="replace")</c>: "%" + two ASCII
    /// hex → that byte; otherwise the literal "%" is kept. The collected
    /// byte stream is decoded as UTF-8 with U+FFFD substitution on bad
    /// bytes (the default <see cref="Encoding.UTF8"/> already does this).
    /// Manual implementation, no stdlib percent API, identical on every
    /// platform by construction.</summary>
    internal static string PercentDecode(string s)
    {
        var src = Encoding.UTF8.GetBytes(s);
        var outBytes = new List<byte>(src.Length);
        int i = 0;
        while (i < src.Length)
        {
            if (src[i] == (byte)'%' && i + 2 < src.Length)
            {
                int hi = HexVal(src[i + 1]);
                int lo = HexVal(src[i + 2]);
                if (hi >= 0 && lo >= 0)
                {
                    outBytes.Add((byte)((hi << 4) | lo));
                    i += 3;
                    continue;
                }
            }
            outBytes.Add(src[i]);
            i++;
        }
        return Encoding.UTF8.GetString(outBytes.ToArray());
    }

    private static int HexVal(byte b) => b switch
    {
        >= (byte)'0' and <= (byte)'9' => b - (byte)'0',
        >= (byte)'A' and <= (byte)'F' => b - (byte)'A' + 10,
        >= (byte)'a' and <= (byte)'f' => b - (byte)'a' + 10,
        _ => -1,
    };
}
