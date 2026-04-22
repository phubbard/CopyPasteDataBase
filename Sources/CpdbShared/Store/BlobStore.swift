import Foundation
import CryptoKit

/// Content-addressed blob store on disk, used as a spill target when a
/// pasteboard flavor is larger than `inlineThreshold` bytes.
///
/// Layout: `Paths.blobsDirectory/<ab>/<cd>/<sha256 hex>`.
public struct BlobStore {
    public static let inlineThreshold = 256 * 1024  // 256 KB

    public init() {}

    /// Returns `(data: Data?, blobKey: String?)` suitable for direct insert
    /// into `entry_flavors`. Small flavors stay inline; large ones are written
    /// to disk content-addressed and replaced with their hex key.
    public func storeForInsert(data: Data) throws -> (Data?, String?) {
        if data.count < Self.inlineThreshold {
            return (data, nil)
        }
        let key = Self.hexSHA256(data)
        let url = Paths.blobPath(forSHA256Hex: key)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: url.path) {
            // Atomic: write to temp then rename
            let tmp = url.appendingPathExtension("tmp-\(UUID().uuidString)")
            try data.write(to: tmp, options: .atomic)
            try fm.moveItem(at: tmp, to: url)
        }
        return (nil, key)
    }

    /// Loads the actual bytes for a flavor, whether inline or spilled.
    public func load(inline: Data?, blobKey: String?) throws -> Data {
        if let inline = inline { return inline }
        guard let key = blobKey else {
            throw BlobStoreError.missing
        }
        let url = Paths.blobPath(forSHA256Hex: key)
        return try Data(contentsOf: url)
    }

    public static func hexSHA256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public enum BlobStoreError: Error {
        case missing
    }
}
