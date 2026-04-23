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
        public var description: String {
            switch self {
            case .entryNotFound(let id): return "no entry with id \(id)"
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
            guard try Entry.fetchOne(db, key: entryId) != nil else {
                throw WriterError.entryNotFound(entryId)
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
        for flavor in flavors {
            let bytes = try blobs.load(inline: flavor.data, blobKey: flavor.blobKey)
            item.setData(bytes, forType: NSPasteboard.PasteboardType(flavor.uti))
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
