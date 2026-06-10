import Foundation
import CryptoKit

/// Canonical content identity, v2 (`idv2-r1`).
///
/// Entry identity = SHA-256 of the **primary** content only, chosen by a rung
/// chain (image → file → url → normalized text → color → full-set fallback).
/// Identity matches user-perceived content so two devices that copy the same
/// thing converge with no coordination; storage keeps full capture fidelity.
///
/// THIS FILE IS A PORT OF THE REFERENCE IMPLEMENTATION `Tools/gen_hash_vectors.py`.
/// The authoritative test vectors live in `Tests/Fixtures/hash-vectors-v2.json`
/// and `HashVectors.swift` asserts every one. The Windows port
/// (`CpdbWin.Core.ContentIdentity`) must reproduce the same hexes. The prose
/// spec is `docs/canonical-hash-v2.md` §2; where code and prose disagree, the
/// vectors JSON wins. Any change here is a wire-format change: bump
/// `revision`, regenerate the vectors, update both platforms in lockstep.
public enum ContentIdentity {

    /// Logged with every computed hash; never a hash input.
    public static let revision = "idv2-r1"

    /// The rung that produced an identity. Carried on the CloudKit wire as
    /// `identityTag` and used for deterministic conflict resolution: a lower
    /// `rungIndex` was computed from more-authoritative input, so on an
    /// equal-version hash fork the lower rung wins (missing flavors can only
    /// demote identity *down* the chain). See docs §2.3 / §5.3.
    public enum Tag: String, Sendable {
        case image, file, url, text, color, fallback

        public var rungIndex: Int {
            switch self {
            case .image:    return 1
            case .file:     return 2
            case .url:      return 3
            case .text:     return 4
            case .color:    return 5
            case .fallback: return 6
            }
        }
    }

    // MARK: - Pinned constants (mirror docs §2.3 and Tools/gen_hash_vectors.py exactly)

    static let sharedPasteboardMarker =
        "group.com.apple.coreservices.useractivityd/shared-pasteboard/"

    /// U+0020 space, U+0009 tab, U+000A LF, U+000D CR, U+00A0 NBSP. Exhaustive.
    static let urlTrimSet: Set<Character> = ["\u{0020}", "\u{0009}", "\u{000A}", "\u{000D}", "\u{00A0}"]

    static let imageUTIs = ["public.png", "public.jpeg", "public.tiff",
                            "public.heic", "public.heif", "public.image"]
    static let imageMinBytes = 1024

    static let colorUTIs = ["com.apple.cocoa.pasteboard.color", "public.color"]

    static let textUTF8UTIs = ["public.utf8-plain-text", "public.plain-text"]
    static let textUTF16External = "public.utf16-external-plain-text"
    static let textUTF16 = "public.utf16-plain-text"
    static let textHTMLLastResort = "public.html"

    /// Fallback rung only. Excluded from the v1-style emission.
    static let volatileExact: Set<String> = [
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
    ]
    static let volatilePrefixes = ["com.apple.iWork.pasteboardState.", "dyn."]

    static func isVolatile(_ uti: String) -> Bool {
        volatileExact.contains(uti) || volatilePrefixes.contains { uti.hasPrefix($0) }
    }

    // MARK: - Public API

    /// Compute identity over a list of pasteboard items (each a flavor list).
    /// Returns the rung tag and the 32-byte SHA-256 `content_hash`.
    public static func compute(items: [[CanonicalHash.Flavor]]) -> (tag: Tag, hash: Data) {
        let flat = flatten(items)
        let (tag, value) = identity(flat)
        var hasher = SHA256()
        hasher.update(data: Data(tag.rawValue.utf8))
        hasher.update(data: Data([0x00]))
        hasher.update(data: value)
        return (tag, Data(hasher.finalize()))
    }

    /// Convenience: single-item snapshot.
    public static func compute(flavors: [CanonicalHash.Flavor]) -> (tag: Tag, hash: Data) {
        compute(items: [flavors])
    }

    // MARK: - Capture policy (§2.4 skip rules — NOT part of the hash contract)

    /// True iff every flavor in the snapshot is zero-length. Such a snapshot
    /// carries no content at all; the Ingestor skips it (belt over the
    /// empty-after-normalization → fallback suspender in the rung chain).
    public static func snapshotIsAllEmpty(items: [[CanonicalHash.Flavor]]) -> Bool {
        let flat = flatten(items)
        return flat.isEmpty || flat.values.allSatisfy { $0.isEmpty }
    }

    /// True iff the snapshot is a Universal Clipboard *file* echo with no
    /// other substantive content: a `public.file-url` pointing into the
    /// useractivityd shared-pasteboard container, and no image ≥ 1 KB, no
    /// non-empty text source, no `public.url`, no color. These are
    /// Mac-to-Mac Finder-copy mirrors — the receiving Mac materializes the
    /// remote file under a fresh UUID per transfer, so the path can never
    /// dedup and the row is pure noise. Echoes that DO carry image bytes or
    /// text (iPhone-origin copies, for which the echo is the only record
    /// anywhere) key via rungs 1/4 and are kept. See docs §2.4.
    public static func isSoleSharedPasteboardEcho(items: [[CanonicalHash.Flavor]]) -> Bool {
        let flat = flatten(items)
        guard let b = flat["public.file-url"], let s = strictUTF8(b),
              s.contains(sharedPasteboardMarker) else { return false }
        // Any other substantive flavor rescues the snapshot.
        for uti in imageUTIs {
            if let img = flat[uti], img.count >= imageMinBytes { return false }
        }
        if let t = bestText(flat), !normalizeText(t).isEmpty { return false }
        if flat["public.url"] != nil { return false }
        for uti in colorUTIs where flat[uti] != nil { return false }
        return true
    }

    // MARK: - Flattening (§2.2 — first occurrence of each UTI wins)

    static func flatten(_ items: [[CanonicalHash.Flavor]]) -> [String: Data] {
        var flat: [String: Data] = [:]
        for item in items {
            for f in item where flat[f.uti] == nil {
                flat[f.uti] = f.data
            }
        }
        return flat
    }

    // MARK: - The rung chain (§2.3)

    static func identity(_ flat: [String: Data]) -> (Tag, Data) {
        // Rung 1 — IMAGE
        for uti in imageUTIs {
            if let b = flat[uti], b.count >= imageMinBytes {
                return (.image, b)
            }
        }

        // Rung 2 — FILE
        if let b = flat["public.file-url"], let s = strictUTF8(b),
           !s.contains(sharedPasteboardMarker) {
            let decoded = stripOneTrailingSlash(percentDecode(s))
            return (.file, Data(decoded.utf8))
        }
        // (decode failure OR shared-pasteboard echo: stored, not identity — fall through)

        // Rung 3 — URL
        if let b = flat["public.url"], let s0 = strictUTF8(b) {
            let s = stripOneTrailingSlash(trimURLSet(s0))
            if !s.isEmpty {
                return (.url, Data(s.utf8))
            }
        }

        // Rung 4 — TEXT (with URL-shaped-text promotion)
        if let raw = bestText(flat) {
            let t = normalizeText(raw)
            if !t.isEmpty {
                let p = trimURLSet(t)
                if looksLikeURLPortable(p) {
                    return (.url, Data(stripOneTrailingSlash(p).utf8))
                }
                return (.text, Data(t.utf8))
            }
            // empty after normalization: fall to fallback
        }

        // Rung 5 — COLOR
        for uti in colorUTIs {
            if let b = flat[uti] {
                return (.color, b)
            }
        }

        // Rung 6 — FALLBACK
        var kept = flat.filter { !isVolatile($0.key) }
        if kept.isEmpty { kept = flat }
        return (.fallback, v1Emission(kept))
    }

    // MARK: - Primitives

    /// Strict UTF-8: nil on any invalid sequence (never substitutes U+FFFD).
    static func strictUTF8(_ b: Data) -> String? {
        String(data: b, encoding: .utf8)
    }

    /// Decode a UTF-16 flavor per §2.3. BOM present → use its endianness and
    /// strip it; BOM-less → little-endian everywhere. Strict: odd length or any
    /// unpaired surrogate → nil. Manual code-unit walk so Swift/C#/Python agree
    /// exactly (we do not rely on platform `String(data:encoding:)` quirks).
    static func decodeUTF16(_ b: Data) -> String? {
        if b.count % 2 != 0 { return nil }
        let bytes = [UInt8](b)
        var idx = 0
        let bigEndian: Bool
        if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
            bigEndian = false; idx = 2
        } else if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
            bigEndian = true; idx = 2
        } else {
            bigEndian = false  // BOM-less default
        }
        var scalars: [Unicode.Scalar] = []
        func unit(_ i: Int) -> UInt16 {
            let lo = UInt16(bytes[i]); let hi = UInt16(bytes[i + 1])
            return bigEndian ? (lo << 8 | hi) : (hi << 8 | lo)
        }
        while idx + 1 < bytes.count {
            let u = unit(idx); idx += 2
            if u >= 0xD800 && u <= 0xDBFF {
                // high surrogate: must be followed by a low surrogate
                guard idx + 1 < bytes.count else { return nil }
                let low = unit(idx)
                guard low >= 0xDC00 && low <= 0xDFFF else { return nil }
                idx += 2
                let code = 0x10000 + (UInt32(u - 0xD800) << 10) + UInt32(low - 0xDC00)
                guard let sc = Unicode.Scalar(code) else { return nil }
                scalars.append(sc)
            } else if u >= 0xDC00 && u <= 0xDFFF {
                return nil  // lone low surrogate
            } else {
                guard let sc = Unicode.Scalar(UInt32(u)) else { return nil }
                scalars.append(sc)
            }
        }
        var s = ""
        s.unicodeScalars.append(contentsOf: scalars)
        return s
    }

    /// Rung-4 decode ladder. A source that fails strict decode is skipped.
    static func bestText(_ flat: [String: Data]) -> String? {
        for uti in textUTF8UTIs {
            if let b = flat[uti], let s = strictUTF8(b) { return s }
        }
        if let b = flat[textUTF16External], let s = decodeUTF16(b) { return s }
        if let b = flat[textUTF16], let s = decodeUTF16(b) { return s }
        if let b = flat[textHTMLLastResort], let s = strictUTF8(b) { return s }
        return nil
    }

    /// Byte-level normalization: strip ONE leading BOM (U+FEFF), CRLF→LF, lone
    /// CR→LF. No outer trim (V5 rejected). No Unicode NFC (divergence risk).
    static func normalizeText(_ input: String) -> String {
        var s = Substring(input)
        if s.first == "\u{FEFF}" { s = s.dropFirst() }
        return s.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
    }

    static func trimURLSet(_ s: String) -> String {
        String(s.drop(while: { urlTrimSet.contains($0) })
                .reversed().drop(while: { urlTrimSet.contains($0) }).reversed())
    }

    /// Remove exactly one trailing "/" unless the string ends with "://".
    static func stripOneTrailingSlash(_ s: String) -> String {
        if s.hasSuffix("/") && !s.hasSuffix("://") {
            return String(s.dropLast())
        }
        return s
    }

    /// p is already URL-trimmed. Portable lowercase-exact http(s) check for the
    /// text→url promotion. Deliberately narrow so Swift/C# never diverge.
    static func looksLikeURLPortable(_ p: String) -> Bool {
        if p.count > 2048 { return false }
        guard p.hasPrefix("http://") || p.hasPrefix("https://") else { return false }
        if p.contains(where: { urlTrimSet.contains($0) }) { return false }
        guard let schemeRange = p.range(of: "://") else { return false }
        let after = p[schemeRange.upperBound...]
        // authority = up to first of / ? # (or end); must be non-empty
        let authEnd = after.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? after.endIndex
        return authEnd > after.startIndex
    }

    /// Percent-decode matching Python's `urllib.parse.unquote(s)` (UTF-8,
    /// errors="replace"): "%" + two ASCII hex → that byte; otherwise the
    /// literal "%" is kept. The collected byte stream is decoded as UTF-8 with
    /// U+FFFD substitution. Identical behaviour on both platforms by
    /// construction (manual, no stdlib percent API).
    static func percentDecode(_ s: String) -> String {
        let src = [UInt8](s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(src.count)
        var i = 0
        func hexVal(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        while i < src.count {
            if src[i] == 0x25, i + 2 < src.count,            // '%'
               let hi = hexVal(src[i + 1]), let lo = hexVal(src[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(src[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// v1 single-item canonical emission over the kept flavors, BYTE-WISE
    /// sorted by the UTF-8 encoding of the UTI (NOT Swift `<` collation, NOT
    /// UTF-16 ordinal): for each `uti||0x00||u64be(len)||bytes`, then a single
    /// trailing 0x01.
    static func v1Emission(_ kept: [String: Data]) -> Data {
        let sorted = kept.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
        var out = Data()
        for (uti, bytes) in sorted {
            out.append(Data(uti.utf8))
            out.append(0x00)
            var lenBE = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &lenBE) { out.append(contentsOf: $0) }
            out.append(bytes)
        }
        out.append(0x01)
        return out
    }
}
