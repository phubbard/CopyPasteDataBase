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
            // DEBUG: log every type encountered + whether we stripped it.
            // Remove once the metadata-only-UTI strip is confirmed working
            // in production. Output goes to Console.app filtered by subsystem.
            let typeNames = nsItem.types.map { $0.rawValue }
            Log.cli.info(
                "snapshot capture: types=[\(typeNames.joined(separator: ", "), privacy: .public)]"
            )
            for type in nsItem.types {
                // Skip Apple's transient metadata markers that
                // describe HOW the clipboard arrived rather than
                // WHAT it contains. Universal Clipboard tags every
                // echo with `com.apple.is-remote-clipboard` (a
                // zero-byte presence flavor); when the same content
                // is captured both locally and via an Apple-side
                // echo, the two flavor sets differ only by this
                // marker — different canonical hash, missed dedup,
                // duplicate row. Stripping the marker before
                // hashing makes both captures collapse onto one
                // entry.
                if Self.metadataOnlyUTIs.contains(type.rawValue) {
                    Log.cli.info("  → STRIP \(type.rawValue, privacy: .public)")
                    continue
                }
                if let data = nsItem.data(forType: type) {
                    flavors.append(.init(uti: type.rawValue, data: data))
                }
            }
            return Item(flavors: flavors)
        }
        return PasteboardSnapshot(items: snapshotItems)
    }

    /// UTIs whose presence on the pasteboard is transport metadata,
    /// not content. We drop them at capture time so they don't
    /// participate in `content_hash`. Add to this list cautiously —
    /// anything here becomes invisible to the hash, so two captures
    /// that differ only in these flavors will dedup as one.
    private static let metadataOnlyUTIs: Set<String> = [
        // Universal Clipboard echo marker. Set by macOS when the
        // pasteboard was sourced from another Apple device. Always
        // zero-byte; never carries content.
        "com.apple.is-remote-clipboard",
    ]
}
#endif
