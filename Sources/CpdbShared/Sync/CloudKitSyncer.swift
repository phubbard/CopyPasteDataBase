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

    /// Outcome of a single `pullRemoteChanges()` call.
    public struct PullReport: Sendable, Equatable {
        public var inserted: Int
        public var updated: Int
        public var tombstoned: Int
        public var skipped: Int
        public var moreComing: Bool
    }

    public static let zoneSubscriptionID = "cpdb-v2-zone-subscription"

    /// UserDefaults key: Double (`timeIntervalSince1970`) of the most
    /// recent successful pull. The About dialog reads this so the user
    /// sees freshness without a live connection to the syncer.
    public static let lastSyncSuccessKey = "cpdb.sync.lastSuccessAt"

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
        let idMap = recordIDToEntryId
        let (saved, failed) = try await store.dbQueue.write { db -> (Int, Int) in
            var saved = 0
            var failed = 0
            for (recordID, outcome) in result.saveResults {
                guard let entryId = idMap[recordID] else { continue }
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

    // MARK: - Pull path

    /// Pull remote changes into the local store. Loops internally while
    /// `moreComing` is true so one call drains everything the server has
    /// for us. Safe to call repeatedly; the change token is persisted
    /// after each page so interrupting a pull doesn't force a re-fetch
    /// of already-applied records.
    ///
    /// Updates `UserDefaults` key `cpdb.sync.lastSuccessAt` (the About
    /// window reads this) on any successful fetch, even if zero records
    /// changed.
    @discardableResult
    public func pullRemoteChanges() async throws -> PullReport {
        try await ensureZoneIfNeeded()

        var totals = PullReport(inserted: 0, updated: 0, tombstoned: 0, skipped: 0, moreComing: false)

        // Page loop — CloudKit may split large change sets across
        // multiple fetch calls. We persist the token after every page
        // so a crash mid-pull doesn't lose progress.
        repeat {
            let token = try await loadChangeToken()
            let result = try await client.fetchRecordZoneChanges(zoneID: zoneID, sinceToken: token)

            let page = try await applyFetchResult(result)
            totals.inserted   += page.inserted
            totals.updated    += page.updated
            totals.tombstoned += page.tombstoned
            totals.skipped    += page.skipped

            if let newToken = result.newChangeToken {
                try await saveChangeToken(newToken)
            }

            totals.moreComing = result.moreComing
        } while totals.moreComing

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastSyncSuccessKey)
        return totals
    }

    /// Ensure a zone subscription exists. Call once per launch from
    /// whoever owns the APNs registration — AppDelegate on Mac, the
    /// iOS app's scene launch on iOS.
    public func ensureSubscription() async throws {
        try await client.ensureZoneSubscription(zoneID: zoneID, subscriptionID: Self.zoneSubscriptionID)
    }

    private func applyFetchResult(_ result: CKFetchResult) async throws -> PullReport {
        let fallbackID = device.identifier
        let fallbackName = device.name

        // Split work: decode CKRecords on the actor, then apply all
        // DB mutations inside a single write transaction so partial
        // application never happens.
        var decoded: [EntryRecordMapper.Decoded] = []
        var skippedCount = 0
        for record in result.changedRecords {
            do {
                let d = try EntryRecordMapper.decode(record)
                decoded.append(d)
            } catch {
                // Malformed record on the wire — log and skip. Don't
                // let one bad row block the whole page.
                skippedCount += 1
            }
        }

        // Extract UUIDs of records the server says were deleted. Our
        // recordID scheme is `entry-<32 hex>` — anything that doesn't
        // match is some other record type and we ignore it.
        let deletedUUIDs: [Data] = result.deletedRecordIDs.compactMap { id in
            Self.uuidFromRecordName(id.recordName)
        }

        let decodedSnapshot = decoded
        let deletedSnapshot = deletedUUIDs
        let (pageInserted, pageUpdated, pageTombstoned) = try await store.dbQueue.write { db -> (Int, Int, Int) in
            var ins = 0, upd = 0, tomb = 0
            for d in decodedSnapshot {
                let outcome = try Self.upsert(decoded: d, in: db, fallbackDeviceID: fallbackID, fallbackDeviceName: fallbackName)
                switch outcome {
                case .inserted:  ins += 1
                case .updated:   upd += 1
                case .unchanged: break
                }
            }
            for uuid in deletedSnapshot {
                if try Self.tombstone(uuid: uuid, in: db) {
                    tomb += 1
                }
            }
            return (ins, upd, tomb)
        }

        return PullReport(
            inserted: pageInserted,
            updated: pageUpdated,
            tombstoned: pageTombstoned,
            skipped: skippedCount,
            moreComing: result.moreComing
        )
    }

    private enum UpsertOutcome { case inserted, updated, unchanged }

    /// Insert or update a local Entry from a decoded CKRecord. Handles
    /// apps + devices upsert by (bundleId, identifier) so the local
    /// foreign keys resolve. Uses `entry.uuid` as the stable key across
    /// devices — that's what `recordID` hashes on the way out.
    ///
    /// Static so it can run inside the GRDB write closure without
    /// capturing `self`. Pulls what it needs via parameters.
    private static func upsert(
        decoded d: EntryRecordMapper.Decoded,
        in db: Database,
        fallbackDeviceID: String,
        fallbackDeviceName: String
    ) throws -> UpsertOutcome {
        // App — upsert by bundle id. Null bundle id (unknown source) →
        // no app row.
        var appId: Int64? = nil
        if let bundleId = d.source.appBundleId {
            if let existing = try AppRecord.filter(Column("bundle_id") == bundleId).fetchOne(db) {
                appId = existing.id
            } else {
                var row = AppRecord(bundleId: bundleId, name: d.source.appName ?? bundleId, iconPng: nil)
                try row.insert(db)
                appId = row.id
            }
        }

        // Device — upsert by identifier.
        let devId: Int64
        let deviceIdentifier = d.source.deviceIdentifier.isEmpty ? fallbackDeviceID : d.source.deviceIdentifier
        if let existing = try Device.filter(Column("identifier") == deviceIdentifier).fetchOne(db) {
            devId = existing.id!
        } else {
            var row = Device(
                identifier: deviceIdentifier,
                name: d.source.deviceName.isEmpty ? fallbackDeviceName : d.source.deviceName,
                kind: "mac"
            )
            try row.insert(db)
            devId = row.id!
        }

        // Entry — upsert by uuid. Preserve local `id` when updating so
        // foreign-key references (flavors, previews, pinboard_entries)
        // stay intact. Mirrors Ingestor's insert shape.
        if var existing = try Entry.filter(Column("uuid") == d.uuid).fetchOne(db) {
            // Update scalar fields in place.
            existing.createdAt   = d.createdAt
            existing.capturedAt  = d.capturedAt
            existing.kind        = d.kind
            existing.sourceAppId = appId
            existing.sourceDeviceId = devId
            existing.title       = d.title
            existing.textPreview = d.textPreview
            existing.contentHash = d.contentHash
            existing.totalSize   = d.totalSize
            existing.deletedAt   = d.deletedAt
            existing.ocrText     = d.ocrText
            existing.imageTags   = d.imageTags
            existing.analyzedAt  = d.analyzedAt
            try existing.update(db)
            try FtsIndex.indexEntry(
                db: db,
                entryId: existing.id!,
                title: existing.title,
                text: existing.textPreview,
                appName: d.source.appName
            )
            try applyThumbnails(d, entryId: existing.id!, in: db)
            return .updated
        } else {
            var entry = Entry(
                uuid: d.uuid,
                createdAt: d.createdAt,
                capturedAt: d.capturedAt,
                kind: d.kind,
                sourceAppId: appId,
                sourceDeviceId: devId,
                title: d.title,
                textPreview: d.textPreview,
                contentHash: d.contentHash,
                totalSize: d.totalSize,
                deletedAt: d.deletedAt,
                ocrText: d.ocrText,
                imageTags: d.imageTags,
                analyzedAt: d.analyzedAt
            )
            try entry.insert(db)
            try FtsIndex.indexEntry(
                db: db,
                entryId: entry.id!,
                title: entry.title,
                text: entry.textPreview,
                appName: d.source.appName
            )
            try applyThumbnails(d, entryId: entry.id!, in: db)
            return .inserted
        }
    }

    /// Copy CKAsset-backed thumbnail bytes into the local `previews`
    /// table so the Mac UI can render them without re-downloading.
    /// CloudKit deletes the asset files after the fetch returns, so we
    /// read them during the write transaction.
    private static func applyThumbnails(
        _ d: EntryRecordMapper.Decoded,
        entryId: Int64,
        in db: Database
    ) throws {
        var small: Data? = nil
        var large: Data? = nil
        if let url = d.thumbSmallURL { small = try? Data(contentsOf: url) }
        if let url = d.thumbLargeURL { large = try? Data(contentsOf: url) }
        guard small != nil || large != nil else { return }
        var row = PreviewRecord(entryId: entryId, thumbSmall: small, thumbLarge: large)
        try row.insert(db, onConflict: .replace)
    }

    /// Soft-delete a local entry by UUID. Returns true if a row was
    /// affected. CloudKit "delete" events are rare for us (we tombstone
    /// in place) but we still handle them.
    private static func tombstone(uuid: Data, in db: Database) throws -> Bool {
        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: "UPDATE entries SET deleted_at = ? WHERE uuid = ? AND deleted_at IS NULL",
            arguments: [now, uuid]
        )
        return db.changesCount > 0
    }

    static func uuidFromRecordName(_ name: String) -> Data? {
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

    // MARK: - Change token persistence

    private func loadChangeToken() async throws -> CKServerChangeToken? {
        let data = try await store.dbQueue.read { db in
            try PushQueue.State.get(PushQueue.StateKey.zoneChangeToken, in: db)
        }
        guard let data = data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveChangeToken(_ token: CKServerChangeToken) async throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        try await store.dbQueue.write { db in
            try PushQueue.State.set(PushQueue.StateKey.zoneChangeToken, value: data, in: db)
        }
    }
}
