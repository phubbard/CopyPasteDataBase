#if os(macOS)
import Foundation
import AppKit
import CpdbShared

/// macOS-side factory for `PasteboardSnapshot`. The pure data struct
/// lives in `CpdbShared/Capture/PasteboardSnapshot.swift`; this file adds
/// the NSPasteboard decoder the capture daemon uses.
public extension PasteboardSnapshot {
    /// Build a snapshot from the current contents of the given pasteboard.
    /// Returns nil if the pasteboard has no readable items.
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> PasteboardSnapshot? {
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
}
#endif
