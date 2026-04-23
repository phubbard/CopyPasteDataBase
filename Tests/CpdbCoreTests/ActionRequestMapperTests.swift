import Testing
import Foundation
import CloudKit
@testable import CpdbShared

@Suite("Action request mapper")
struct ActionRequestMapperTests {

    private static let zone = CKRecordZone.ID(
        zoneName: CKSchema.zoneName,
        ownerName: CKCurrentUserDefaultName
    )

    /// Build the record we'd have put on the wire, then round-trip it
    /// through `decode` and assert every field came back.
    @Test("buildPasteRequest → decode round-trips every field")
    func roundTrip() throws {
        let hash = Data((0..<32).map { UInt8($0 + 1) })
        let target = "HW-MAC-ABC"
        let record = ActionRequestMapper.buildPasteRequest(
            targetDeviceIdentifier: target,
            entryContentHash: hash,
            in: Self.zone
        )
        let decoded = try ActionRequestMapper.decode(record)
        #expect(decoded.recordID == record.recordID)
        #expect(decoded.targetDeviceIdentifier == target)
        #expect(decoded.kind == CKSchema.ActionKind.paste)
        #expect(decoded.entryContentHash == hash)
        // Timestamp was set to "now" — positive & recent.
        #expect(decoded.requestedAt > 0)
        #expect(Date().timeIntervalSince1970 - decoded.requestedAt < 5)
    }

    @Test("decode throws on the wrong recordType")
    func wrongRecordType() {
        let id = CKRecord.ID(recordName: "action-x", zoneID: Self.zone)
        let record = CKRecord(recordType: CKSchema.RecordType.entry, recordID: id)
        #expect(throws: EntryRecordMapper.DecodeError.self) {
            _ = try ActionRequestMapper.decode(record)
        }
    }

    @Test("decode throws when targetDeviceIdentifier is missing")
    func missingTarget() {
        let id = CKRecord.ID(recordName: "action-y", zoneID: Self.zone)
        let record = CKRecord(recordType: CKSchema.RecordType.actionRequest, recordID: id)
        record[CKSchema.ActionRequestField.kind] = "paste" as NSString
        let hash = Data(repeating: 0xAB, count: 32)
        let entryID = EntryRecordMapper.recordID(forContentHash: hash, in: Self.zone)
        record[CKSchema.ActionRequestField.entryRef] = CKRecord.Reference(recordID: entryID, action: .none)
        record[CKSchema.ActionRequestField.requestedAt] = 1_700_000_000.0 as NSNumber
        #expect(throws: EntryRecordMapper.DecodeError.self) {
            _ = try ActionRequestMapper.decode(record)
        }
    }

    @Test("decode throws when entryRef recordName isn't v2.1 hash format")
    func badEntryRef() {
        let id = CKRecord.ID(recordName: "action-z", zoneID: Self.zone)
        let record = CKRecord(recordType: CKSchema.RecordType.actionRequest, recordID: id)
        record[CKSchema.ActionRequestField.targetDeviceIdentifier] = "HW-X" as NSString
        record[CKSchema.ActionRequestField.kind] = "paste" as NSString
        // Legacy 32-hex UUID recordName — not accepted by v2.1 parser.
        let uuidID = CKRecord.ID(
            recordName: "entry-11111111222222223333333344444444",
            zoneID: Self.zone
        )
        record[CKSchema.ActionRequestField.entryRef] = CKRecord.Reference(recordID: uuidID, action: .none)
        record[CKSchema.ActionRequestField.requestedAt] = 0 as NSNumber
        #expect(throws: EntryRecordMapper.DecodeError.self) {
            _ = try ActionRequestMapper.decode(record)
        }
    }

    @Test("recordName is unique per call — no collision between two requests")
    func uniqueRecordNames() {
        let hash = Data(repeating: 0x55, count: 32)
        let a = ActionRequestMapper.buildPasteRequest(
            targetDeviceIdentifier: "HW", entryContentHash: hash, in: Self.zone
        )
        let b = ActionRequestMapper.buildPasteRequest(
            targetDeviceIdentifier: "HW", entryContentHash: hash, in: Self.zone
        )
        #expect(a.recordID.recordName != b.recordID.recordName)
        #expect(a.recordID.recordName.hasPrefix("action-"))
    }
}
