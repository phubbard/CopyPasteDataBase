import Foundation
import CloudKit

/// Narrow protocol wrapping the CloudKit surface the syncer actually uses.
///
/// Exists for one reason: unit tests. `CKDatabase` requires an iCloud
/// account, an entitled binary, and a network; shoving a fake behind this
/// protocol lets the syncer logic be tested in-process in milliseconds.
///
/// The real implementation (`LiveCloudKitClient`) forwards to the Private
/// Database on a `CKContainer`. Tests use `InMemoryCloudKitClient` (in the
/// test target) which keeps records in a dictionary keyed by record ID.
///
/// Intentionally minimal: we add methods here only when the syncer needs
/// them. Step 4 (push) wants `ensureZone` + `modifyRecords`; step 5 will
/// add `fetchRecordZoneChanges` and subscription plumbing.
public protocol CloudKitClient: Sendable {
    /// Create the zone if it doesn't exist. No-op if the zone already
    /// lives on the server. Called once on syncer startup.
    func ensureZone(_ zoneID: CKRecordZone.ID) async throws

    /// Save a batch of records and/or delete a batch of record IDs in a
    /// single round-trip. Mirrors CloudKit's per-record result shape:
    /// individual records can succeed or fail independently.
    ///
    /// The syncer uses this with `atomically: false` semantics — a
    /// partial success is fine, failed records get requeued with
    /// exponential backoff.
    func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID]
    ) async throws -> CKModifyResult
}

/// Per-record outcome from a `modifyRecords` call.
///
/// Using explicit dictionaries (not CloudKit's tuple return) so the
/// protocol surface is trivially mockable without importing CloudKit's
/// types into test helpers.
public struct CKModifyResult: Sendable {
    public var saveResults: [CKRecord.ID: Result<CKRecord, any Error>]
    public var deleteResults: [CKRecord.ID: Result<Void, any Error>]

    public init(
        saveResults: [CKRecord.ID: Result<CKRecord, any Error>] = [:],
        deleteResults: [CKRecord.ID: Result<Void, any Error>] = [:]
    ) {
        self.saveResults = saveResults
        self.deleteResults = deleteResults
    }

    /// IDs that failed to save, with their errors. Convenience for the
    /// syncer's retry queue.
    public var failedSaves: [(CKRecord.ID, any Error)] {
        saveResults.compactMap { id, result in
            if case .failure(let e) = result { return (id, e) } else { return nil }
        }
    }

    public var failedDeletes: [(CKRecord.ID, any Error)] {
        deleteResults.compactMap { id, result in
            if case .failure(let e) = result { return (id, e) } else { return nil }
        }
    }
}

// MARK: - Live implementation

/// Production `CloudKitClient` backed by `CKContainer.privateCloudDatabase`.
///
/// Thin — all the interesting logic lives in `CloudKitSyncer`. This type
/// exists to isolate the `import CloudKit` dependency from the syncer's
/// test-facing API.
public struct LiveCloudKitClient: CloudKitClient {
    private let database: CKDatabase

    public init(containerIdentifier: String) {
        let container = CKContainer(identifier: containerIdentifier)
        self.database = container.privateCloudDatabase
    }

    public init(database: CKDatabase) {
        self.database = database
    }

    public func ensureZone(_ zoneID: CKRecordZone.ID) async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            _ = try await database.save(zone)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Zone already exists — treat as success. CloudKit surfaces
            // zone-already-present as `serverRecordChanged` rather than a
            // dedicated "already exists" code.
            return
        }
    }

    public func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID]
    ) async throws -> CKModifyResult {
        let (saveResults, deleteResults) = try await database.modifyRecords(
            saving: recordsToSave,
            deleting: recordIDsToDelete,
            savePolicy: .changedKeys,    // send only fields we touched
            atomically: false             // per-record success; failures go to retry queue
        )
        return CKModifyResult(
            saveResults: saveResults,
            deleteResults: deleteResults
        )
    }
}
