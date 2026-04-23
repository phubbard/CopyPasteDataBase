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

    @Test("recordID is deterministic and namespaced under the content hash")
    func recordIDShape() {
        let hash = Data((0..<32).map { UInt8($0) })
        let a = FlavorRecordMapper.recordID(forContentHash: hash, uti: "public.utf8-plain-text", in: Self.zone)
        let b = FlavorRecordMapper.recordID(forContentHash: hash, uti: "public.utf8-plain-text", in: Self.zone)
        #expect(a.recordName == b.recordName)
        #expect(a.recordName.hasPrefix("flavor-"))
        #expect(a.recordName.contains("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        // Dots in UTIs get sluggified.
        #expect(!a.recordName.contains("."))
    }

    @Test("recordID slug is ASCII-only — Unicode letters in UTI become underscores")
    func recordIDASCIIOnly() {
        let hash = Data(repeating: 0xBB, count: 32)
        let wildUTI = "com.exámple.café.tést.🙂.漢字"
        let id = FlavorRecordMapper.recordID(forContentHash: hash, uti: wildUTI, in: Self.zone)
        // Strip the "flavor-<64hex>-" prefix; whatever remains must
        // only contain ASCII [A-Za-z0-9_].
        let prefix = "flavor-"
        #expect(id.recordName.hasPrefix(prefix))
        let rest = id.recordName.dropFirst(prefix.count + 64 + 1)
        for ch in rest {
            let s = ch.unicodeScalars.first!.value
            let ok =
                (s >= 0x30 && s <= 0x39) ||
                (s >= 0x41 && s <= 0x5A) ||
                (s >= 0x61 && s <= 0x7A) ||
                s == 0x5F  // _
            #expect(ok, "slug contains non-safe char: \(ch)")
        }
    }

    @Test("recordID slug caps so total recordName stays under 255")
    func recordIDSlugCap() {
        let hash = Data(repeating: 0xCC, count: 32)
        let ludicrous = String(repeating: "a", count: 500)
        let id = FlavorRecordMapper.recordID(forContentHash: hash, uti: ludicrous, in: Self.zone)
        #expect(id.recordName.count <= 255)
    }

    @Test("different flavors of same entry get different record IDs")
    func recordIDPerFlavor() {
        let hash = Data(repeating: 0xAA, count: 32)
        let text = FlavorRecordMapper.recordID(forContentHash: hash, uti: "public.utf8-plain-text", in: Self.zone)
        let png  = FlavorRecordMapper.recordID(forContentHash: hash, uti: "public.png", in: Self.zone)
        #expect(text.recordName != png.recordName)
    }

    @Test("populate + decode round-trips contentHash, UTI, size, and asset URL")
    func roundTrip() throws {
        let contentHash = Data((0..<32).map { UInt8($0 + 1) })
        let payload = Data("hello flavor".utf8)
        let asset = try stageAsset(payload, suffix: "txt")
        defer { try? FileManager.default.removeItem(at: asset) }

        let entryRecordID = EntryRecordMapper.recordID(forContentHash: contentHash, in: Self.zone)
        let flavorRecordID = FlavorRecordMapper.recordID(
            forContentHash: contentHash, uti: "public.utf8-plain-text", in: Self.zone
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
        #expect(decoded.contentHash == contentHash)
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
