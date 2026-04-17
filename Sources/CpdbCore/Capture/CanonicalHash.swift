import Foundation
import CryptoKit

/// Canonical, order-independent SHA-256 hash over a sequence of pasteboard
/// items. Used as the dedup key in `entries.content_hash`.
///
/// The canonical form is:
///
/// ```
/// sha256(
///   for each item in items:       // items in original order
///     for each uti in SORTED(item.types):
///       uti.utf8 || 0x00 || uint64_be(data.count) || data
///     0x01                        // item separator
/// )
/// ```
///
/// Sorting UTIs within an item removes sensitivity to the order macOS gives us
/// back from NSPasteboardItem (which can vary across versions). The item
/// separator (`0x01`) prevents ambiguity between `[ {A}, {B} ]` and `[ {A,B} ]`.
public enum CanonicalHash {
    public struct Flavor: Sendable, Hashable {
        public var uti: String
        public var data: Data
        public init(uti: String, data: Data) {
            self.uti = uti
            self.data = data
        }
    }

    public static func hash(items: [[Flavor]]) -> Data {
        var hasher = SHA256()
        for item in items {
            let sorted = item.sorted { $0.uti < $1.uti }
            for flavor in sorted {
                hasher.update(data: Data(flavor.uti.utf8))
                hasher.update(data: Data([0x00]))
                var lenBE = UInt64(flavor.data.count).bigEndian
                withUnsafeBytes(of: &lenBE) { hasher.update(bufferPointer: $0) }
                hasher.update(data: flavor.data)
            }
            hasher.update(data: Data([0x01]))
        }
        return Data(hasher.finalize())
    }

    /// Convenience hex string for logging/debugging.
    public static func hex(_ hash: Data) -> String {
        hash.map { String(format: "%02x", $0) }.joined()
    }
}
