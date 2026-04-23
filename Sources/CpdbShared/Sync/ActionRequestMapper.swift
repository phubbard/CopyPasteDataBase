import Foundation
import CloudKit

/// Builds + decodes `CKRecord`s of type `CKSchema.RecordType.actionRequest`.
///
/// An ActionRequest is a tiny one-shot record: iOS writes it to
/// the shared zone to ask a specific Mac to perform a side-effect
/// (currently only "paste this entry"), the Mac consumes it during
/// a pull, executes, and deletes the record so the request doesn't
/// fire again.
///
/// Wire shape:
/// ```
/// recordName  : action-<UUID>                       (fresh per request)
/// targetDeviceIdentifier : the Mac's hardware UUID   (only that Mac acts)
/// kind        : "paste"
/// entryRef    : CKReference → the v2.1 entry-<64-hex-hash> record
/// requestedAt : Double unix seconds
/// ```
///
/// Why not deterministic IDs like Entry/Flavor records? Because
/// every request is independent — two taps on "push to Mac" for the
/// same entry SHOULD produce two records. The Mac processes them
/// in order and deletes each as it acts.
public enum ActionRequestMapper {

    public static func recordID(in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(
            recordName: "action-\(UUID().uuidString)",
            zoneID: zoneID
        )
    }

    /// Construct a fresh paste-request record pointed at
    /// `targetDeviceIdentifier` asking for `entryContentHash` to
    /// land on that device's clipboard.
    public static func buildPasteRequest(
        targetDeviceIdentifier: String,
        entryContentHash: Data,
        in zoneID: CKRecordZone.ID
    ) -> CKRecord {
        let recordID = Self.recordID(in: zoneID)
        let record = CKRecord(
            recordType: CKSchema.RecordType.actionRequest,
            recordID: recordID
        )
        let entryID = EntryRecordMapper.recordID(
            forContentHash: entryContentHash,
            in: zoneID
        )
        record[CKSchema.ActionRequestField.targetDeviceIdentifier] = targetDeviceIdentifier as NSString
        record[CKSchema.ActionRequestField.kind] = CKSchema.ActionKind.paste as NSString
        record[CKSchema.ActionRequestField.entryRef] = CKRecord.Reference(recordID: entryID, action: .none)
        record[CKSchema.ActionRequestField.requestedAt] = Date().timeIntervalSince1970 as NSNumber
        return record
    }

    /// Decoded form of a pulled ActionRequest record.
    public struct Decoded: Sendable, Equatable {
        public var recordID: CKRecord.ID
        public var targetDeviceIdentifier: String
        public var kind: String
        /// Parsed out of the `entryRef` CKReference's v2.1-style
        /// record name. Same parser logic FlavorRecordMapper uses.
        public var entryContentHash: Data
        public var requestedAt: Double
    }

    public static func decode(_ record: CKRecord) throws -> Decoded {
        guard record.recordType == CKSchema.RecordType.actionRequest else {
            throw EntryRecordMapper.DecodeError.invalidField(
                "recordType",
                reason: "expected \(CKSchema.RecordType.actionRequest), got \(record.recordType)"
            )
        }
        guard let target = (record[CKSchema.ActionRequestField.targetDeviceIdentifier] as? String)
                ?? ((record[CKSchema.ActionRequestField.targetDeviceIdentifier] as? NSString) as String?),
              !target.isEmpty
        else {
            throw EntryRecordMapper.DecodeError.missingField(CKSchema.ActionRequestField.targetDeviceIdentifier)
        }
        guard let kind = (record[CKSchema.ActionRequestField.kind] as? String)
                ?? ((record[CKSchema.ActionRequestField.kind] as? NSString) as String?),
              !kind.isEmpty
        else {
            throw EntryRecordMapper.DecodeError.missingField(CKSchema.ActionRequestField.kind)
        }
        guard let ref = record[CKSchema.ActionRequestField.entryRef] as? CKRecord.Reference else {
            throw EntryRecordMapper.DecodeError.missingField(CKSchema.ActionRequestField.entryRef)
        }
        guard let hash = FlavorRecordMapper.contentHashFromEntryRecordName(ref.recordID.recordName) else {
            throw EntryRecordMapper.DecodeError.invalidField(
                CKSchema.ActionRequestField.entryRef,
                reason: "not a v2.1 entry- content hash: \(ref.recordID.recordName)"
            )
        }
        let requestedAt: Double
        if let n = record[CKSchema.ActionRequestField.requestedAt] as? NSNumber {
            requestedAt = n.doubleValue
        } else if let d = record[CKSchema.ActionRequestField.requestedAt] as? Double {
            requestedAt = d
        } else {
            requestedAt = 0
        }
        return Decoded(
            recordID: record.recordID,
            targetDeviceIdentifier: target,
            kind: kind,
            entryContentHash: hash,
            requestedAt: requestedAt
        )
    }
}
