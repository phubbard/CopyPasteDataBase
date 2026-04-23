import Foundation

/// A captured pasteboard state: one or more items, each with all UTIs the
/// source app chose to publish.
///
/// Pure data — no AppKit dependency. The macOS-side factory
/// `fromPasteboard(_:)` lives in `CpdbCore/Capture/PasteboardSnapshot+AppKit.swift`.
/// iOS consumers (syncer, search UI) work on already-decoded snapshots
/// fetched from CloudKit or local storage.
public struct PasteboardSnapshot: Sendable {
    public struct Item: Sendable {
        public var flavors: [CanonicalHash.Flavor]
        public init(flavors: [CanonicalHash.Flavor]) {
            self.flavors = flavors
        }
    }

    public var items: [Item]
    public var capturedAt: Date

    public init(items: [Item], capturedAt: Date = Date()) {
        self.items = items
        self.capturedAt = capturedAt
    }

    public var totalSize: Int64 {
        items.reduce(0) { acc, item in
            acc + item.flavors.reduce(0) { $0 + Int64($1.data.count) }
        }
    }

    public var flavorItemsForHashing: [[CanonicalHash.Flavor]] {
        items.map { $0.flavors }
    }

    /// Extract the best plain-text representation for search / display.
    ///
    /// Preference order:
    ///   1. UTF-8 plain text flavors — the dominant modern format.
    ///   2. UTF-16 variants — old Cocoa apps still emit these.
    ///   3. `public.url` / `public.file-url` bytes decoded as UTF-8.
    ///      Some sources (notably iOS share-sheet → Copy bridged to the
    ///      Mac via Universal Clipboard) arrive with ONLY a URL flavor
    ///      and no separate plain-text flavor. Without this fallback
    ///      the entry lands in SQLite with `text_preview=NULL` and
    ///      renders as an empty LinkCard.
    ///   4. `public.url-name` — human-readable title that sometimes
    ///      accompanies a URL. Last resort because it may be empty
    ///      while the URL itself is present.
    public var plainText: String? {
        for item in items {
            for flavor in item.flavors {
                if flavor.uti == "public.utf8-plain-text" || flavor.uti == "public.plain-text" {
                    if let s = String(data: flavor.data, encoding: .utf8) { return s }
                }
                if flavor.uti == "public.utf16-external-plain-text" || flavor.uti == "public.utf16-plain-text" {
                    if let s = String(data: flavor.data, encoding: .utf16) { return s }
                }
            }
        }
        // Fallback #1: a URL flavor carried without a text shadow.
        for item in items {
            for flavor in item.flavors where flavor.uti == "public.url" || flavor.uti == "public.file-url" {
                if let s = String(data: flavor.data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !s.isEmpty
                {
                    return s
                }
            }
        }
        // Fallback #2: a URL's human-readable name.
        for item in items {
            for flavor in item.flavors where flavor.uti == "public.url-name" {
                if let s = String(data: flavor.data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !s.isEmpty
                {
                    return s
                }
            }
        }
        return nil
    }

    /// Raw bytes of the best image flavor, or nil if there isn't one.
    ///
    /// Preference order mirrors macOS's decoding reliability: PNG first
    /// (lossless, ubiquitous), then JPEG, TIFF, HEIC. Used by the daemon
    /// to generate thumbnails on capture — see `Thumbnailer` / `Ingestor`.
    public var imageFlavorData: Data? {
        let priority = ["public.png", "public.jpeg", "public.tiff", "public.heic", "public.image"]
        for uti in priority {
            for item in items {
                for flavor in item.flavors where flavor.uti == uti {
                    return flavor.data
                }
            }
        }
        return nil
    }

    /// True iff the snapshot's plain-text content matches Apple's "Strong
    /// Password" format: three hyphen-separated groups of exactly six
    /// alphanumeric characters (total length 20). Used as a safety net
    /// when frontmost-app-history heuristics miss a Passwords-app copy.
    ///
    /// The format is proprietary and stable enough that false positives are
    /// vanishingly unlikely. Apple's memorable-password format (`word_word_Word`)
    /// is a separate shape we do **not** filter on here — those are long
    /// enough and varied enough that frontmost-app history reliably catches
    /// them, and matching on them risks flagging real content.
    public var looksLikeApplePassword: Bool {
        guard let raw = plainText else { return false }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count == 20 else { return false }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ $0.count == 6 }) else { return false }
        return parts.allSatisfy { part in
            part.allSatisfy { c in
                c.isASCII && (c.isLetter || c.isNumber)
            }
        }
    }

    /// Classify the snippet using a tiered heuristic against the UTIs present.
    ///
    /// Image detection wins over file-url when there's a *substantive* image
    /// flavor (>= 1 KB). This handles screenshot tools like CleanShot that
    /// put both `public.file-url` and `public.png` on the pasteboard: the
    /// PNG bytes are the payload, the file-url is just breadcrumb metadata,
    /// so we want to treat it as an image (thumbnail, image preview) rather
    /// than a file reference that depends on the file still existing.
    ///
    /// Files copied from Finder *without* inline image bytes keep `kind=file`
    /// — those legitimately want file-reference rendering.
    public var kind: EntryKind {
        let utis = Set(items.flatMap { $0.flavors.map(\.uti) })
        if utis.contains("public.url") || utis.contains("public.file-url") == false && utis.contains(where: { $0.hasSuffix(".source-url") || $0 == "public.url-name" }) {
            if utis.contains("public.url") { return .link }
        }
        if hasSubstantiveImageFlavor { return .image }
        if utis.contains("public.file-url") { return .file }
        if utis.contains("com.apple.cocoa.pasteboard.color") || utis.contains("public.color") {
            return .color
        }
        if plainText != nil { return .text }
        return .other
    }

    /// True if any flavor is an image UTI (png/jpeg/tiff/heic/image) with at
    /// least `Self.minImageBytes` bytes of payload. The threshold exists so
    /// a zero-byte placeholder flavor doesn't masquerade as the primary
    /// content.
    public var hasSubstantiveImageFlavor: Bool {
        for item in items {
            for flavor in item.flavors {
                let uti = flavor.uti
                let isImage = uti.hasPrefix("public.png")
                    || uti.hasPrefix("public.jpeg")
                    || uti.hasPrefix("public.tiff")
                    || uti == "public.heic"
                    || uti == "public.heif"
                    || uti == "public.image"
                if isImage && flavor.data.count >= Self.minImageBytes {
                    return true
                }
            }
        }
        return false
    }

    public static let minImageBytes = 1024
}
