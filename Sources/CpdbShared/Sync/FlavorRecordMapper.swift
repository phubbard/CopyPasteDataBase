import Foundation
import CloudKit

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

    /// Deterministic record ID. Shape: `flavor-<32 hex of entry uuid>-<uti slug>`.
    ///
    /// The slug is strictly ASCII alphanumerics + `_`; every other byte
    /// (including non-ASCII "letters" like `é`, CJK, emoji, etc.) is
    /// replaced with `_`. CloudKit's `CKRecord.ID` recordName only
    /// accepts ASCII alphanumerics, underscores, and dashes — letting
    /// a Unicode letter through raises `NSInvalidArgumentException`
    /// and tears down the process.
    ///
    /// Slug is also capped at 200 chars to keep the total recordName
    /// under CloudKit's 255-char limit (7 for "flavor-" + 32 hex + 1
    /// dash + 200 slug = 240).
    public static func recordID(
        forEntryUUID entryUUID: Data,
        uti: String,
        in zoneID: CKRecordZone.ID
    ) -> CKRecord.ID {
        let entryHex = entryUUID.map { String(format: "%02x", $0) }.joined()
        let rawSlug = uti.unicodeScalars.map { scalar -> Character in
            let cp = scalar.value
            let isDigit     = cp >= 0x30 && cp <= 0x39
            let isUpper     = cp >= 0x41 && cp <= 0x5A
            let isLower     = cp >= 0x61 && cp <= 0x7A
            if isDigit || isUpper || isLower { return Character(scalar) }
            return "_"
        }
        let slug = String(rawSlug.prefix(200))
        return CKRecord.ID(recordName: "flavor-\(entryHex)-\(slug)", zoneID: zoneID)
    }

    /// Build a fresh `CKRecord` for one flavor. Caller supplies the
    /// staged asset file URL (written to a tmp location by the syncer)
    /// — we don't touch the filesystem here so this function stays
    /// pure-data and unit-testable.
    public static func populate(
        record: CKRecord,
        entryRecordID: CKRecord.ID,
        uti: String,
        size: Int64,
        assetURL: URL
    ) {
        let ref = CKRecord.Reference(recordID: entryRecordID, action: .deleteSelf)
        record[CKSchema.FlavorField.entryRef] = ref
        record[CKSchema.FlavorField.uti]      = uti as NSString
        record[CKSchema.FlavorField.size]     = size as NSNumber
        record[CKSchema.FlavorField.data]     = CKAsset(fileURL: assetURL)
    }

    /// Decoded form of a pulled Flavor CKRecord. `entryRef` is exposed
    /// as the parent entry's UUID (parsed back out of the referenced
    /// recordID) so the syncer can look up the local entry row without
    /// needing a separate fetch.
    public struct Decoded: Sendable {
        public var entryUUID: Data
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
        guard let entryUUID = uuidFromEntryRecordName(ref.recordID.recordName) else {
            throw EntryRecordMapper.DecodeError.invalidField(
                CKSchema.FlavorField.entryRef,
                reason: "recordName '\(ref.recordID.recordName)' is not an entry- UUID"
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
            entryUUID: entryUUID,
            uti: uti,
            size: sizeNum.int64Value,
            assetURL: url
        )
    }

    /// Parse the 16-byte UUID out of an Entry recordName like
    /// `entry-32ed3cd4b2044b4ea646a30a7acedf1f`. Returns nil for any
    /// other record-name shape. Duplicated from CloudKitSyncer so this
    /// type stays standalone for unit-testing.
    static func uuidFromEntryRecordName(_ name: String) -> Data? {
        let prefix = "entry-"
        guard name.hasPrefix(prefix) else { return nil }
        let hex = name.dropFirst(prefix.count)
        guard hex.count == 32 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var iter = hex.makeIterator()
        while let hi = iter.next(), let lo = iter.next() {
            guard let b = UInt8(String([hi, lo]), radix: 16) else { return nil }
            bytes.append(b)
        }
        return bytes.count == 16 ? Data(bytes) : nil
    }
}
