import Foundation
import CloudKit

/// Translates between a local `Entry` (+ joined source-app / device
/// metadata) and a `CKRecord` of type `CKSchema.RecordType.entry`.
///
/// Thumbnails (`CKAsset`s for small + large previews) are set and read
/// separately via URL so the scalar path is pure data and fully
/// unit-testable without filesystem I/O. The caller (`CloudKitSyncer`) is
/// responsible for writing thumb bytes to tmp files on push and reading
/// tmp files on pull.
public enum EntryRecordMapper {

    // MARK: - Write path: Entry → CKRecord

    /// Source-app + device metadata that gets denormalised onto the
    /// CKRecord. The syncer looks this up in the local DB before calling
    /// the mapper; CloudKit doesn't do joins so we flatten on the way out.
    public struct SourceInfo: Sendable, Equatable {
        public var appBundleId: String?
        public var appName: String?
        public var deviceIdentifier: String
        public var deviceName: String

        public init(
            appBundleId: String? = nil,
            appName: String? = nil,
            deviceIdentifier: String,
            deviceName: String
        ) {
            self.appBundleId = appBundleId
            self.appName = appName
            self.deviceIdentifier = deviceIdentifier
            self.deviceName = deviceName
        }
    }

    /// The canonical CKRecord.ID for an Entry: derived from its
    /// `contentHash` (SHA-256, 32 bytes → 64 hex chars). Two devices
    /// that independently captured the same content produce the
    /// identical recordID and converge on a single server record with
    /// last-write-wins semantics. This is v2.1 of the wire format —
    /// v2.0 used `entry-<uuid-hex>` which produced one record per
    /// device per content, tripling storage and triggering batch
    /// conflicts during concurrent pushes. Orphan v2.0 records stay
    /// on the server until a future GC removes them.
    public static func recordID(forContentHash hash: Data, in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        let name = hash.map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "entry-\(name)", zoneID: zoneID)
    }

    /// Populate a fresh (or existing) CKRecord with the entry's scalar
    /// fields + source info. Caller attaches thumbnails separately via
    /// `setThumbnails(on:smallURL:largeURL:)`.
    ///
    /// Passing an existing CKRecord (rather than creating one here) lets
    /// the syncer preserve the server's `recordChangeTag` for optimistic
    /// locking — critical for CloudKit's conflict resolution.
    public static func populate(
        record: CKRecord,
        entry: Entry,
        source: SourceInfo
    ) {
        record[CKSchema.EntryField.uuid]        = entry.uuid as NSData
        record[CKSchema.EntryField.createdAt]   = entry.createdAt  as NSNumber
        record[CKSchema.EntryField.capturedAt]  = entry.capturedAt as NSNumber
        record[CKSchema.EntryField.kind]        = entry.kind.rawValue as NSString
        record[CKSchema.EntryField.contentHash] = entry.contentHash as NSData
        record[CKSchema.EntryField.totalSize]   = entry.totalSize   as NSNumber

        record[CKSchema.EntryField.title]        = entry.title as NSString?
        record[CKSchema.EntryField.textPreview]  = entry.textPreview as NSString?
        record[CKSchema.EntryField.deletedAt]    = entry.deletedAt.map { $0 as NSNumber }
        record[CKSchema.EntryField.ocrText]      = entry.ocrText    as NSString?
        record[CKSchema.EntryField.imageTags]    = entry.imageTags  as NSString?
        record[CKSchema.EntryField.analyzedAt]   = entry.analyzedAt.map { $0 as NSNumber }

        record[CKSchema.EntryField.sourceAppBundleId] = source.appBundleId as NSString?
        record[CKSchema.EntryField.sourceAppName]     = source.appName     as NSString?
        record[CKSchema.EntryField.deviceIdentifier]  = source.deviceIdentifier as NSString
        record[CKSchema.EntryField.deviceName]        = source.deviceName       as NSString
        // v2.6: pin state. Stored as Int64 0/1 — CKRecord has no
        // native Bool type. Pre-2.6 clients see this field as
        // missing-or-nil and treat it as unpinned, the safe default.
        record[CKSchema.EntryField.pinned] = (entry.pinned ? 1 : 0) as NSNumber
        record[CKSchema.EntryField.bodyEvictedAt] = entry.bodyEvictedAt.map { $0 as NSNumber }
        record[CKSchema.EntryField.linkTitle]     = entry.linkTitle as NSString?
        record[CKSchema.EntryField.linkFetchedAt] = entry.linkFetchedAt.map { $0 as NSNumber }
    }

    /// Attach thumbnail `CKAsset`s to the record. Pass nil URLs to clear
    /// an existing asset. The caller owns the lifetime of the temp files —
    /// CloudKit uploads the contents during `CKModifyRecordsOperation`
    /// and the files can be removed once the op completes.
    public static func setThumbnails(
        on record: CKRecord,
        smallURL: URL?,
        largeURL: URL?
    ) {
        record[CKSchema.EntryField.thumbSmall] = smallURL.map { CKAsset(fileURL: $0) }
        record[CKSchema.EntryField.thumbLarge] = largeURL.map { CKAsset(fileURL: $0) }
    }

    // MARK: - Read path: CKRecord → Decoded

    /// Decoded form of a pulled CKRecord. Intentionally not an `Entry` —
    /// `Entry.id` / `sourceAppId` / `sourceDeviceId` are local-DB
    /// foreign keys the mapper can't produce. The syncer takes this
    /// struct, upserts `apps` + `devices` rows, and inserts a local
    /// `Entry` with the resolved ids.
    public struct Decoded: Sendable, Equatable {
        public var uuid: Data
        public var createdAt: Double
        public var capturedAt: Double
        public var kind: EntryKind
        public var title: String?
        public var textPreview: String?
        public var contentHash: Data
        public var totalSize: Int64
        public var deletedAt: Double?
        public var ocrText: String?
        public var imageTags: String?
        public var analyzedAt: Double?
        public var source: SourceInfo
        public var thumbSmallURL: URL?
        public var thumbLargeURL: URL?
        /// Defaults to false when the CKRecord predates v2.6 and has
        /// no `pinned` field — treats missing as "not pinned."
        public var pinned: Bool = false
        /// Set on the originating device when the eviction policy
        /// discarded body bytes. Other devices use it to skip
        /// re-hydrating the body on pull. Nil for entries whose
        /// bodies are still on the originating device, or for
        /// pre-v2.6.2 records.
        public var bodyEvictedAt: Double?
        /// Background-fetched link title (v2.7+). Nil when never
        /// fetched OR fetched but page had no title.
        public var linkTitle: String?
        /// Sentinel for "did any device successfully attempt this
        /// fetch?" (v2.7+). Nil = no device has tried; non-nil =
        /// at least one device completed an attempt.
        public var linkFetchedAt: Double?
    }

    public enum DecodeError: Error, CustomStringConvertible {
        case missingField(String)
        case invalidField(String, reason: String)

        public var description: String {
            switch self {
            case .missingField(let name):
                return "CKRecord missing required field \(name)"
            case .invalidField(let name, let reason):
                return "CKRecord field \(name) is invalid: \(reason)"
            }
        }
    }

    /// Parse a CKRecord of type `Entry` into a `Decoded`. Throws on
    /// missing required fields or a kind string we don't recognise; those
    /// are programming errors (or schema drift that should be treated as
    /// data we can't process).
    public static func decode(_ record: CKRecord) throws -> Decoded {
        guard record.recordType == CKSchema.RecordType.entry else {
            throw DecodeError.invalidField("recordType", reason: "expected \(CKSchema.RecordType.entry), got \(record.recordType)")
        }

        let uuid = try requireData(record, CKSchema.EntryField.uuid)
        let contentHash = try requireData(record, CKSchema.EntryField.contentHash)
        let createdAt = try requireDouble(record, CKSchema.EntryField.createdAt)
        let capturedAt = try requireDouble(record, CKSchema.EntryField.capturedAt)
        let kindRaw = try requireString(record, CKSchema.EntryField.kind)
        guard let kind = EntryKind(rawValue: kindRaw) else {
            throw DecodeError.invalidField(CKSchema.EntryField.kind, reason: "unknown kind '\(kindRaw)'")
        }
        let totalSize = try requireInt64(record, CKSchema.EntryField.totalSize)

        let deviceIdentifier = try requireString(record, CKSchema.EntryField.deviceIdentifier)
        let deviceName = (record[CKSchema.EntryField.deviceName] as? String) ?? deviceIdentifier

        let source = SourceInfo(
            appBundleId: record[CKSchema.EntryField.sourceAppBundleId] as? String,
            appName:     record[CKSchema.EntryField.sourceAppName] as? String,
            deviceIdentifier: deviceIdentifier,
            deviceName: deviceName
        )

        let smallAsset = record[CKSchema.EntryField.thumbSmall] as? CKAsset
        let largeAsset = record[CKSchema.EntryField.thumbLarge] as? CKAsset

        return Decoded(
            uuid: uuid,
            createdAt: createdAt,
            capturedAt: capturedAt,
            kind: kind,
            title:        record[CKSchema.EntryField.title] as? String,
            textPreview:  record[CKSchema.EntryField.textPreview] as? String,
            contentHash: contentHash,
            totalSize: totalSize,
            deletedAt:   (record[CKSchema.EntryField.deletedAt] as? NSNumber)?.doubleValue,
            ocrText:      record[CKSchema.EntryField.ocrText] as? String,
            imageTags:    record[CKSchema.EntryField.imageTags] as? String,
            analyzedAt:  (record[CKSchema.EntryField.analyzedAt] as? NSNumber)?.doubleValue,
            source: source,
            thumbSmallURL: smallAsset?.fileURL,
            thumbLargeURL: largeAsset?.fileURL,
            pinned: ((record[CKSchema.EntryField.pinned] as? NSNumber)?.int64Value ?? 0) == 1,
            bodyEvictedAt: (record[CKSchema.EntryField.bodyEvictedAt] as? NSNumber)?.doubleValue,
            linkTitle:      record[CKSchema.EntryField.linkTitle] as? String,
            linkFetchedAt: (record[CKSchema.EntryField.linkFetchedAt] as? NSNumber)?.doubleValue
        )
    }

    // MARK: - Field extraction helpers

    private static func requireData(_ record: CKRecord, _ key: String) throws -> Data {
        guard let value = record[key] else { throw DecodeError.missingField(key) }
        if let data = value as? Data { return data }
        if let nsdata = value as? NSData { return nsdata as Data }
        throw DecodeError.invalidField(key, reason: "expected Data, got \(type(of: value))")
    }

    private static func requireString(_ record: CKRecord, _ key: String) throws -> String {
        guard let value = record[key] else { throw DecodeError.missingField(key) }
        if let s = value as? String { return s }
        if let ns = value as? NSString { return ns as String }
        throw DecodeError.invalidField(key, reason: "expected String, got \(type(of: value))")
    }

    private static func requireDouble(_ record: CKRecord, _ key: String) throws -> Double {
        guard let value = record[key] else { throw DecodeError.missingField(key) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        throw DecodeError.invalidField(key, reason: "expected Double, got \(type(of: value))")
    }

    private static func requireInt64(_ record: CKRecord, _ key: String) throws -> Int64 {
        guard let value = record[key] else { throw DecodeError.missingField(key) }
        if let n = value as? NSNumber { return n.int64Value }
        if let i = value as? Int64 { return i }
        throw DecodeError.invalidField(key, reason: "expected Int64, got \(type(of: value))")
    }
}
