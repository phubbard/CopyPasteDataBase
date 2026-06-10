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
    ///
    /// Stores every published flavor verbatim — capture fidelity is a core
    /// product value, and under canonical-hash v2 identity is computed from
    /// the primary content only, so transport/provenance sidecars
    /// (`com.apple.is-remote-clipboard`, Chromium tokens, linkpresentation
    /// metadata) are hash-invisible by construction and safe to keep. The
    /// pre-v2 `metadataOnlyUTIs` capture-time strip is gone: v2 removes the
    /// pressure v1 created to discard provenance before storage.
    ///
    /// One capture-time rewrite (docs/canonical-hash-v2.md §2.4): Finder
    /// publishes file-REFERENCE URLs (`file:///.file/id=…`) whose id-form
    /// is volatile across machines. We resolve them to path URLs BEFORE
    /// storage so the recompute-from-storage invariant holds for file
    /// entries and reference-vs-path copies of the same file converge.
    /// Resolution is only possible while the file exists, which is exactly
    /// the capture moment.
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> PasteboardSnapshot? {
        guard let items = pb.pasteboardItems, !items.isEmpty else { return nil }
        let snapshotItems: [Item] = items.map { nsItem in
            var flavors: [CanonicalHash.Flavor] = []
            flavors.reserveCapacity(nsItem.types.count)
            for type in nsItem.types {
                guard var data = nsItem.data(forType: type) else { continue }
                if type.rawValue == "public.file-url" {
                    data = Self.resolveFileReferenceURL(data)
                }
                flavors.append(.init(uti: type.rawValue, data: data))
            }
            return Item(flavors: flavors)
        }
        return PasteboardSnapshot(items: snapshotItems)
    }

    /// Resolve a Finder file-reference URL (`file:///.file/id=…`) to its
    /// path form. Returns the original bytes when the flavor isn't a
    /// reference URL, isn't decodable, or the file no longer exists
    /// (resolution needs the live file).
    internal static func resolveFileReferenceURL(_ data: Data) -> Data {
        guard let s = String(data: data, encoding: .utf8),
              s.hasPrefix("file:///.file/id="),
              let refURL = URL(string: s),
              let resolved = (refURL as NSURL).filePathURL
        else { return data }
        return Data(resolved.absoluteString.utf8)
    }
}
#endif
