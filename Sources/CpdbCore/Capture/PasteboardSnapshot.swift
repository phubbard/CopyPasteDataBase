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
    public var kind: EntryKind {
        let utis = Set(items.flatMap { $0.flavors.map(\.uti) })
        if utis.contains("public.url") || utis.contains("public.file-url") == false && utis.contains(where: { $0.hasSuffix(".source-url") || $0 == "public.url-name" }) {
            // Prefer link when we have an explicit URL flavor but not a file URL.
            if utis.contains("public.url") { return .link }
        }
        if utis.contains("public.file-url") { return .file }
        if utis.contains(where: { $0.hasPrefix("public.png") || $0.hasPrefix("public.jpeg") || $0.hasPrefix("public.tiff") || $0 == "public.image" }) {
            return .image
        }
        if utis.contains("com.apple.cocoa.pasteboard.color") || utis.contains("public.color") {
            return .color
        }
        if plainText != nil { return .text }
        return .other
    }
}
