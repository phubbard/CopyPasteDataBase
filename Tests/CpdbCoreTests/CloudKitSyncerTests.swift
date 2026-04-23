import Testing
import Foundation
import CloudKit
import GRDB
@testable import CpdbShared

/// In-memory `CloudKitClient` fake. Records "saved" in a dict keyed by
/// record ID so tests can assert on what got pushed, and optional hooks
/// let a test simulate per-record or whole-batch failures.
///
/// Not `Sendable` the natural way — mutable state — so wrap it in an
/// actor. Syncer is also an actor so all calls already cross actor
/// boundaries.
actor FakeCloudKitClient: CloudKitClient {
    struct Injected: Sendable {
        var modifyFailure: (any Error)? = nil
        /// Record IDs to fail individually (all others succeed).
        var failingRecordIDs: Set<CKRecord.ID> = []
    }

    private(set) var savedRecords: [CKRecord.ID: CKRecord] = [:]
    private(set) var ensuredZones: Set<CKRecordZone.ID> = []
    var injected: Injected = .init()
    private(set) var modifyCallCount = 0

    func setInjected(_ i: Injected) { self.injected = i }

    func ensureZone(_ zoneID: CKRecordZone.ID) async throws {
        ensuredZones.insert(zoneID)
    }

    func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID]
    ) async throws -> CKModifyResult {
        modifyCallCount += 1
        if let err = injected.modifyFailure {
            throw err
        }
        var saveResults: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for record in recordsToSave {
            if injected.failingRecordIDs.contains(record.recordID) {
                saveResults[record.recordID] = .failure(TestError.injected)
            } else {
                savedRecords[record.recordID] = record
                saveResults[record.recordID] = .success(record)
            }
        }
        var deleteResults: [CKRecord.ID: Result<Void, any Error>] = [:]
        for id in recordIDsToDelete {
            savedRecords.removeValue(forKey: id)
            deleteResults[id] = .success(())
        }
        return CKModifyResult(saveResults: saveResults, deleteResults: deleteResults)
    }

    enum TestError: Error { case injected }
}

@Suite("CloudKit syncer — push path")
struct CloudKitSyncerTests {

    private static let zone = CKRecordZone.ID(
        zoneName: CKSchema.zoneName,
        ownerName: CKCurrentUserDefaultName
    )

    private static let device = CloudKitSyncer.DeviceInfo(
        identifier: "TEST-HW-UUID",
        name: "Test Mac"
    )

    /// Build a Store, seed one device + one entry, enqueue the entry.
    /// Returns (store, entryId).
    private func seed(entryCount: Int = 1) throws -> (Store, [Int64]) {
        let store = try Store.inMemory()
        var ids: [Int64] = []
        try store.dbQueue.write { db in
            var dev = Device(identifier: Self.device.identifier, name: Self.device.name, kind: "mac")
            try dev.insert(db)
            let deviceId = dev.id!
            for i in 0..<entryCount {
                var uuid = UUID().uuid
                let uuidData = withUnsafeBytes(of: &uuid) { Data($0) }
                var entry = Entry(
                    uuid: uuidData,
                    createdAt: 1_700_000_000 + Double(i),
                    capturedAt: 1_700_000_000 + Double(i),
                    kind: .text,
                    sourceAppId: nil,
                    sourceDeviceId: deviceId,
                    title: "entry \(i)",
                    textPreview: "body \(i)",
                    contentHash: Data(repeating: UInt8(i % 256), count: 32),
                    totalSize: 100
                )
                try entry.insert(db)
                ids.append(entry.id!)
                try PushQueue.enqueue(entryId: entry.id!, in: db, now: 1_700_000_000 + Double(i))
            }
        }
        return (store, ids)
    }

    private func makeSyncer(store: Store, client: CloudKitClient, batchSize: Int = 50) -> CloudKitSyncer {
        CloudKitSyncer(
            store: store,
            client: client,
            zoneID: Self.zone,
            device: Self.device,
            batchSize: batchSize
        )
    }

    // MARK: - Happy paths

    @Test("start() ensures the zone exists")
    func startEnsuresZone() async throws {
        let (store, _) = try seed(entryCount: 0)
        let client = FakeCloudKitClient()
        let syncer = makeSyncer(store: store, client: client)
        try await syncer.start()
        let zones = await client.ensuredZones
        #expect(zones.contains(Self.zone))
    }

    @Test("push drains the queue when everything succeeds")
    func pushDrainsQueue() async throws {
        let (store, ids) = try seed(entryCount: 3)
        let client = FakeCloudKitClient()
        let syncer = makeSyncer(store: store, client: client)

        let report = try await syncer.pushPendingChanges()
        #expect(report.attempted == 3)
        #expect(report.saved == 3)
        #expect(report.failed == 0)
        #expect(report.remaining == 0)

        let queueCount = try await store.dbQueue.read { db in try PushQueue.count(in: db) }
        #expect(queueCount == 0)

        let saved = await client.savedRecords
        #expect(saved.count == 3)
        for id in ids {
            // Every pushed record should be findable in the fake's storage.
            _ = id // IDs are local; we just check count + content below.
        }
        for record in saved.values {
            #expect(record.recordType == CKSchema.RecordType.entry)
        }
    }

    @Test("push sends the right scalar fields on the wire")
    func pushContainsScalarFields() async throws {
        let (store, _) = try seed(entryCount: 1)
        let client = FakeCloudKitClient()
        let syncer = makeSyncer(store: store, client: client)
        _ = try await syncer.pushPendingChanges()

        let saved = await client.savedRecords
        #expect(saved.count == 1)
        let record = saved.values.first!
        #expect(record[CKSchema.EntryField.kind] as? String == "text")
        #expect(record[CKSchema.EntryField.title] as? String == "entry 0")
        #expect(record[CKSchema.EntryField.deviceIdentifier] as? String == Self.device.identifier)
        #expect(record[CKSchema.EntryField.deviceName] as? String == Self.device.name)
        #expect(record[CKSchema.EntryField.uuid] as? Data != nil)
        #expect(record[CKSchema.EntryField.contentHash] as? Data != nil)
    }

    // MARK: - Failure paths

    @Test("partial failure: failed records stay in queue with attempt_count bumped")
    func partialFailureKeepsRowsQueued() async throws {
        let (store, ids) = try seed(entryCount: 3)
        let client = FakeCloudKitClient()
        let syncer = makeSyncer(store: store, client: client)

        // Pre-build the record ID for the middle entry so the fake can
        // target it for failure.
        let middleUUID = try await store.dbQueue.read { db in
            try Entry.fetchOne(db, key: ids[1])!.uuid
        }
        let middleID = EntryRecordMapper.recordID(forEntryUUID: middleUUID, in: Self.zone)
        await client.setInjected(.init(failingRecordIDs: [middleID]))

        let report = try await syncer.pushPendingChanges()
        #expect(report.attempted == 3)
        #expect(report.saved == 2)
        #expect(report.failed == 1)
        #expect(report.remaining == 1)

        // The survivor is the middle entry, with attempt_count == 1.
        let (remainingIds, attempts) = try await store.dbQueue.read { db -> ([Int64], Int64) in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT entry_id, attempt_count FROM cloudkit_push_queue"
            )
            return (rows.map { $0["entry_id"] as Int64 }, rows.first?["attempt_count"] as Int64? ?? 0)
        }
        #expect(remainingIds == [ids[1]])
        #expect(attempts == 1)
    }

    @Test("whole-batch failure rethrows and bumps attempts on every row")
    func wholeBatchFailureBumpsAll() async throws {
        let (store, _) = try seed(entryCount: 2)
        let client = FakeCloudKitClient()
        await client.setInjected(.init(modifyFailure: FakeCloudKitClient.TestError.injected))
        let syncer = makeSyncer(store: store, client: client)

        await #expect(throws: (any Error).self) {
            _ = try await syncer.pushPendingChanges()
        }

        let attempts = try await store.dbQueue.read { db -> [Int64] in
            try Row.fetchAll(db, sql: "SELECT attempt_count FROM cloudkit_push_queue")
                .map { $0["attempt_count"] as Int64 }
        }
        #expect(attempts.count == 2)
        #expect(attempts.allSatisfy { $0 == 1 })
    }

    // MARK: - Queue semantics

    @Test("re-enqueuing the same entry coalesces — one push per drain")
    func reenqueueCoalesces() async throws {
        let (store, ids) = try seed(entryCount: 1)
        // Enqueue the same entry a few more times.
        try await store.dbQueue.write { db in
            for _ in 0..<5 {
                try PushQueue.enqueue(entryId: ids[0], in: db, now: 1_800_000_000)
            }
        }
        let queueCountBefore = try await store.dbQueue.read { db in try PushQueue.count(in: db) }
        #expect(queueCountBefore == 1, "INSERT OR REPLACE should collapse to one row")

        let client = FakeCloudKitClient()
        let syncer = makeSyncer(store: store, client: client)
        let report = try await syncer.pushPendingChanges()
        #expect(report.saved == 1)
        let modifyCalls = await client.modifyCallCount
        #expect(modifyCalls == 1)
    }

}
