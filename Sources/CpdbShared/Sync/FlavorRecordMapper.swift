import Foundation
import CloudKit
import CryptoKit

/// Translates between a local `Flavor` row and a `CKRecord` of type
/// `CKSchema.RecordType.flavor`.
///
/// Shape choice: every flavor's bytes ride as a `CKAsset`, regardless of
/// size. Locally we store small flavors inline in SQLite and spill large
/// ones to the content-addressed blob store; on the wire we unify that
/// split into a single `CKAsset` per flavor. Saves wire-side branching
/// and keeps the CKRecord schema uniform.
///
/// Parent relationship: a Flavor record has a `CKReference` back to its
/// Entry with `.deleteSelf` — CloudKit auto-deletes the Flavor rows when
/// the parent Entry is server-deleted. We tombstone (not server-delete)
/// in normal operation, so cascade is mostly future-proofing for GC.
public enum FlavorRecordMapper {

    /// Deterministic record ID. Shape:
    ///   `flavor-<64-hex content hash>-<16-hex SHA256(uti)>`
    ///
    /// v2.1: content-addressed (shared across devices).
    ///
    /// UTI component is hashed rather than slugified because (a) long
    /// dynamic UTIs (`dyn.ah62d4rv4gu8…`) produced slugs that hit
    /// CloudKit's undocumented real recordName limit, and (b) a
    /// truncated slug can collide for UTIs that share a prefix. 8
    /// bytes / 16 hex chars is 64 bits of address space — astronomical
    /// collision resistance for the handful of UTIs a typical entry
    /// carries. The actual UTI string lives in the record's `uti`
    /// field, so debugging doesn't need the slug.
    ///
    /// Total recordName length: 7 + 64 + 1 + 16 = 88 chars.
    public static func recordID(
        forContentHash hash: Data,
        uti: String,
        in zoneID: CKRecordZone.ID
    ) -> CKRecord.ID {
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        let utiBytes = Data(uti.utf8)
        let utiDigest = SHA256.hash(data: utiBytes)
        let utiHex = utiDigest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "flavor-\(hashHex)-\(utiHex)", zoneID: zoneID)
    }

    /// Build a fresh `CKRecord` for one flavor. Caller supplies the
    /// staged asset file URL (written to a tmp location by the syncer)
    /// — we don't touch the filesystem here so this function stays
    /// pure-data and unit-testable.
    ///
    /// Reference action is `.none` rather than `.deleteSelf`: we don't
    /// rely on server-side cascade cleanup (local tombstones via
    /// `entries.deleted_at` do the logical delete; hard-delete is a
    /// separate GC concern), and `.deleteSelf` binds a parent's
    /// flavors into an atomic cluster on the CloudKit server — a
    /// single bad flavor blocks ~N sibling flavors + the parent with
    /// `CKErrorDomain:22 "Atomic failure"`. `.none` makes each record
    /// an independent save target.
    public static func populate(
        record: CKRecord,
        entryRecordID: CKRecord.ID,
        uti: String,
        size: Int64,
        assetURL: URL
    ) {
        let ref = CKRecord.Reference(recordID: entryRecordID, action: .none)
        record[CKSchema.FlavorField.entryRef] = ref
        record[CKSchema.FlavorField.uti]      = uti as NSString
        record[CKSchema.FlavorField.size]     = size as NSNumber
        record[CKSchema.FlavorField.data]     = CKAsset(fileURL: assetURL)
    }

    /// Decoded form of a pulled Flavor CKRecord. `contentHash` comes
    /// from the parent entry's recordID (v2.1 format:
    /// `entry-<64-hex-hash>`). Local lookup joins on this to find the
    /// right `entries.id` for the flavor insert.
    public struct Decoded: Sendable {
        public var contentHash: Data
        public var uti: String
        public var size: Int64
        public var assetURL: URL
    }

    public static func decode(_ record: CKRecord) throws -> Decoded {
        guard record.recordType == CKSchema.RecordType.flavor else {
            throw EntryRecordMapper.DecodeError.invalidField(
                "recordType",
                reason: "expected \(CKSchema.RecordType.flavor), got \(record.recordType)"
            )
        }
        guard let ref = record[CKSchema.FlavorField.entryRef] as? CKRecord.Reference else {
            throw EntryRecordMapper.DecodeError.missingField(CKSchema.FlavorField.entryRef)
        }
        guard let hash = contentHashFromEntryRecordName(ref.recordID.recordName) else {
            throw EntryRecordMapper.DecodeError.invalidField(
                CKSchema.FlavorField.entryRef,
                reason: "recordName '\(ref.recordID.recordName)' is not a v2.1 entry- content hash"
            )
        }
        let uti = (record[CKSchema.FlavorField.uti] as? String) ?? {
            (record[CKSchema.FlavorField.uti] as? NSString) as String?
        }() ?? ""
        guard !uti.isEmpty else {
            throw EntryRecordMapper.DecodeError.missingField(CKSchema.FlavorField.uti)
        }
        guard let sizeNum = record[CKSchema.FlavorField.size] as? NSNumber else {
            throw EntryRecordMapper.DecodeError.missingField(CKSchema.FlavorField.size)
        }
        guard let asset = record[CKSchema.FlavorField.data] as? CKAsset,
              let url = asset.fileURL else {
            throw EntryRecordMapper.DecodeError.missingField(CKSchema.FlavorField.data)
        }
        return Decoded(
            contentHash: hash,
            uti: uti,
            size: sizeNum.int64Value,
            assetURL: url
        )
    }

    /// Parse the 32-byte content hash out of a v2.1 Entry recordName
    /// like `entry-77ef96ef...`. Returns nil for the legacy v2.0
    /// UUID-based shape (32 hex chars instead of 64) — in mixed-era
    /// zones we simply can't resolve those flavors and skip them.
    static func contentHashFromEntryRecordName(_ name: String) -> Data? {
        let prefix = "entry-"
        guard name.hasPrefix(prefix) else { return nil }
        let hex = name.dropFirst(prefix.count)
        guard hex.count == 64 else { return nil }  // 32 bytes
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var iter = hex.makeIterator()
        while let hi = iter.next(), let lo = iter.next() {
            guard let b = UInt8(String([hi, lo]), radix: 16) else { return nil }
            bytes.append(b)
        }
        return bytes.count == 32 ? Data(bytes) : nil
    }
}
