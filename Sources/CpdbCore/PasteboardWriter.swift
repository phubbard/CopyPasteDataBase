#if os(macOS)
import Foundation
import AppKit
import GRDB
import CpdbShared

/// Rebuilds an entry into `NSPasteboardItem`s and writes it to a pasteboard.
///
/// Extracted from `Restorer` so the app can pull in just this API without
/// the surrounding CLI restore surface.
public struct PasteboardWriter {
    public let store: Store
    public let blobs: BlobStore

    public init(store: Store, blobs: BlobStore = BlobStore()) {
        self.store = store
        self.blobs = blobs
    }

    public enum WriterError: Error, CustomStringConvertible {
        case entryNotFound(Int64)
        /// The entry exists but its body bytes were discarded by an
        /// eviction policy. Metadata + thumbnail are still present
        /// but there's nothing to put on NSPasteboard.
        case bodyEvicted(Int64)
        public var description: String {
            switch self {
            case .entryNotFound(let id): return "no entry with id \(id)"
            case .bodyEvicted(let id):   return "entry \(id) body discarded by retention policy"
            }
        }
    }

    /// Reconstruct `NSPasteboardItem`s for an entry. Returned items are
    /// suitable to hand straight to `NSPasteboard.writeObjects(_:)`.
    ///
    /// Note: we currently fold every flavor into a single
    /// `NSPasteboardItem`. That's correct for ~99% of captures (one copy
    /// event = one pasteboard item). Multi-item copies (e.g. Finder copying
    /// two files) get merged; true multi-item fidelity waits for phase 3
    /// since it needs a second "item-group" column on `entry_flavors`.
    public func loadItems(entryId: Int64) throws -> [NSPasteboardItem] {
        struct FlavorRow { let uti: String; let data: Data?; let blobKey: String? }
        let flavors: [FlavorRow] = try store.dbQueue.read { db in
            guard let entry = try Entry.fetchOne(db, key: entryId) else {
                throw WriterError.entryNotFound(entryId)
            }
            // Body-evicted entries have no flavor rows. Surface a
            // distinct error so the caller (popup paste action,
            // CLI copy command) can tell the user the bytes are
            // gone vs. the entry never existed.
            if entry.bodyEvictedAt != nil {
                throw WriterError.bodyEvicted(entryId)
            }
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT uti, data, blob_key FROM entry_flavors WHERE entry_id = ? ORDER BY uti",
                arguments: [entryId]
            )
            return rows.map {
                FlavorRow(uti: $0["uti"], data: $0["data"], blobKey: $0["blob_key"])
            }
        }

        let item = NSPasteboardItem()
        var writtenUTIs = Set<String>()
        var urlString: String?
        for flavor in flavors {
            let bytes = try blobs.load(inline: flavor.data, blobKey: flavor.blobKey)
            item.setData(bytes, forType: NSPasteboard.PasteboardType(flavor.uti))
            writtenUTIs.insert(flavor.uti)
            if flavor.uti == "public.url", urlString == nil {
                urlString = String(data: bytes, encoding: .utf8)
            }
        }
        // Synthesize a plain-text flavor for a URL-only entry. A link
        // captured as bare `public.url` (e.g. a Universal Clipboard echo
        // of an iPhone Safari copy, landing on an idle Mac via
        // loginwindow) has no text flavor, so pasting it into a text
        // field — which reads `public.utf8-plain-text`, not
        // `public.url` — drops nothing on the page. Add the URL string
        // as plain text so it pastes everywhere. Ephemeral: this is only
        // on the pasteboard, never stored, so entry identity is
        // unchanged. (`writeObjects` natively does this for an NSURL, but
        // we rebuild from raw flavor bytes, so we do it explicitly.)
        let textUTIs: Set<String> = [
            "public.utf8-plain-text", "public.text", "public.plain-text",
            "public.utf16-external-plain-text", "public.utf16-plain-text",
        ]
        if writtenUTIs.isDisjoint(with: textUTIs),
           let url = urlString, !url.isEmpty {
            item.setData(Data(url.utf8), forType: .init("public.utf8-plain-text"))
        }
        return [item]
    }

    /// Write an entry's contents to the given pasteboard (default: general).
    public func write(entryId: Int64, to pasteboard: NSPasteboard = .general) throws {
        let items = try loadItems(entryId: entryId)
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
#endif
