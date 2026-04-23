import Testing
import Foundation
import CloudKit
@testable import CpdbShared

@Suite("Flavor record mapper")
struct FlavorRecordMapperTests {

    private static let zone = CKRecordZone.ID(
        zoneName: CKSchema.zoneName,
        ownerName: CKCurrentUserDefaultName
    )

    /// Build a tmp asset file and return its URL. Tests are responsible
    /// for cleanup via the deferred removeItem or just leaving it to
    /// /tmp's eventual wipe.
    private func stageAsset(_ bytes: Data, suffix: String = "bin") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpdb-flavor-test-\(UUID().uuidString).\(suffix)")
        try bytes.write(to: url)
        return url
    }

    @Test("recordID is deterministic and namespaced under the entry UUID")
    func recordIDShape() {
        let uuid = Data((0..<16).map { UInt8($0) })
        let a = FlavorRecordMapper.recordID(forEntryUUID: uuid, uti: "public.utf8-plain-text", in: Self.zone)
        let b = FlavorRecordMapper.recordID(forEntryUUID: uuid, uti: "public.utf8-plain-text", in: Self.zone)
        #expect(a.recordName == b.recordName)
        #expect(a.recordName.hasPrefix("flavor-"))
        #expect(a.recordName.contains("000102030405060708090a0b0c0d0e0f"))
        // Dots in UTIs get sluggified.
        #expect(!a.recordName.contains("."))
    }

    @Test("different flavors of same entry get different record IDs")
    func recordIDPerFlavor() {
        let uuid = Data(repeating: 0xAA, count: 16)
        let text = FlavorRecordMapper.recordID(forEntryUUID: uuid, uti: "public.utf8-plain-text", in: Self.zone)
        let png  = FlavorRecordMapper.recordID(forEntryUUID: uuid, uti: "public.png", in: Self.zone)
        #expect(text.recordName != png.recordName)
    }

    @Test("populate + decode round-trips entryUUID, UTI, size, and asset URL")
    func roundTrip() throws {
        let entryUUID = Data((0..<16).map { UInt8($0 + 1) })
        let payload = Data("hello flavor".utf8)
        let asset = try stageAsset(payload, suffix: "txt")
        defer { try? FileManager.default.removeItem(at: asset) }

        let entryRecordID = EntryRecordMapper.recordID(forEntryUUID: entryUUID, in: Self.zone)
        let flavorRecordID = FlavorRecordMapper.recordID(
            forEntryUUID: entryUUID, uti: "public.utf8-plain-text", in: Self.zone
        )
        let record = CKRecord(recordType: CKSchema.RecordType.flavor, recordID: flavorRecordID)
        FlavorRecordMapper.populate(
            record: record,
            entryRecordID: entryRecordID,
            uti: "public.utf8-plain-text",
            size: Int64(payload.count),
            assetURL: asset
        )

        let decoded = try FlavorRecordMapper.decode(record)
        #expect(decoded.entryUUID == entryUUID)
        #expect(decoded.uti == "public.utf8-plain-text")
        #expect(decoded.size == Int64(payload.count))
        #expect(decoded.assetURL == asset)
    }

    @Test("decode throws on a wrong record type")
    func wrongRecordType() {
        let id = CKRecord.ID(recordName: "flavor-x", zoneID: Self.zone)
        let record = CKRecord(recordType: CKSchema.RecordType.entry, recordID: id)
        #expect(throws: EntryRecordMapper.DecodeError.self) {
            _ = try FlavorRecordMapper.decode(record)
        }
    }

    @Test("decode throws when the entry reference is missing")
    func missingEntryRef() {
        let id = CKRecord.ID(recordName: "flavor-x", zoneID: Self.zone)
        let record = CKRecord(recordType: CKSchema.RecordType.flavor, recordID: id)
        // uti/size/data present, but no entryRef.
        record[CKSchema.FlavorField.uti]  = "public.plain-text" as NSString
        record[CKSchema.FlavorField.size] = 10 as NSNumber
        #expect(throws: EntryRecordMapper.DecodeError.self) {
            _ = try FlavorRecordMapper.decode(record)
        }
    }

    @Test("decode throws when the entry reference name isn't entry-<hex>")
    func badEntryRefName() throws {
        let badRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "not-an-entry", zoneID: Self.zone),
            action: .none
        )
        let id = CKRecord.ID(recordName: "flavor-bad", zoneID: Self.zone)
        let record = CKRecord(recordType: CKSchema.RecordType.flavor, recordID: id)
        record[CKSchema.FlavorField.entryRef] = badRef
        record[CKSchema.FlavorField.uti]  = "public.plain-text" as NSString
        record[CKSchema.FlavorField.size] = 10 as NSNumber
        let asset = try stageAsset(Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: asset) }
        record[CKSchema.FlavorField.data] = CKAsset(fileURL: asset)
        #expect(throws: EntryRecordMapper.DecodeError.self) {
            _ = try FlavorRecordMapper.decode(record)
        }
    }
}
