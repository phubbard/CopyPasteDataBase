import Foundation
import AppKit

/// A captured pasteboard state: one or more items, each with all UTIs the
/// source app chose to publish. Pulled out of AppKit so the ingestion path
/// can be unit-tested without touching a real NSPasteboard.
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

    /// Build a snapshot from the current contents of the given pasteboard.
    /// Returns nil if the pasteboard has no readable items.
    public static func fromPasteboard(_ pb: NSPasteboard = .general) -> PasteboardSnapshot? {
        guard let items = pb.pasteboardItems, !items.isEmpty else { return nil }
        let snapshotItems: [Item] = items.map { nsItem in
            var flavors: [CanonicalHash.Flavor] = []
            flavors.reserveCapacity(nsItem.types.count)
            for type in nsItem.types {
                if let data = nsItem.data(forType: type) {
                    flavors.append(.init(uti: type.rawValue, data: data))
                }
            }
            return Item(flavors: flavors)
        }
        return PasteboardSnapshot(items: snapshotItems)
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
