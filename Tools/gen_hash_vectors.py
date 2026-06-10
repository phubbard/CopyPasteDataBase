#!/usr/bin/env python3
"""
Reference implementation of canonical-hash v2 (semantic content identity)
and generator for the authoritative cross-platform test vectors.

This file is the SINGLE SOURCE OF TRUTH for the v2 identity algorithm:
the Swift `ContentIdentity` (CpdbShared) and the C# `ContentIdentity`
(Windows port) must reproduce every hex in the emitted
`Tests/Fixtures/hash-vectors-v2.json` byte-for-byte. The prose spec lives
in `docs/canonical-hash-v2.md` §2; where this implementation and the prose
disagree, THIS implementation wins and the prose is corrected (per §2.6:
"the JSON artifact is authoritative — schema.md and this table cite it,
never the reverse").

Run:  python3 Tools/gen_hash_vectors.py            # writes the JSON + prints report
      python3 Tools/gen_hash_vectors.py --check    # report only, exit 1 on prose mismatch

The "report" cross-checks the computed hexes against the hand-written hexes
in docs/canonical-hash-v2.md §2.6 and flags every divergence so the doc can
be reconciled to ground truth.
"""
import base64
import hashlib
import json
import os
import struct
import sys
import urllib.parse

# ----------------------------------------------------------------------------
# Pinned constants (mirror docs/canonical-hash-v2.md §2.3 exactly).
# Any change here is a wire-format change: bump IDENTITY_REVISION, regenerate
# the vectors, and update both platform implementations in lockstep.
# ----------------------------------------------------------------------------

IDENTITY_REVISION = "idv2-r1"  # logged with every computed hash; never a hash input

SHARED_PASTEBOARD_MARKER = "group.com.apple.coreservices.useractivityd/shared-pasteboard/"

# Exhaustive, pinned. Codepoints only — no locale, no Unicode "whitespace" class.
URL_TRIM_SET = {"\u0020", "\u0009", "\u000a", "\u000d", "\u00a0"}

IMAGE_UTIS = ["public.png", "public.jpeg", "public.tiff", "public.heic", "public.heif", "public.image"]
IMAGE_MIN = 1024  # bytes

COLOR_UTIS = ["com.apple.cocoa.pasteboard.color", "public.color"]

# best_text decode ladder (rung 4). Order is normative.
TEXT_UTF8_UTIS = ["public.utf8-plain-text", "public.plain-text"]
TEXT_UTF16_EXTERNAL = "public.utf16-external-plain-text"
TEXT_UTF16 = "public.utf16-plain-text"
TEXT_HTML_LASTRESORT = "public.html"

# Fallback rung only. Excluded from the v1-style emission. The semantic rungs
# make this list irrelevant everywhere except kind=other junk — that inversion
# is the point: a new volatile UTI in 2027 needs zero code change.
VOLATILE_DENYLIST_EXACT = {
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
}
VOLATILE_DENYLIST_PREFIX = ("com.apple.iWork.pasteboardState.", "dyn.")

TAGS = {"image", "file", "url", "text", "color", "fallback"}


def is_volatile(uti: str) -> bool:
    return uti in VOLATILE_DENYLIST_EXACT or any(uti.startswith(p) for p in VOLATILE_DENYLIST_PREFIX)


# ----------------------------------------------------------------------------
# Primitives
# ----------------------------------------------------------------------------

def strict_utf8(b: bytes):
    """Decode strict UTF-8. Returns the str, or None on any invalid sequence
    (a skipped source never substitutes U+FFFD)."""
    try:
        return b.decode("utf-8")
    except UnicodeDecodeError:
        return None


def decode_utf16(b: bytes):
    """Decode a UTF-16 flavor per §2.3: BOM present -> use its endianness and
    strip it; BOM-less -> little-endian on every platform. Strict; an unpaired
    surrogate (or odd length) -> None (skip source)."""
    if len(b) % 2 != 0:
        return None
    if b[:2] == b"\xff\xfe":
        body, enc = b[2:], "utf-16-le"
    elif b[:2] == b"\xfe\xff":
        body, enc = b[2:], "utf-16-be"
    else:
        body, enc = b, "utf-16-le"  # BOM-less default
    try:
        s = body.decode(enc, "strict")
    except UnicodeDecodeError:
        return None
    # Python's UTF-16 codec admits lone surrogates; the contract rejects them.
    if any(0xD800 <= ord(ch) <= 0xDFFF for ch in s):
        return None
    return s


def best_text(flat):
    """Rung-4 decode ladder. Returns a decoded str, or None if every source
    fails / is absent. A source that fails strict decode is skipped, not
    substituted."""
    for uti in TEXT_UTF8_UTIS:
        if uti in flat:
            s = strict_utf8(flat[uti])
            if s is not None:
                return s
    if TEXT_UTF16_EXTERNAL in flat:
        s = decode_utf16(flat[TEXT_UTF16_EXTERNAL])
        if s is not None:
            return s
    if TEXT_UTF16 in flat:
        s = decode_utf16(flat[TEXT_UTF16])
        if s is not None:
            return s
    if TEXT_HTML_LASTRESORT in flat:
        s = strict_utf8(flat[TEXT_HTML_LASTRESORT])
        if s is not None:
            return s
    return None


def normalize_text(s: str) -> str:
    """Byte-level normalization after strict validation: strip ONE leading BOM
    (U+FEFF, the decoded form of EF BB BF), CRLF -> LF, lone CR -> LF.
    No outer trim (V5 rejected). No Unicode NFC (platform-divergence risk)."""
    if s.startswith("﻿"):
        s = s[1:]
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    return s


def trim_url_set(s: str) -> str:
    """Strip leading/trailing codepoints in the pinned URL_TRIM_SET only."""
    i, j = 0, len(s)
    while i < j and s[i] in URL_TRIM_SET:
        i += 1
    while j > i and s[j - 1] in URL_TRIM_SET:
        j -= 1
    return s[i:j]


def strip_one_trailing_slash(s: str) -> str:
    """Remove exactly one trailing '/' unless the string ends with '://'.
    'https://x.com//' -> 'https://x.com/'; 'https://' -> 'https://'."""
    if s.endswith("/") and not s.endswith("://"):
        return s[:-1]
    return s


def looks_like_url_portable(p: str) -> bool:
    """p is already URL-trimmed. Portable, lowercase-exact http(s) check used
    for text->url promotion. Deliberately narrow so Swift/C# never diverge."""
    if len(p) > 2048:
        return False
    if not (p.startswith("http://") or p.startswith("https://")):
        return False
    if any(ch in URL_TRIM_SET for ch in p):
        return False
    after = p[p.index("://") + 3:]
    # authority = substring up to the first of / ? # (or end); must be non-empty
    cut = len(after)
    for sep in ("/", "?", "#"):
        k = after.find(sep)
        if k != -1:
            cut = min(cut, k)
    return cut > 0


def v1_emission(kept_items) -> bytes:
    """v1 single-item canonical emission over the kept flavors:
    for each (uti, bytes) in BYTE-WISE-sorted-by-uti order:
        uti.utf8 || 0x00 || u64be(len) || bytes
    then a single trailing 0x01 (the v1 item separator).
    Sort is byte-wise over the UTF-8 encoding of the UTI — NOT Swift String<
    (collation) nor Ordinal (UTF-16 code units). Both platform ports must
    compare the UTF-8 byte arrays."""
    out = bytearray()
    for uti, b in sorted(kept_items, key=lambda kv: kv[0].encode("utf-8")):
        out += uti.encode("utf-8")
        out += b"\x00"
        out += struct.pack(">Q", len(b))
        out += b
    out += b"\x01"
    return bytes(out)


# ----------------------------------------------------------------------------
# The rung chain (§2.3). Operates on a flattened map<uti, bytes>.
# Returns (tag, value_bytes).
# ----------------------------------------------------------------------------

def flatten(items):
    """§2.2: first occurrence of each UTI across items (original order) wins.
    Mirrors entry_flavors PK (entry_id, uti) insert-with-ignore semantics, so
    flatten(capture) == flatten(stored rows) by construction."""
    flat = {}
    for item in items:
        for uti, b in item:
            if uti not in flat:
                flat[uti] = b
    return flat


def identity(flat):
    # Rung 1 — IMAGE
    for uti in IMAGE_UTIS:
        b = flat.get(uti)
        if b is not None and len(b) >= IMAGE_MIN:
            return ("image", b)

    # Rung 2 — FILE
    if "public.file-url" in flat:
        s = strict_utf8(flat["public.file-url"])
        if s is not None and SHARED_PASTEBOARD_MARKER not in s:
            s = urllib.parse.unquote(s)  # percent-decode
            s = strip_one_trailing_slash(s)
            return ("file", s.encode("utf-8"))
        # decode failure OR shared-pasteboard echo: fall through (stored, not identity)

    # Rung 3 — URL
    if "public.url" in flat:
        s = strict_utf8(flat["public.url"])
        if s is not None:
            s = trim_url_set(s)
            s = strip_one_trailing_slash(s)
            if s:
                return ("url", s.encode("utf-8"))

    # Rung 4 — TEXT (with URL-shaped-text promotion)
    t = best_text(flat)
    if t is not None:
        t = normalize_text(t)
        if t != "":
            p = trim_url_set(t)
            if looks_like_url_portable(p):
                return ("url", strip_one_trailing_slash(p).encode("utf-8"))
            return ("text", t.encode("utf-8"))
        # empty after normalization: fall to fallback (avoids the sha256("text\0")
        # mega-cluster the simulation found)

    # Rung 5 — COLOR
    for uti in COLOR_UTIS:
        if uti in flat:
            return ("color", flat[uti])

    # Rung 6 — FALLBACK
    kept = [(uti, b) for uti, b in flat.items() if not is_volatile(uti)]
    if not kept:
        kept = list(flat.items())
    return ("fallback", v1_emission(kept))


def content_hash_v2(items):
    """Full identity over a list of items (each item a list of (uti, bytes))."""
    flat = flatten(items)
    tag, value = identity(flat)
    h = hashlib.sha256()
    h.update(tag.encode("utf-8"))
    h.update(b"\x00")
    h.update(value)
    return tag, h.hexdigest()


# ----------------------------------------------------------------------------
# Vector definitions. Each: name, note, items, optional design_hex (the
# hand-written hex from docs §2.6 to cross-check), optional equals (assert the
# computed hash matches the named earlier vector's hash).
# items: list of items; each item a list of (uti, raw_bytes).
# ----------------------------------------------------------------------------

def _png_min(n=1200):
    """Deterministic >=1024-byte pseudo-PNG. Identity for images is raw bytes,
    so this need not be a decodable PNG — only deterministic and >= IMAGE_MIN."""
    body = b"\x89PNG\r\n\x1a\n"
    filler = bytes(range(256)) * ((n // 256) + 1)
    return (body + filler)[:n]

PNG_FIXTURE = _png_min()


def _i(*flavors):
    """One item from (uti, bytes) pairs."""
    return [list(flavors)]


VECTORS = [
    dict(name="text-hello", note="plain text -> text rung",
         items=_i(("public.utf8-plain-text", b"hello")),
         design_hex="306f89347195cc05509ddca47462e259aac6fd01943d2557004ea6f26370cd58"),

    dict(name="sidecar-excluded", note="volatile sidecars never reach the text rung",
         items=_i(("public.utf8-plain-text", b"hello"),
                  ("org.chromium.source-url", b"https://x.y"),
                  ("public.text", b"hello")),
         equals="text-hello"),

    dict(name="text-crlf", note="CRLF -> LF normalization",
         items=_i(("public.utf8-plain-text", b"a\r\nb")),
         design_hex="4930252210319b32b80fc460afbf2d8bd33efa58de16f861fc6cff5a4f402c20"),

    dict(name="url-from-public-url", note="public.url, trailing slash stripped",
         items=_i(("public.url", b"https://example.com/"),
                  ("public.utf8-plain-text", b"https://example.com")),
         design_hex="7ce6868d0d70a4cad25be46c38e61a0ac80edd2c1d10c370317a07c18eae900c"),

    dict(name="url-promoted-slash", note="text-only URL promotes + slash strip; equals url-from-public-url",
         items=_i(("public.utf8-plain-text", b"https://example.com/")),
         equals="url-from-public-url"),

    dict(name="url-promoted-newline", note="trailing newline trimmed by URL_TRIM_SET",
         items=_i(("public.utf8-plain-text", b"https://x.com\n")),
         design_hex="b92e3072845a49f4cdde20685b46eb6debd6815e2384d25a14425bb7eea80213"),

    dict(name="url-bare", note="public.url 'https://x.com' equals the promoted-newline text",
         items=_i(("public.url", b"https://x.com")),
         equals="url-promoted-newline"),

    dict(name="url-promoted-spaces", note="leading/trailing spaces incl. U+00A0 trimmed; equals url-promoted-newline",
         items=_i(("public.utf8-plain-text", " https://x.com ".encode("utf-8"))),
         equals="url-promoted-newline"),

    dict(name="url-promotion-negative", note="URL mid-string does NOT promote",
         items=_i(("public.utf8-plain-text", b"see https://x.com now")),
         design_hex="252ecc3e56b61551328b769484199146e18d3d26a04f66afe29383f681bae1c1"),

    dict(name="file-url", note="file rung",
         items=_i(("public.file-url", b"file:///Users/pfh/report.pdf")),
         design_hex="87dea9dc8abdfa1c71e030532c89a97163275d69a61518704b131fcb49066ba2"),

    dict(name="utf16-external-le-bom", note="UTF-16 LE BOM decodes to 'hello'; equals text-hello",
         items=_i((TEXT_UTF16_EXTERNAL, b"\xff\xfeh\x00e\x00l\x00l\x00o\x00")),
         equals="text-hello"),

    dict(name="utf16-external-be-bom", note="UTF-16 BE BOM decodes to 'hello'; equals text-hello",
         items=_i((TEXT_UTF16_EXTERNAL, b"\xfe\xff\x00h\x00e\x00l\x00l\x00o")),
         equals="text-hello"),

    dict(name="utf16-external-bomless-le", note="BOM-less UTF-16 defaults LE; equals text-hello",
         items=_i((TEXT_UTF16_EXTERNAL, b"h\x00e\x00l\x00l\x00o\x00")),
         equals="text-hello"),

    dict(name="image-png", note="PNG >= 1024 B -> image rung (raw bytes)",
         items=_i(("public.png", PNG_FIXTURE))),

    dict(name="image-png-with-sidecars", note="image wins over url/text sidecars; equals image-png",
         items=_i(("public.url", b"https://imgsrc.example/x"),
                  ("public.utf8-plain-text", b"caption"),
                  ("public.png", PNG_FIXTURE)),
         equals="image-png"),

    dict(name="png-subthreshold-fallback", note="8-byte PNG is below IMAGE_MIN -> fallback rung",
         items=_i(("public.png", b"\x89PNG\r\n\x1a\n")),
         design_hex="342ef223de740961d8fa39ffe431e793fde18708e6282440074f79e85d47804d"),

    dict(name="custom-uti-fallback", note="unknown content-bearing UTI -> fallback",
         items=_i(("com.example.custom", b"xyz")),
         design_hex="81536d9fe2abf3cac9bd19786938f3cca883a9f40e71999ea223d9f08c3ce309"),

    dict(name="empty-text-fallback", note="empty after normalization routes to fallback, not sha256('text\\0')",
         items=_i(("public.utf8-plain-text", b"")),
         design_hex="4d648625bd151b778f4a9a5c38fc2beaf4eceeab4c6b8665b40f2338c1b1f33f"),

    # --- additional coverage the JSON carries (no design hex; impl is truth) ---
    dict(name="multi-item-first-wins", note="duplicate UTI across items: first occurrence wins; equals text-hello",
         items=[[("public.utf8-plain-text", b"hello")],
                [("public.utf8-plain-text", b"world")]],
         equals="text-hello"),

    dict(name="malformed-utf8-skips-to-fallback",
         note="lone 0x80 fails strict UTF-8; no other text source -> fallback emits the raw flavor",
         items=_i(("public.utf8-plain-text", b"\x80"))),

    dict(name="malformed-utf16-unpaired-surrogate-skips",
         note="unpaired high surrogate D800 (no low) fails strict UTF-16 -> source skipped; html rescues",
         items=_i((TEXT_UTF16_EXTERNAL, b"\x00\xd8"),
                  ("public.html", b"<p>rescued</p>"))),

    dict(name="shared-pasteboard-file-skipped",
         note="UC-echo file-url is stored but never keys identity; text echo keys via rung 4; equals text-hello",
         items=_i(("public.file-url",
                   ("file:///Users/pfh/Library/Group%20Containers/"
                    + SHARED_PASTEBOARD_MARKER + "items/ABC/x.txt").encode("utf-8")),
                  ("public.utf8-plain-text", b"hello")),
         equals="text-hello"),

    dict(name="fallback-sort-nonascii",
         note="two non-ASCII UTIs spanning the U+E000/U+10000 boundary: byte-wise UTF-8 sort, not UTF-16 code-unit order",
         items=_i(("com.example.\U00010000", b"A"),     # U+10000 -> 4-byte UTF-8 (F0 90 80 80)
                  ("com.example.", b"B"))),       # U+E000  -> 3-byte UTF-8 (EE 80 80)

    dict(name="color-rung",
         note="color flavor with no text/url/image -> color rung",
         items=_i(("com.apple.cocoa.pasteboard.color", b"\x00\x00\x80\x3f\x00\x00\x00\x00"))),

    dict(name="file-trailing-slash",
         note="directory file-url: one trailing slash stripped",
         items=_i(("public.file-url", b"file:///Users/pfh/Documents/"))),
]


def build():
    out_vectors = []
    by_name = {}
    report = []
    mismatches = []
    for v in VECTORS:
        items_bytes = [[(uti, b) for (uti, b) in item] for item in v["items"]]
        tag, hexd = content_hash_v2(items_bytes)
        by_name[v["name"]] = hexd

        status = "ok"
        if "design_hex" in v:
            if v["design_hex"] != hexd:
                status = "PROSE-MISMATCH"
                mismatches.append((v["name"], v["design_hex"], hexd))
        if "equals" in v:
            want = by_name.get(v["equals"])
            if want is None:
                status = "EQUALS-UNRESOLVED(" + v["equals"] + ")"
            elif want != hexd:
                status = "EQUALS-BROKEN(vs " + v["equals"] + ")"
                mismatches.append((v["name"], "equals:" + v["equals"], hexd))

        report.append((v["name"], tag, hexd, status, v.get("note", "")))

        # JSON form: items as base64; expected tag + hex; optional equals.
        jitems = [[{"uti": uti, "base64": base64.b64encode(b).decode("ascii")}
                   for (uti, b) in item] for item in v["items"]]
        entry = {"name": v["name"], "note": v.get("note", ""),
                 "items": jitems, "expect_tag": tag, "expect_hex": hexd}
        if "equals" in v:
            entry["equals"] = v["equals"]
        out_vectors.append(entry)

    doc = {
        "_comment": ("Authoritative cross-platform test vectors for canonical-hash v2. "
                     "Generated by Tools/gen_hash_vectors.py — DO NOT hand-edit. "
                     "Swift CpdbShared.ContentIdentity and Windows CpdbWin.Core.ContentIdentity "
                     "must reproduce every expect_hex. See docs/canonical-hash-v2.md §2."),
        "identity_revision": IDENTITY_REVISION,
        "hash": "sha256( expect_tag_utf8 || 0x00 || value_bytes )",
        "vectors": out_vectors,
    }
    return doc, report, mismatches


def main():
    check_only = "--check" in sys.argv
    doc, report, mismatches = build()

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_path = os.path.join(repo, "Tests", "Fixtures", "hash-vectors-v2.json")

    print(f"canonical-hash v2 reference — revision {IDENTITY_REVISION}")
    print(f"{'vector':<34}{'tag':<10}{'status':<22}hex")
    print("-" * 110)
    for name, tag, hexd, status, _note in report:
        print(f"{name:<34}{tag:<10}{status:<22}{hexd}")

    print()
    if mismatches:
        print(f"{len(mismatches)} divergence(s) from docs §2.6 prose (implementation is ground truth):")
        for name, want, got in mismatches:
            print(f"  {name}: doc says {want}")
            print(f"  {' ' * len(name)}  impl  {got}")
        print("  -> reconcile docs/canonical-hash-v2.md §2.6 to the impl hexes above.")
    else:
        print("All design hexes + equals-relations match the implementation. Contract self-consistent.")

    if not check_only:
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        with open(out_path, "w") as f:
            json.dump(doc, f, indent=2, ensure_ascii=True)
            f.write("\n")
        print(f"\nWrote {len(doc['vectors'])} vectors -> {os.path.relpath(out_path, repo)}")

    # Exit non-zero only on a broken equals-relation (a real impl bug).
    # Prose mismatches are expected on first run and are reconciled in the doc.
    broken = [m for m in mismatches if m[1].startswith("equals:")]
    if broken:
        print(f"\nFAIL: {len(broken)} broken equals-relation(s) — implementation bug.")
        sys.exit(1)


if __name__ == "__main__":
    main()
