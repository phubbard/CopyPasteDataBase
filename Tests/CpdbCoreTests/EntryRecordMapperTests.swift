import Testing
import Foundation
import CloudKit
@testable import CpdbShared

@Suite("Entry record mapper")
struct EntryRecordMapperTests {

    private static let zone = CKRecordZone.ID(
        zoneName: CKSchema.zoneName,
        ownerName: CKCurrentUserDefaultName
    )

    /// Build an Entry with every field populated to sensible values.
    private func fullEntry(
        kind: EntryKind = .text,
        withOCR: Bool = false,
        tombstoned: Bool = false
    ) -> Entry {
        var uuid = UUID().uuid
        let uuidData = withUnsafeBytes(of: &uuid) { Data($0) }
        return Entry(
            id: nil,
            uuid: uuidData,
            createdAt: 1_700_000_000,
            capturedAt: 1_700_000_001,
            kind: kind,
            sourceAppId: 42,         // local PK — NOT round-tripped; CloudKit gets bundle-id/name denormalised
            sourceDeviceId: 7,       // local PK — NOT round-tripped
            title: "hello world",
            textPreview: "hello world\nsecond line",
            contentHash: Data((0..<32).map { UInt8($0) }),
            totalSize: 1_024,
            deletedAt: tombstoned ? 1_700_000_500 : nil,
            ocrText: withOCR ? "ocr extracted text" : nil,
            imageTags: withOCR ? "keyboard, desk, document" : nil,
            analyzedAt: withOCR ? 1_700_000_050 : nil
        )
    }

    private func defaultSource() -> EntryRecordMapper.SourceInfo {
        .init(
            appBundleId: "com.apple.dt.Xcode",
            appName: "Xcode",
            deviceIdentifier: "HW-UUID-ABC",
            deviceName: "Paul's Mac"
        )
    }

    private func roundTrip(_ entry: Entry, source: EntryRecordMapper.SourceInfo) throws -> EntryRecordMapper.Decoded {
        let id = EntryRecordMapper.recordID(forContentHash: entry.contentHash, in: Self.zone)
        let record = CKRecord(recordType: CKSchema.RecordType.entry, recordID: id)
        EntryRecordMapper.populate(record: record, entry: entry, source: source)
        return try EntryRecordMapper.decode(record)
    }

    // MARK: - Happy paths

    @Test("round-trip: plain text entry preserves every wire field")
    func textRoundTrip() throws {
        let entry = fullEntry(kind: .text)
        let source = defaultSource()
        let decoded = try roundTrip(entry, source: source)

        #expect(decoded.uuid         == entry.uuid)
        #expect(decoded.createdAt    == entry.createdAt)
        #expect(decoded.capturedAt   == entry.capturedAt)
        #expect(decoded.kind         == .text)
        #expect(decoded.title        == entry.title)
        #expect(decoded.textPreview  == entry.textPreview)
        #expect(decoded.contentHash  == entry.contentHash)
        #expect(decoded.totalSize    == entry.totalSize)
        #expect(decoded.deletedAt    == nil)
        #expect(decoded.ocrText      == nil)
        #expect(decoded.imageTags    == nil)
        #expect(decoded.analyzedAt   == nil)
        #expect(decoded.source       == source)
        #expect(decoded.thumbSmallURL == nil)
        #expect(decoded.thumbLargeURL == nil)
    }

    @Test("round-trip: image entry with OCR + tags + analyzed timestamp")
    func imageWithOCR() throws {
        let entry = fullEntry(kind: .image, withOCR: true)
        let decoded = try roundTrip(entry, source: defaultSource())

        #expect(decoded.kind         == .image)
        #expect(decoded.ocrText      == entry.ocrText)
        #expect(decoded.imageTags    == entry.imageTags)
        #expect(decoded.analyzedAt   == entry.analyzedAt)
    }

    @Test("round-trip: tombstoned entry carries deletedAt")
    func tombstoneRoundTrip() throws {
        let entry = fullEntry(tombstoned: true)
        let decoded = try roundTrip(entry, source: defaultSource())
        #expect(decoded.deletedAt == entry.deletedAt)
    }

    @Test("round-trip: pinned flag survives the wire trip")
    func pinnedRoundTrip() throws {
        var entry = fullEntry()
        entry.pinned = true
        let decoded = try roundTrip(entry, source: defaultSource())
        #expect(decoded.pinned == true)

        // And the unpinned default also round-trips correctly.
        var unpinned = fullEntry()
        unpinned.pinned = false
        let decodedUnpinned = try roundTrip(unpinned, source: defaultSource())
        #expect(decodedUnpinned.pinned == false)
    }

    @Test("decode: missing pinned field defaults to false (back-compat)")
    func pinnedFieldMissingDefaults() throws {
        // Simulate a pre-v2.6 record by populating manually without
        // the pinned key. Decoded.pinned should default false.
        let entry = fullEntry()
        let id = EntryRecordMapper.recordID(forContentHash: entry.contentHash, in: Self.zone)
        let record = CKRecord(recordType: CKSchema.RecordType.entry, recordID: id)
        EntryRecordMapper.populate(record: record, entry: entry, source: defaultSource())
        record[CKSchema.EntryField.pinned] = nil   // strip what populate set
        let decoded = try EntryRecordMapper.decode(record)
        #expect(decoded.pinned == false)
    }

    @Test("round-trip covers every EntryKind")
    func everyKind() throws {
        for kind in EntryKind.allCases {
            let entry = fullEntry(kind: kind)
            let decoded = try roundTrip(entry, source: defaultSource())
            #expect(decoded.kind == kind, "kind \(kind) round-tripped as \(decoded.kind)")
        }
    }

    @Test("round-trip: source info with nil app fields (unknown source)")
    func nilAppFields() throws {
        let entry = fullEntry()
        let source = EntryRecordMapper.SourceInfo(
            appBundleId: nil,
            appName: nil,
            deviceIdentifier: "HW-UUID-QQQ",
            deviceName: "Minimal Mac"
        )
        let decoded = try roundTrip(entry, source: source)
        #expect(decoded.source == source)
    }

    // MARK: - Record ID determinism

    @Test("recordID derivation is stable for the same content hash")
    func recordIDStable() {
        let hash = Data(repeating: 0xAB, count: 32)
        let a = EntryRecordMapper.recordID(forContentHash: hash, in: Self.zone)
        let b = EntryRecordMapper.recordID(forContentHash: hash, in: Self.zone)
        #expect(a.recordName == b.recordName)
        #expect(a.recordName.hasPrefix("entry-"))
        // All 32 bytes of the SHA-256 hash land in the name as hex —
        // 64 hex chars after the "entry-" prefix.
        #expect(a.recordName.count == "entry-".count + 64)
    }

    // MARK: - Thumbnail attachment

    @Test("setThumbnails stores URLs and they round-trip back via Decoded")
    func thumbnailURLs() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpdb-ck-thumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let smallURL = tmpDir.appendingPathComponent("small.jpg")
        let largeURL = tmpDir.appendingPathComponent("large.jpg")
        try Data("fake-small".utf8).write(to: smallURL)
        try Data("fake-large".utf8).write(to: largeURL)

        let entry = fullEntry(kind: .image, withOCR: true)
        let id = EntryRecordMapper.recordID(forContentHash: entry.contentHash, in: Self.zone)
        let record = CKRecord(recordType: CKSchema.RecordType.entry, recordID: id)
        EntryRecordMapper.populate(record: record, entry: entry, source: defaultSource())
        EntryRecordMapper.setThumbnails(on: record, smallURL: smallURL, largeURL: largeURL)

        let decoded = try EntryRecordMapper.decode(record)
        #expect(decoded.thumbSmallURL == smallURL)
        #expect(decoded.thumbLargeURL == largeURL)
    }

    @Test("setThumbnails(nil, nil) clears both asset fields")
    func clearThumbnails() throws {
        let entry = fullEntry(kind: .image)
        let id = EntryRecordMapper.recordID(forContentHash: entry.contentHash, in: Self.zone)
        let record = CKRecord(recordType: CKSchema.RecordType.entry, recordID: id)
        EntryRecordMapper.populate(record: record, entry: entry, source: defaultSource())
        // Attach, then clear.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cpdb-ck-\(UUID()).jpg")
        try Data("x".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        EntryRecordMapper.setThumbnails(on: record, smallURL: tmp, largeURL: tmp)
        EntryRecordMapper.setThumbnails(on: record, smallURL: nil, largeURL: nil)

        let decoded = try EntryRecordMapper.decode(record)
        #expect(decoded.thumbSmallURL == nil)
        #expect(decoded.thumbLargeURL == nil)
    }

    // MARK: - Error paths

    @Test("decode throws when a required field is missing")
    func missingFieldThrows() {
        let id = CKRecord.ID(recordName: "entry-x", zoneID: Self.zone)
        let record = CKRecord(recordType: CKSchema.RecordType.entry, recordID: id)
        // Completely empty record — everything is missing.
        #expect(throws: EntryRecordMapper.DecodeError.self) {
            _ = try EntryRecordMapper.decode(record)
        }
    }

    @Test("decode throws on a wrong record type")
    func wrongRecordTypeThrows() {
        let id = CKRecord.ID(recordName: "flavor-x", zoneID: Self.zone)
        let record = CKRecord(recordType: CKSchema.RecordType.flavor, recordID: id)
        #expect(throws: EntryRecordMapper.DecodeError.self) {
            _ = try EntryRecordMapper.decode(record)
        }
    }

    @Test("decode throws on an unknown kind string")
    func unknownKindThrows() {
        let id = CKRecord.ID(recordName: "entry-bad", zoneID: Self.zone)
        let record = CKRecord(recordType: CKSchema.RecordType.entry, recordID: id)
        // Populate all required fields except force a bogus kind.
        record[CKSchema.EntryField.uuid]        = Data(repeating: 0x01, count: 16) as NSData
        record[CKSchema.EntryField.createdAt]   = 1.0 as NSNumber
        record[CKSchema.EntryField.capturedAt]  = 1.0 as NSNumber
        record[CKSchema.EntryField.kind]        = "blorp" as NSString
        record[CKSchema.EntryField.contentHash] = Data(repeating: 0x02, count: 32) as NSData
        record[CKSchema.EntryField.totalSize]   = 0 as NSNumber
        record[CKSchema.EntryField.deviceIdentifier] = "X" as NSString
        record[CKSchema.EntryField.deviceName]       = "X" as NSString

        #expect(throws: EntryRecordMapper.DecodeError.self) {
            _ = try EntryRecordMapper.decode(record)
        }
    }
}
