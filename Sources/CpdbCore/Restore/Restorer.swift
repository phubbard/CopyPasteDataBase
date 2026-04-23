#if os(macOS)
import Foundation
import AppKit
import CpdbShared

/// Backwards-compatible restore API. All the real work now lives in
/// `PasteboardWriter`; this type stays so existing CLI callers and tests
/// don't have to change.
public struct Restorer {
    public let writer: PasteboardWriter

    public init(store: Store, blobs: BlobStore = BlobStore()) {
        self.writer = PasteboardWriter(store: store, blobs: blobs)
    }

    public enum RestoreError: Error, CustomStringConvertible {
        case entryNotFound(Int64)
        public var description: String {
            switch self {
            case .entryNotFound(let id): return "no entry with id \(id)"
            }
        }
    }

    public func loadPasteboardItems(entryId: Int64) throws -> [NSPasteboardItem] {
        do {
            return try writer.loadItems(entryId: entryId)
        } catch PasteboardWriter.WriterError.entryNotFound(let id) {
            throw RestoreError.entryNotFound(id)
        }
    }

    public func restoreToPasteboard(entryId: Int64, pasteboard: NSPasteboard = .general) throws {
        do {
            try writer.write(entryId: entryId, to: pasteboard)
        } catch PasteboardWriter.WriterError.entryNotFound(let id) {
            throw RestoreError.entryNotFound(id)
        }
    }
}
#endif
