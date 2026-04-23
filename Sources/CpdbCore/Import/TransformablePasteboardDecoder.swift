#if os(macOS)
import Foundation
import CpdbShared

/// Decodes the `ZSNIPPETDATA.ZPASTEBOARDITEMS` BLOB from a Paste (`com.wiheads.paste`)
/// database back into a concrete `[PasteboardSnapshot.Item]`.
///
/// Paste uses a Core Data `transformable` attribute with "Allows External
/// Storage" enabled. That means the row can encode its payload in one of two
/// ways, distinguished by the first byte:
///
/// - `0x01` — inline. What follows is a standard `bplist00` NSKeyedArchiver
///   payload.
/// - `0x02` — external. What follows is the ASCII UUID of a file stored in
///   `<Database>_SUPPORT/.Paste_SUPPORT/_EXTERNAL_DATA/<UUID>` (the file
///   itself is a plain `bplist00`).
///
/// The archived graph's root is an `NSArray<NSDictionary>` with the shape:
///
///     { "types": NSArray<NSString>,   // UTI list, authoritative order
///       "data":  NSDictionary<NSString: NSData> }  // UTI → bytes
///
/// Strings stored as URLs sometimes land as `NSString` instead of `NSData`;
/// we coerce those to UTF-8 bytes.
public struct TransformablePasteboardDecoder {

    public enum DecodeError: Error, CustomStringConvertible {
        case emptyBlob
        case unexpectedTopLevel(String)
        case itemShape(String)
        case keyedUnarchiverFailed(Error)
        case externalRefMissing(uuid: String, at: URL)
        case externalRefMalformed(String)

        public var description: String {
            switch self {
            case .emptyBlob: return "transformable blob is empty"
            case .unexpectedTopLevel(let s): return "unexpected top-level object: \(s)"
            case .itemShape(let s): return "malformed item dict: \(s)"
            case .keyedUnarchiverFailed(let e): return "NSKeyedUnarchiver failed: \(e)"
            case .externalRefMissing(let uuid, let url):
                return "external ref \(uuid) not found at \(url.path)"
            case .externalRefMalformed(let s):
                return "external ref not a UUID: \(s)"
            }
        }
    }

    /// Directory containing Paste's external binary storage. Typically:
    /// `~/Library/Application Support/com.wiheads.paste/.Paste_SUPPORT/_EXTERNAL_DATA/`.
    /// Passed in so the decoder has no filesystem assumptions of its own.
    public let externalDataDirectory: URL

    public init(externalDataDirectory: URL) {
        self.externalDataDirectory = externalDataDirectory
    }

    /// Resolve `externalDataDirectory` from the Paste.db path: sibling
    /// `.Paste_SUPPORT/_EXTERNAL_DATA`.
    public static func externalDataDirectory(forPasteDatabase path: URL) -> URL {
        path.deletingLastPathComponent()
            .appendingPathComponent(".Paste_SUPPORT", isDirectory: true)
            .appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
    }

    /// Returns the decoded pasteboard items from a raw `ZPASTEBOARDITEMS` blob.
    public func decode(_ raw: Data) throws -> [PasteboardSnapshot.Item] {
        guard !raw.isEmpty else { throw DecodeError.emptyBlob }
        let payload = try resolveInlinePayload(raw)
        return try Self.decodeBplistPayload(payload)
    }

    /// Turn a row blob into the actual bplist bytes. Handles both inline
    /// (`0x01` prefix) and external (`0x02` prefix) storage.
    func resolveInlinePayload(_ raw: Data) throws -> Data {
        let first = raw[raw.startIndex]
        switch first {
        case 0x01:
            // Inline — skip the marker byte, rest is bplist.
            let rest = raw.subdata(in: raw.startIndex.advanced(by: 1) ..< raw.endIndex)
            // Some Paste rows in the wild are truncated to just the prefix byte.
            // Treat them as empty so the importer reports them as skipped, not failed.
            if rest.isEmpty { throw DecodeError.emptyBlob }
            return rest
        case 0x02:
            // External — rest is an ASCII UUID string. Some versions append
            // a trailing NUL or whitespace; trim both.
            let tail = raw.subdata(in: raw.startIndex.advanced(by: 1) ..< raw.endIndex)
            guard var uuid = String(data: tail, encoding: .ascii) else {
                throw DecodeError.externalRefMalformed("non-ASCII tail")
            }
            uuid = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
                       .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            guard UUID(uuidString: uuid) != nil else {
                throw DecodeError.externalRefMalformed(uuid)
            }
            let url = externalDataDirectory.appendingPathComponent(uuid, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw DecodeError.externalRefMissing(uuid: uuid, at: url)
            }
            return try Data(contentsOf: url)
        default:
            // Some old rows might be raw bplist without a prefix. Accept that too.
            if raw.count >= 8,
               raw[raw.startIndex ..< raw.startIndex.advanced(by: 7)] == Data("bplist0".utf8) {
                return raw
            }
            throw DecodeError.unexpectedTopLevel("leading byte 0x\(String(format: "%02x", first))")
        }
    }

    /// Decode an already-unwrapped bplist payload into concrete items.
    ///
    /// Paste archives each item as its own `PasteCore.PasteboardItem` class,
    /// not `NSDictionary`. The class has two keyed ivars — `types` (NSArray)
    /// and `data` (NSDictionary). To decode without linking Paste, we
    /// register a shim class that implements `NSCoding.init(coder:)` the way
    /// Paste did.
    static func decodeBplistPayload(_ payload: Data) throws -> [PasteboardSnapshot.Item] {
        let unarchiver: NSKeyedUnarchiver
        do {
            unarchiver = try NSKeyedUnarchiver(forReadingFrom: payload)
        } catch {
            throw DecodeError.keyedUnarchiverFailed(error)
        }
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(PasteCoreItemShim.self, forClassName: "PasteCore.PasteboardItem")
        unarchiver.setClass(PasteCoreItemShim.self, forClassName: "Paste.PasteboardItem")

        let top = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        if let err = unarchiver.error {
            throw DecodeError.keyedUnarchiverFailed(err)
        }

        guard let nsItems = top as? [Any] else {
            throw DecodeError.unexpectedTopLevel("\(type(of: top))")
        }

        var items: [PasteboardSnapshot.Item] = []
        items.reserveCapacity(nsItems.count)

        for (idx, rawItem) in nsItems.enumerated() {
            guard let shim = rawItem as? PasteCoreItemShim else {
                throw DecodeError.itemShape("item \(idx) is \(type(of: rawItem)) not PasteCoreItemShim")
            }
            guard let dataDict = shim.data else {
                throw DecodeError.itemShape("item \(idx) has no data dict")
            }

            var flavors: [CanonicalHash.Flavor] = []
            flavors.reserveCapacity(dataDict.count)

            for (rawKey, anyVal) in dataDict {
                guard let uti = rawKey as? String else {
                    throw DecodeError.itemShape("item \(idx) non-string UTI key \(type(of: rawKey))")
                }
                if let nsData = anyVal as? Data {
                    flavors.append(.init(uti: uti, data: nsData))
                } else if let s = anyVal as? String {
                    flavors.append(.init(uti: uti, data: Data(s.utf8)))
                } else {
                    throw DecodeError.itemShape("item \(idx) uti \(uti) has non-Data value: \(type(of: anyVal))")
                }
            }

            items.append(.init(flavors: flavors))
        }

        return items
    }
}

/// Stand-in for `PasteCore.PasteboardItem`. Registered with `NSKeyedUnarchiver`
/// via `setClass(_:forClassName:)` so we can decode Paste's archived items
/// without linking against Paste's own framework.
@objc(PasteCoreItemShim)
final class PasteCoreItemShim: NSObject, NSCoding {
    let types: NSArray?
    let data: NSDictionary?

    init(types: NSArray?, data: NSDictionary?) {
        self.types = types
        self.data = data
    }

    required init?(coder: NSCoder) {
        // Paste wrote `coder.encode(types, forKey: "types")` and `coder.encode(data, forKey: "data")`.
        // Use non-secure decoding — we've already loosened requiresSecureCoding for this path.
        self.types = coder.decodeObject(forKey: "types") as? NSArray
        self.data  = coder.decodeObject(forKey: "data")  as? NSDictionary
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(types, forKey: "types")
        coder.encode(data,  forKey: "data")
    }
}
#endif
