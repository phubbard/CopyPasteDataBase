import Foundation
import CloudKit
import GRDB

/// Drives the CloudKit push/pull loop for the local store.
///
/// Step 4 (this file) implements the push path: draining
/// `cloudkit_push_queue` and uploading Entry records (metadata +
/// thumbnails) to the Private Database. Flavor `CKAsset` upload and the
/// pull path land in follow-up steps.
///
/// Shape choices:
/// - An `actor` so the push loop is serialised without the caller
///   needing a lock. Callers enqueue via the DB (not via this type), so
///   the actor only guards in-flight push state.
/// - `CloudKitClient` is injected so tests can swap in an in-memory
///   fake. The live implementation is `LiveCloudKitClient`.
/// - Errors never crash the app: a batch that partially fails updates
///   `attempt_count` + `last_error` on the queue rows and leaves them
///   for the next drain. The caller schedules the next drain.
public actor CloudKitSyncer {

    public struct DeviceInfo: Sendable {
        public var identifier: String
        public var name: String
        public init(identifier: String, name: String) {
            self.identifier = identifier
            self.name = name
        }
    }

    /// Outcome of a single `pushPendingChanges()` call, for logging and
    /// for tests. Not used for control flow — the syncer schedules its
    /// own retries.
    public struct PushReport: Sendable, Equatable {
        public var attempted: Int
        public var saved: Int
        public var failed: Int
        public var remaining: Int
    }

    private let store: Store
    private let client: CloudKitClient
    private let zoneID: CKRecordZone.ID
    private let device: DeviceInfo
    private let blobs: BlobStore

    /// How many entries to pull off the queue per push call. CloudKit's
    /// `CKModifyRecordsOperation` tops out around 400 records per batch.
    /// 200 is safe for metadata-only records (step 4); once flavor
    /// CKAssets land (step 4.5) this drops to ~50 so one entry's flavor
    /// fan-out stays under the limit.
    private let batchSize: Int

    private var zoneEnsured = false
    private var pushing = false

    public init(
        store: Store,
        client: CloudKitClient,
        zoneID: CKRecordZone.ID = CKRecordZone.ID(
            zoneName: CKSchema.zoneName,
            ownerName: CKCurrentUserDefaultName
        ),
        device: DeviceInfo,
        batchSize: Int = 200,
        blobs: BlobStore = BlobStore()
    ) {
        self.store = store
        self.client = client
        self.zoneID = zoneID
        self.device = device
        self.batchSize = batchSize
        self.blobs = blobs
    }

    /// Ensure the custom zone exists and drain the push queue once.
    /// Safe to call repeatedly; the zone create is idempotent.
    public func start() async throws {
        try await ensureZoneIfNeeded()
        _ = try await pushPendingChanges()
    }

    /// Create the custom zone on the server if we haven't already. Cached
    /// in-actor so subsequent calls are zero-work.
    public func ensureZoneIfNeeded() async throws {
        guard !zoneEnsured else { return }
        try await client.ensureZone(zoneID)
        zoneEnsured = true
    }

    /// Drain one batch from the push queue. Returns a report for
    /// logging. Re-entrancy guard: if a push is already running, returns
    /// an empty report rather than running two in parallel.
    @discardableResult
    public func pushPendingChanges() async throws -> PushReport {
        if pushing {
            return PushReport(attempted: 0, saved: 0, failed: 0, remaining: try await remainingCount())
        }
        pushing = true
        defer { pushing = false }

        try await ensureZoneIfNeeded()

        // 1. Snapshot the next batch from the queue.
        let pending = try await store.dbQueue.read { db in
            try PushQueue.peek(limit: self.batchSize, in: db)
        }
        guard !pending.isEmpty else {
            return PushReport(attempted: 0, saved: 0, failed: 0, remaining: 0)
        }

        // 2. Build CKRecords + stage thumbnail assets for each entry.
        //    Drop entries that have vanished (race with local delete).
        var builtRecords: [CKRecord] = []
        var recordIDToEntryId: [CKRecord.ID: Int64] = [:]
        var tempFiles: [URL] = []
        defer {
            for url in tempFiles {
                try? FileManager.default.removeItem(at: url)
            }
        }

        for pendingRow in pending {
            let bundle = try await loadEntryBundle(entryId: pendingRow.entryId)
            guard let bundle = bundle else {
                // Entry row is gone — drop the orphan queue row.
                try await store.dbQueue.write { db in
                    try PushQueue.remove(entryId: pendingRow.entryId, in: db)
                }
                continue
            }

            let recordID = EntryRecordMapper.recordID(forEntryUUID: bundle.entry.uuid, in: zoneID)
            let record = CKRecord(recordType: CKSchema.RecordType.entry, recordID: recordID)
            EntryRecordMapper.populate(record: record, entry: bundle.entry, source: bundle.source)

            if let (smallURL, largeURL) = try stageThumbnails(bundle.preview) {
                if let u = smallURL { tempFiles.append(u) }
                if let u = largeURL { tempFiles.append(u) }
                EntryRecordMapper.setThumbnails(on: record, smallURL: smallURL, largeURL: largeURL)
            }

            builtRecords.append(record)
            recordIDToEntryId[recordID] = pendingRow.entryId
        }

        // 3. Push.
        let attempted = builtRecords.count
        guard attempted > 0 else {
            let remaining = try await remainingCount()
            return PushReport(attempted: 0, saved: 0, failed: 0, remaining: remaining)
        }

        let result: CKModifyResult
        do {
            result = try await client.modifyRecords(saving: builtRecords, deleting: [])
        } catch {
            // Whole-batch failure (network down, auth error, …).
            // Mark every row as a failed attempt; backoff handled by
            // whoever calls us next.
            try await store.dbQueue.write { db in
                for pendingRow in pending {
                    try PushQueue.markFailure(
                        entryId: pendingRow.entryId,
                        error: Self.describe(error),
                        in: db
                    )
                }
            }
            throw error
        }

        // 4. Process per-record results.
        let (saved, failed) = try await store.dbQueue.write { db -> (Int, Int) in
            var saved = 0
            var failed = 0
            for (recordID, outcome) in result.saveResults {
                guard let entryId = recordIDToEntryId[recordID] else { continue }
                switch outcome {
                case .success:
                    try PushQueue.remove(entryId: entryId, in: db)
                    saved += 1
                case .failure(let error):
                    try PushQueue.markFailure(
                        entryId: entryId,
                        error: Self.describe(error),
                        in: db
                    )
                    failed += 1
                }
            }
            return (saved, failed)
        }

        let remaining = try await remainingCount()
        return PushReport(attempted: attempted, saved: saved, failed: failed, remaining: remaining)
    }

    // MARK: - Internals

    private func remainingCount() async throws -> Int {
        try await store.dbQueue.read { db in try PushQueue.count(in: db) }
    }

    /// Everything the mapper needs to build one CKRecord. Loaded in a
    /// single `dbQueue.read` so we don't hold the write pool.
    private struct EntryBundle {
        var entry: Entry
        var source: EntryRecordMapper.SourceInfo
        var preview: PreviewRecord?
    }

    private func loadEntryBundle(entryId: Int64) async throws -> EntryBundle? {
        let fallbackID = device.identifier
        let fallbackName = device.name
        return try await store.dbQueue.read { db in
            guard let entry = try Entry.fetchOne(db, key: entryId) else {
                return nil
            }
            let app = try entry.sourceAppId.flatMap { id in
                try AppRecord.fetchOne(db, key: id)
            }
            let dev = try Device.fetchOne(db, key: entry.sourceDeviceId)
            let source = EntryRecordMapper.SourceInfo(
                appBundleId: app?.bundleId,
                appName: app?.name,
                deviceIdentifier: dev?.identifier ?? fallbackID,
                deviceName: dev?.name ?? fallbackName
            )
            let preview = try PreviewRecord.fetchOne(db, key: entryId)
            return EntryBundle(entry: entry, source: source, preview: preview)
        }
    }

    /// Write thumbnail bytes to temp files so CloudKit can upload them
    /// as `CKAsset`s. Returns nil if the entry has no preview row;
    /// individual URLs are nil when that specific size is missing.
    /// Caller is responsible for removing the temp files after the
    /// push completes.
    private func stageThumbnails(_ preview: PreviewRecord?) throws -> (URL?, URL?)? {
        guard let preview = preview else { return nil }
        guard preview.thumbSmall != nil || preview.thumbLarge != nil else { return nil }

        let dir = Self.thumbStagingDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func stage(_ data: Data?, suffix: String) throws -> URL? {
            guard let data = data else { return nil }
            let url = dir.appendingPathComponent("\(UUID().uuidString)-\(suffix).jpg")
            try data.write(to: url, options: .atomic)
            return url
        }

        let small = try stage(preview.thumbSmall, suffix: "sm")
        let large = try stage(preview.thumbLarge, suffix: "lg")
        return (small, large)
    }

    /// Throwaway per-process directory under the temp dir. Wiped
    /// opportunistically by `stageThumbnails` cleanup and by the OS.
    static func thumbStagingDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cpdb-ck-thumbs", isDirectory: true)
    }

    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain):\(ns.code) \(ns.localizedDescription)"
    }
}
