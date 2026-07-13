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
        /// True when this call did no work because sync is gated by an
        /// in-progress (or pending pull-before-push-latched) identity
        /// cutover — see `pushPendingChanges`'s `blockedByCutover` check.
        /// Additive field, defaults false, so existing call sites and
        /// literal constructions keep compiling.
        public var gated: Bool = false
    }

    /// Outcome of a single `pullRemoteChanges()` call.
    public struct PullReport: Sendable, Equatable {
        public var inserted: Int
        public var updated: Int
        public var tombstoned: Int
        public var skipped: Int
        public var moreComing: Bool
        /// True when this call did no work because sync is paused/gated
        /// (identity cutover pending) rather than because there was
        /// genuinely nothing to pull. Callers (the iOS UI in particular)
        /// must not treat a gated report as a successful empty pull.
        public var gated: Bool = false

        public init(
            inserted: Int,
            updated: Int,
            tombstoned: Int,
            skipped: Int,
            moreComing: Bool,
            gated: Bool = false
        ) {
            self.inserted = inserted
            self.updated = updated
            self.tombstoned = tombstoned
            self.skipped = skipped
            self.moreComing = moreComing
            self.gated = gated
        }
    }

    public static let zoneSubscriptionID = "cpdb-v3-zone-subscription"

    /// UserDefaults key: Double (`timeIntervalSince1970`) of the most
    /// recent successful pull. The About dialog reads this so the user
    /// sees freshness without a live connection to the syncer.
    public static let lastSyncSuccessKey = "cpdb.sync.lastSuccessAt"

    // MARK: - Safety-net poll interval

    /// UserDefaults key for the safety-net pull interval (minutes).
    /// Stored as an `Int`. Absent → default 15 min. Clamped to the
    /// [min, max] range at read time so out-of-band edits can't
    /// poison the loop with 0 or a huge number.
    public static let safetyNetIntervalKey = "cpdb.sync.safetyNetIntervalMinutes"
    public static let safetyNetIntervalDefaultMinutes = 15
    public static let safetyNetIntervalMinMinutes = 5
    public static let safetyNetIntervalMaxMinutes = 24 * 60   // 24 h

    /// Current safety-net poll interval in seconds, honouring the
    /// stored preference. The AppDelegate's periodic loop reads this
    /// on every idle cycle so the user can tune it without restart.
    public static var safetyNetIntervalSeconds: TimeInterval {
        let raw = UserDefaults.standard.object(forKey: safetyNetIntervalKey) as? Int
            ?? safetyNetIntervalDefaultMinutes
        let clamped = max(safetyNetIntervalMinMinutes, min(safetyNetIntervalMaxMinutes, raw))
        return TimeInterval(clamped * 60)
    }

    /// UserDefaults key: Bool. When true, `pushPendingChanges` and
    /// `pullRemoteChanges` return immediately with empty reports. The
    /// Preferences iCloud section toggles this; menu-bar Sync Now
    /// respects it the same way.
    public static let pausedKey = "cpdb.sync.paused"

    public static var isPaused: Bool {
        get { UserDefaults.standard.bool(forKey: pausedKey) }
        set { UserDefaults.standard.set(newValue, forKey: pausedKey) }
    }

    private let store: Store
    private let client: CloudKitClient
    private let zoneID: CKRecordZone.ID
    private let device: DeviceInfo
    private let blobs: BlobStore
    /// Invoked during a pull when a pending ActionRequest targeted at
    /// THIS device asks for a paste action. The closure receives the
    /// local `Entry` the request refers to (looked up by content_hash)
    /// and is expected to write its flavors to the system pasteboard.
    /// The syncer deletes the ActionRequest record after the closure
    /// returns, whether it succeeded or not.
    ///
    /// Only set on the Mac (AppDelegate wires `Restorer`); iOS never
    /// consumes requests — it only sends them.
    private let onPasteAction: (@Sendable (Entry) async -> Void)?

    /// Upper bound on how many entries to pull off the queue per push
    /// call. Actual batch size is also gated by byte budget (see
    /// `maxBatchBytes`). Default is small (20) because each entry
    /// produces 1 Entry + N Flavor records, each Flavor is a CKAsset,
    /// and CloudKit caps request bodies at ~40 MB — one large-image
    /// entry can carry multi-MB flavors.
    private let batchSize: Int

    /// Byte budget per modifyRecords call. CloudKit's documented limit
    /// is 40 MB per operation (aggregated across all records +
    /// assets); 30 MB leaves headroom for encoding overhead and
    /// whatever metadata we're not accounting for.
    private let maxBatchBytes: Int64 = 30 * 1024 * 1024

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
        batchSize: Int = 20,
        blobs: BlobStore = BlobStore(),
        onPasteAction: (@Sendable (Entry) async -> Void)? = nil
    ) {
        self.store = store
        self.client = client
        self.zoneID = zoneID
        self.device = device
        self.batchSize = batchSize
        self.blobs = blobs
        self.onPasteAction = onPasteAction
    }

    // MARK: - Public: action requests

    /// Send a "paste this entry on the target Mac" request. Called
    /// from iOS. The target Mac's running syncer picks the request
    /// up on its next pull (or APNs silent push) and writes the
    /// entry's flavors to its own `NSPasteboard`.
    public func sendPasteRequest(
        entryContentHash: Data,
        targetDeviceIdentifier: String
    ) async throws {
        try await ensureZoneIfNeeded()
        let record = ActionRequestMapper.buildPasteRequest(
            targetDeviceIdentifier: targetDeviceIdentifier,
            entryContentHash: entryContentHash,
            in: zoneID
        )
        let result = try await client.modifyRecords(saving: [record], deleting: [])
        if case .failure(let error) = result.saveResults[record.recordID] {
            throw error
        }
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
        if Self.isPaused {
            return PushReport(attempted: 0, saved: 0, failed: 0, remaining: try await remainingCount())
        }
        // Identity cutover in progress: sync is fully disabled until the
        // local rehash + reseed completes (docs/canonical-hash-v2.md §4.1)
        // — pushing mid-rehash would upload records under hashes the
        // migration is about to change. The pull-before-push latch keeps
        // push silent even AFTER the cutover finishes, until one full
        // post-cutover pull has merged remote state (§5.2) — without it,
        // the last device to cut over would clobber every cutover-window
        // edit fleet-wide and resurrect server tombstones. (The latch is
        // SET by the cutover; the code that CLEARS it after a successful
        // pull lands in Step 4 with the cpdb-v3 zone switch. Gating on it
        // now makes a pre-Step-4 build fail safe — push stays silent
        // rather than pushing v2 records into the still-cpdb-v2 zone.)
        let blockedByCutover = try await store.dbQueue.read { db in
            try IdentityCutover.isPending(db)
                || IdentityCutover.state(db, IdentityCutover.pullBeforePushLatchKey) != nil
        }
        if blockedByCutover {
            // Symmetric with pullRemoteChanges' gated report: a UI
            // watching sync health must be able to tell "gated by a
            // pending cutover" apart from "genuinely nothing to push".
            // `remaining` reflects the real queue depth (potentially the
            // full post-cutover reseed, thousands of rows) rather than a
            // hardcoded 0 — a gated report must not read as "queue empty".
            return PushReport(attempted: 0, saved: 0, failed: 0, remaining: try await remainingCount(), gated: true)
        }
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

        // 2. Build CKRecords. We split the outbound records into two
        //    separate `modifyRecords` calls:
        //      a. Entry records (metadata + thumbnail CKAssets)
        //      b. Flavor records (CKAsset for each flavor body)
        //    Why: CloudKit clusters saves that share record references
        //    server-side. Mixing an Entry with its Flavor records in
        //    one request means a transient problem with any single
        //    flavor asset upload fails the whole cluster — entry +
        //    every sibling flavor — with `CKErrorDomain:22 "Atomic
        //    failure"`. Splitting them decouples the fates: an entry
        //    saves even if one of its flavors has trouble, and
        //    flavors retry independently.
        //
        //    Drop entries that have vanished (race with local delete).
        //    Stop accumulating once we approach CloudKit's 40-MB
        //    per-request budget.
        var entryRecords: [CKRecord] = []
        var flavorRecords: [CKRecord] = []
        var recordIDToEntryId: [CKRecord.ID: Int64] = [:]
        var tempFiles: [URL] = []
        var accumulatedBytes: Int64 = 0
        defer {
            for url in tempFiles {
                try? FileManager.default.removeItem(at: url)
            }
        }

        for pendingRow in pending {
            // Byte-budget guard. Stop before adding an entry whose
            // flavors would blow the batch past maxBatchBytes.
            if accumulatedBytes > maxBatchBytes / 2 && !entryRecords.isEmpty {
                break
            }
            let bundle = try await loadEntryBundle(entryId: pendingRow.entryId)
            guard let bundle = bundle else {
                // Entry row is gone — drop the orphan queue row.
                try await store.dbQueue.write { db in
                    try PushQueue.remove(entryId: pendingRow.entryId, in: db)
                }
                continue
            }

            let recordID = EntryRecordMapper.recordID(
                forContentHash: bundle.entry.contentHash,
                in: zoneID
            )
            let record = CKRecord(recordType: CKSchema.RecordType.entry, recordID: recordID)
            EntryRecordMapper.populate(record: record, entry: bundle.entry, source: bundle.source)

            if let (smallURL, largeURL) = try stageThumbnails(bundle.preview) {
                if let u = smallURL { tempFiles.append(u) }
                if let u = largeURL { tempFiles.append(u) }
                EntryRecordMapper.setThumbnails(on: record, smallURL: smallURL, largeURL: largeURL)
            }

            // Push-batch recordID dedup. Two local entries can map
            // to the same content-addressed recordID — most often a
            // live entry + a tombstoned-by-`cpdb dedupe` sibling
            // sharing content_hash, both queued for push. CloudKit
            // rejects the whole batch with "Invalid Arguments: You
            // can't save the same record twice" if we send both, so
            // we collapse here. Prefer the live row when one is
            // live and one is tombstoned: the live row's state is
            // what the server should reflect, and we drop the
            // tombstoned sibling's queue row in the same write so
            // it doesn't keep crashing future batches.
            if let priorEntryId = recordIDToEntryId[recordID] {
                let isPriorLive = (try? await isEntryLive(entryId: priorEntryId)) ?? true
                let isCurrentLive = bundle.entry.deletedAt == nil
                if isPriorLive && !isCurrentLive {
                    // Keep prior, drop current.
                    try await store.dbQueue.write { db in
                        try PushQueue.remove(entryId: pendingRow.entryId, in: db)
                    }
                    continue
                } else if !isPriorLive && isCurrentLive {
                    // Replace prior with current.
                    if let idx = entryRecords.firstIndex(where: { $0.recordID == recordID }) {
                        entryRecords.remove(at: idx)
                    }
                    try await store.dbQueue.write { db in
                        try PushQueue.remove(entryId: priorEntryId, in: db)
                    }
                    recordIDToEntryId[recordID] = pendingRow.entryId
                } else {
                    // Both live or both tombstoned — keep first,
                    // drop the rest from the queue (they're
                    // logically the same record from CloudKit's POV).
                    try await store.dbQueue.write { db in
                        try PushQueue.remove(entryId: pendingRow.entryId, in: db)
                    }
                    continue
                }
            }
            entryRecords.append(record)
            recordIDToEntryId[recordID] = pendingRow.entryId

            // Flavor records — one per (entry, uti). Bytes come from
            // BlobStore, which handles inline-vs-spilled transparently.
            // Asset tmp files are tracked in tempFiles for cleanup
            // after the modifyRecords call returns.
            let flavors = try await loadFlavors(entryId: pendingRow.entryId)
            for flavor in flavors {
                do {
                    let url = try stageFlavorAsset(flavor, entryUUID: bundle.entry.uuid)
                    tempFiles.append(url)
                    accumulatedBytes += flavor.size
                    let flavorID = FlavorRecordMapper.recordID(
                        forContentHash: bundle.entry.contentHash,
                        uti: flavor.uti,
                        in: zoneID
                    )
                    let flavorRec = CKRecord(recordType: CKSchema.RecordType.flavor, recordID: flavorID)
                    FlavorRecordMapper.populate(
                        record: flavorRec,
                        entryRecordID: recordID,
                        uti: flavor.uti,
                        size: flavor.size,
                        assetURL: url
                    )
                    flavorRecords.append(flavorRec)
                } catch {
                    // Missing blob, disk full, etc. — log and skip this
                    // flavor. Entry still pushes; reader will see the
                    // entry with fewer flavors than expected. On a
                    // clean push next tick we'll try again.
                    Log.cli.error(
                        "staging flavor uti=\(flavor.uti, privacy: .public) entry=\(bundle.entry.uuid.base64EncodedString(), privacy: .public) failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }

        // 3. Push entries first (fast, metadata + thumbnails only).
        // `attempted` counts entries, matching the queue semantics.
        let attempted = recordIDToEntryId.count
        guard !entryRecords.isEmpty else {
            let remaining = try await remainingCount()
            return PushReport(attempted: 0, saved: 0, failed: 0, remaining: remaining)
        }

        let result: CKModifyResult
        do {
            result = try await client.modifyRecords(saving: entryRecords, deleting: [])
        } catch let ckError as CKError where Self.isRetryable(ckError) {
            // Any CloudKit error that supplies a retryAfterSeconds
            // hint (or is a well-known transient like zoneBusy, rate
            // limit, service unavailable, network issue) → sleep and
            // retry next tick. Don't mark failures; the queue rows
            // stay untouched.
            let retry = ckError.retryAfterSeconds ?? 2.0
            Log.cli.info(
                "cloudkit push: transient (\(ckError.code.rawValue, privacy: .public)), waiting \(retry, privacy: .public)s before next try"
            )
            let ns = UInt64(max(retry, 0.5) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            return PushReport(
                attempted: 0,
                saved: 0,
                failed: 0,
                remaining: try await remainingCount()
            )
        } catch {
            // Other whole-batch failure (network down, auth error, …).
            // Mark every row as a failed attempt so they skip to the
            // back of the queue and get exponential-backoff handling.
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

        // 4. Process Entry save results. Entries that saved get
        // removed from the queue; failures normally bump attempt_count.
        //
        // Exception: if EVERY record in the batch failed with
        // batchRequestFailed (code 22 = cascade from server-side
        // "Atomic failure"), the real cause is a zone-level CAS
        // collision — another device pushed to the same records
        // concurrently. This surfaces with code 22 instead of the
        // dedicated .zoneBusy code when the server rolls back the
        // whole batch at once. Treat it as a retryable transient:
        // leave queue rows untouched, sleep, and retry next tick.
        let idMap = recordIDToEntryId
        var errorKindCounts: [String: Int] = [:]
        var successfulEntryRecordIDs: Set<CKRecord.ID> = []

        let wholeBatchCascade = !result.saveResults.isEmpty
            && result.saveResults.values.allSatisfy { outcome in
                if case .failure(let err) = outcome,
                   let ck = err as? CKError, ck.code == .batchRequestFailed {
                    return true
                }
                return false
            }
        if wholeBatchCascade {
            // Rotate these entries to the back of the queue so the
            // next tick peeks a different set. Otherwise we keep
            // retrying the exact same 20 rows every tick, which is a
            // problem when axiom/thor happen to be mid-push on the
            // same content-hashed recordIDs — the contested batch
            // blocks forward progress on every other entry below it.
            let entryIds = Array(idMap.values)
            try await store.dbQueue.write { db in
                let now = Date().timeIntervalSince1970
                for entryId in entryIds {
                    try db.execute(
                        sql: "UPDATE cloudkit_push_queue SET enqueued_at = ? WHERE entry_id = ?",
                        arguments: [now, entryId]
                    )
                }
            }
            Log.cli.info(
                "cloudkit push: whole-batch cascade, rotated \(entryIds.count, privacy: .public) rows to back of queue"
            )
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return PushReport(
                attempted: 0,
                saved: 0,
                failed: 0,
                remaining: try await remainingCount()
            )
        }

        // Run the whole save-results loop INSIDE the dbQueue.write
        // closure (Swift 6 concurrency forbids mutating outer captured
        // vars from a Sendable closure), then return the collected
        // counters to the caller for merging.
        struct EntryWriteOutcome {
            var saved: Int
            var failed: Int
            var successfulRecordIDs: Set<CKRecord.ID>
            var errorKindCounts: [String: Int]
        }
        // enqueued_at observed at peek time, per entry — so the
        // post-success removal can't drop a re-enqueue that landed during
        // the (seconds-to-minutes) CloudKit round-trip.
        let enqueuedAtByEntryId = Dictionary(pending.map { ($0.entryId, $0.enqueuedAt) },
                                             uniquingKeysWith: { a, _ in a })
        let entryOutcome = try await store.dbQueue.write { db -> EntryWriteOutcome in
            var out = EntryWriteOutcome(
                saved: 0, failed: 0,
                successfulRecordIDs: [], errorKindCounts: [:]
            )
            for (recordID, outcome) in result.saveResults {
                switch outcome {
                case .success:
                    if let entryId = idMap[recordID] {
                        // Race-safe: keep a re-enqueue that arrived since
                        // peek (its enqueued_at is newer). Falls back to
                        // unconditional if we somehow lack the peek value.
                        if let peekedAt = enqueuedAtByEntryId[entryId] {
                            try PushQueue.remove(entryId: entryId, peekedEnqueuedAt: peekedAt, in: db)
                        } else {
                            try PushQueue.remove(entryId: entryId, in: db)
                        }
                        out.successfulRecordIDs.insert(recordID)
                        out.saved += 1
                    }
                case .failure(let error):
                    let kind = "entry:\(Self.describe(error))"
                    out.errorKindCounts[kind, default: 0] += 1
                    // CKErrorDomain:22 (batchRequestFailed) means this
                    // record was fine — another record in our cluster
                    // hit a server-side conflict and cascade-failed us
                    // along with it. Don't bump attempt_count; let the
                    // next tick retry. This is the common case with
                    // multiple devices concurrently pushing the same
                    // content-addressed recordIDs.
                    if let ck = error as? CKError, ck.code == .batchRequestFailed {
                        continue
                    }
                    if let entryId = idMap[recordID] {
                        try PushQueue.markFailure(
                            entryId: entryId,
                            error: Self.describe(error),
                            in: db
                        )
                        out.failed += 1
                    }
                }
            }
            return out
        }
        let saved = entryOutcome.saved
        let failed = entryOutcome.failed
        successfulEntryRecordIDs.formUnion(entryOutcome.successfulRecordIDs)
        for (k, v) in entryOutcome.errorKindCounts {
            errorKindCounts[k, default: 0] += v
        }

        // 5. Push flavors for entries that successfully landed. Entries
        // whose parents failed are skipped — next push retries the
        // whole thing. We don't care about per-flavor failures for the
        // queue (parent entry already dequeued on success); just log.
        let survivingFlavors = flavorRecords.filter { rec in
            // Reference to parent entry is in `entryRef`. Filter flavor
            // records whose parent's recordID is in the success set.
            if let ref = rec[CKSchema.FlavorField.entryRef] as? CKRecord.Reference {
                return successfulEntryRecordIDs.contains(ref.recordID)
            }
            return false
        }
        if !survivingFlavors.isEmpty {
            do {
                let flavorResult = try await client.modifyRecords(
                    saving: survivingFlavors, deleting: []
                )
                var benignRaceCount = 0
                for (_, outcome) in flavorResult.saveResults {
                    if case .failure(let error) = outcome {
                        // Concurrent multi-device pushes of the same
                        // content-addressed flavor recordID
                        // (`flavor-<sha256>-<…>`) routinely lose
                        // their per-record save with .batchRequestFailed
                        // ("Atomic failure") — the winner's copy is
                        // already on the server, so the data is intact;
                        // we just don't get to overwrite it. Same for
                        // .serverRecordChanged (etag conflict) and
                        // .unknownItem (the parent entry got
                        // tombstoned mid-push). All three are
                        // benign concurrency noise rather than data
                        // loss; aggregate them under one info-level
                        // counter so the log doesn't scream.
                        if let ck = error as? CKError,
                           ck.code == .batchRequestFailed
                            || ck.code == .serverRecordChanged
                            || ck.code == .unknownItem
                        {
                            benignRaceCount += 1
                            continue
                        }
                        let kind = "flavor:\(Self.describe(error))"
                        errorKindCounts[kind, default: 0] += 1
                    }
                }
                if benignRaceCount > 0 {
                    Log.cli.info(
                        "cloudkit push: \(benignRaceCount, privacy: .public) flavor record(s) lost a concurrent multi-device push race (data already on server)"
                    )
                }
            } catch let ckError as CKError where Self.isRetryable(ckError) {
                let retry = ckError.retryAfterSeconds ?? 2.0
                Log.cli.info(
                    "cloudkit push (flavors): transient (\(ckError.code.rawValue, privacy: .public)), waiting \(retry, privacy: .public)s"
                )
                let ns = UInt64(max(retry, 0.5) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                // Don't mark anything — entries already landed, flavors
                // will be re-built from local state on the next tick.
            } catch {
                errorKindCounts["flavor-batch:\(Self.describe(error))", default: 0] += 1
            }
        }

        if !errorKindCounts.isEmpty {
            let sorted = errorKindCounts.sorted { $0.value > $1.value }
            for (kind, n) in sorted.prefix(5) {
                Log.cli.error("push: \(n, privacy: .public) × \(kind, privacy: .public)")
            }
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

    /// True when the named entry is live (deleted_at IS NULL).
    /// Used by the push-batch recordID dedup path to choose between
    /// a live and tombstoned row sharing the same content_hash.
    private func isEntryLive(entryId: Int64) async throws -> Bool {
        try await store.dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT deleted_at IS NULL FROM entries WHERE id = ?",
                arguments: [entryId]
            ) ?? false
        }
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

    /// Pull every flavor row for an entry. Ordered by UTI for stable
    /// iteration — useful when debugging but not required for
    /// correctness. Returns empty array when the entry has no flavors
    /// (shouldn't happen for live entries but we don't crash on it).
    private func loadFlavors(entryId: Int64) async throws -> [Flavor] {
        try await store.dbQueue.read { db in
            try Flavor
                .filter(Column("entry_id") == entryId)
                .order(Column("uti"))
                .fetchAll(db)
        }
    }

    /// Write one flavor's raw bytes to a temp file so CloudKit can
    /// upload it as a `CKAsset`. Small flavors live inline in SQLite,
    /// large ones spill to blob store — BlobStore.load resolves both.
    private func stageFlavorAsset(_ flavor: Flavor, entryUUID: Data) throws -> URL {
        let bytes = try blobs.load(inline: flavor.data, blobKey: flavor.blobKey)
        let dir = Self.flavorStagingDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = Self.filenameExtension(forUTI: flavor.uti)
        let hex = entryUUID.prefix(4).map { String(format: "%02x", $0) }.joined()
        let url = dir.appendingPathComponent("\(hex)-\(UUID().uuidString).\(ext)")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    static func flavorStagingDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cpdb-ck-flavors", isDirectory: true)
    }

    /// Best-guess file extension for a UTI. Used only to keep the
    /// temp file looking right in logs — CloudKit doesn't care what
    /// extension we hand it. Unknown UTIs get `.bin`.
    static func filenameExtension(forUTI uti: String) -> String {
        switch uti {
        case "public.utf8-plain-text",
             "public.plain-text",
             "public.text":            return "txt"
        case "public.url",
             "public.file-url":        return "url"
        case "public.html":            return "html"
        case "public.rtf":             return "rtf"
        case "public.png":             return "png"
        case "public.jpeg":            return "jpg"
        case "public.tiff":            return "tiff"
        case "com.compuserve.gif":     return "gif"
        case "public.heic":            return "heic"
        default:                       return "bin"
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

    /// CloudKit errors we treat as "sleep and retry next tick"
    /// rather than real failures. Any error with a retryAfterSeconds
    /// hint qualifies — CloudKit explicitly signals "I'll accept this
    /// later, just not now." We also include well-known transient
    /// codes that sometimes omit the hint.
    static func isRetryable(_ error: CKError) -> Bool {
        if error.retryAfterSeconds != nil { return true }
        switch error.code {
        case .zoneBusy,
             .requestRateLimited,
             .serviceUnavailable,
             .networkUnavailable,
             .networkFailure:
            return true
        default:
            return false
        }
    }

    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        // CloudKit often hides the real cause behind a .batchRequestFailed
        // (code 22) cascade error. The actual offending per-record error
        // usually lives in `userInfo[CKRecordChangedErrorServerRecordKey]`
        // sibling — specifically the `NSUnderlyingError` key. Pull those
        // out so our log lines carry the signal, not just the cascade
        // label.
        var parts = ["\(ns.domain):\(ns.code) \(ns.localizedDescription)"]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("<- underlying: \(underlying.domain):\(underlying.code) \(underlying.localizedDescription)")
        }
        if let reasonKey = ns.userInfo["ServerErrorDescription"] as? String {
            parts.append("<- server: \(reasonKey)")
        }
        // Dump any remaining userInfo keys (excluding the noisy ones
        // we know about) — truncated so we don't flood the log.
        let skip: Set<String> = [
            NSUnderlyingErrorKey, "ServerErrorDescription",
            "CKErrorDescription", "NSLocalizedFailureReason"
        ]
        let extra = ns.userInfo
            .filter { !skip.contains($0.key) }
            .map { "\($0.key)=\(String(describing: $0.value).prefix(120))" }
            .sorted()
            .joined(separator: "; ")
        if !extra.isEmpty {
            parts.append("userInfo: \(extra.prefix(400))")
        }
        return parts.joined(separator: " ")
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
    /// Pull remote changes. Optional `progress` fires after every
    /// successfully-applied page so a UI can show incremental counts
    /// + elapsed time during a long backfill on a fresh install.
    /// The callback receives cumulative totals so far, not per-page
    /// deltas — caller can compute rate from successive samples.
    @discardableResult
    public func pullRemoteChanges(
        progress: (@Sendable (PullReport) -> Void)? = nil
    ) async throws -> PullReport {
        if Self.isPaused {
            return PullReport(inserted: 0, updated: 0, tombstoned: 0, skipped: 0, moreComing: false)
        }
        // Identity cutover in progress — see pushPendingChanges. Pulls
        // are equally unsafe: the pull upsert keys by content_hash, which
        // the migration is mid-way through rewriting. Report this as
        // gated (not a clean empty pull) so a UI watching lastSuccessAt
        // doesn't read silence as "up to date" — see docs on `gated`.
        if try await store.dbQueue.read({ try IdentityCutover.isPending($0) }) {
            return PullReport(inserted: 0, updated: 0, tombstoned: 0, skipped: 0, moreComing: false, gated: true)
        }
        try await ensureZoneIfNeeded()

        var totals = PullReport(inserted: 0, updated: 0, tombstoned: 0, skipped: 0, moreComing: false)

        // Page loop — CloudKit may split large change sets across
        // multiple fetch calls. We persist the token after every page
        // so a crash mid-pull doesn't lose progress.
        var pageIndex = 0
        var selfHealed = false
        repeat {
            let token = try await loadChangeToken()
            let result: CKFetchResult
            do {
                result = try await client.fetchRecordZoneChanges(zoneID: zoneID, sinceToken: token)
            } catch let ck as CKError where
                ck.code == .changeTokenExpired || ck.code == .zoneNotFound || ck.code == .userDeletedZone {
                // Self-heal the only manual-intervention failure classes
                // (no token-reset UI on iOS): drop the token + zone-ensured
                // cache and retry from scratch. Once per pull to avoid a
                // loop. zoneNotFound also means we must re-create the zone.
                guard !selfHealed else { throw ck }
                selfHealed = true
                Log.cli.error("cloudkit pull self-heal: \(ck.code.rawValue, privacy: .public) — resetting change token")
                try await resetChangeToken()
                zoneEnsured = false
                try await ensureZoneIfNeeded()
                continue
            }

            let page = try await applyFetchResult(result)
            totals.inserted   += page.inserted
            totals.updated    += page.updated
            totals.tombstoned += page.tombstoned
            totals.skipped    += page.skipped

            if let newToken = result.newChangeToken {
                try await saveChangeToken(newToken)
            }

            totals.moreComing = result.moreComing
            pageIndex += 1
            // Only log pages that actually did something OR are
            // followed by more pages. Empty-and-final pages are the
            // "safety net poll found nothing" case; they'd dominate
            // the log and drown the interesting lines.
            if page.inserted + page.updated + page.tombstoned + page.skipped > 0
                || result.moreComing
            {
                Log.cli.info(
                    "cloudkit pull page \(pageIndex, privacy: .public): inserted=\(page.inserted, privacy: .public) updated=\(page.updated, privacy: .public) tombstoned=\(page.tombstoned, privacy: .public) skipped=\(page.skipped, privacy: .public) moreComing=\(result.moreComing, privacy: .public)"
                )
            }
            progress?(totals)
        } while totals.moreComing

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastSyncSuccessKey)

        // A full pull has completed: clear the pull-before-push latch the
        // cutover set (§5.2), and reap any expired orphan-flavor stash
        // entries. After this, push is unblocked — the post-cutover state
        // is now pull-merge-PUSH, so this device won't clobber peers'
        // cutover-window edits.
        try await store.dbQueue.write { db in
            try IdentityCutover.clearState(db, IdentityCutover.pullBeforePushLatchKey)
            let ttlCutoff = Date().timeIntervalSince1970 - 7 * 86400
            try db.execute(sql: "DELETE FROM orphan_flavors WHERE received_at < ?", arguments: [ttlCutoff])
        }
        return totals
    }

    /// Ensure a zone subscription exists. Call once per launch from
    /// whoever owns the APNs registration — AppDelegate on Mac, the
    /// iOS app's scene launch on iOS.
    public func ensureSubscription() async throws {
        try await client.ensureZoneSubscription(zoneID: zoneID, subscriptionID: Self.zoneSubscriptionID)
    }

    /// Forget the stored zone change token so the next `pullRemoteChanges`
    /// fetches every record in the zone as if this were first run.
    /// Useful as a "repair" button when a device's local cache gets out
    /// of sync with the server (e.g. records inserted directly via the
    /// CloudKit Dashboard or a botched local deletion).
    public func resetChangeToken() async throws {
        try await store.dbQueue.write { db in
            try PushQueue.State.delete(PushQueue.StateKey.zoneChangeToken, in: db)
        }
    }

    /// Wipe the push queue and re-enqueue every live entry. Used by the
    /// Preferences "Re-push everything" action (e.g. after a wire-format
    /// change that requires all records to be re-uploaded, like step 4.5's
    /// flavor addition). Because our recordIDs are deterministic, the
    /// server-side result is an idempotent upsert of the same records.
    public func requeueAll() async throws {
        try await store.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM cloudkit_push_queue;")
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: """
                    INSERT INTO cloudkit_push_queue (entry_id, enqueued_at)
                    SELECT id, ? FROM entries WHERE deleted_at IS NULL
                """,
                arguments: [now]
            )
        }
    }

    private func applyFetchResult(_ result: CKFetchResult) async throws -> PullReport {
        let fallbackID = device.identifier
        let fallbackName = device.name

        // Split the mixed changedRecords by type. Entries must be
        // applied before Flavors so the parent row exists when we
        // insert the child. Unknown types are skipped with a log line.
        var decodedEntries: [EntryRecordMapper.Decoded] = []
        var decodedFlavors: [DecodedFlavorBytes] = []
        var myActions: [ActionRequestMapper.Decoded] = []
        var skippedCount = 0
        for record in result.changedRecords {
            switch record.recordType {
            case CKSchema.RecordType.entry:
                do {
                    decodedEntries.append(try EntryRecordMapper.decode(record))
                } catch {
                    skippedCount += 1
                }
            case CKSchema.RecordType.flavor:
                do {
                    let d = try FlavorRecordMapper.decode(record)
                    // Read asset bytes eagerly — CloudKit removes the
                    // temp file on the next fetch call, so we can't
                    // defer this until the write transaction.
                    let bytes = try Data(contentsOf: d.assetURL)
                    decodedFlavors.append(DecodedFlavorBytes(
                        contentHash: d.contentHash, uti: d.uti, bytes: bytes
                    ))
                } catch {
                    skippedCount += 1
                }
            case CKSchema.RecordType.actionRequest:
                do {
                    let req = try ActionRequestMapper.decode(record)
                    // Only act on requests targeting THIS device.
                    // Other devices' requests pass through as no-ops.
                    if req.targetDeviceIdentifier == device.identifier {
                        myActions.append(req)
                    }
                } catch {
                    skippedCount += 1
                }
            default:
                skippedCount += 1
            }
        }

        // Extract content hashes of records the server says were
        // deleted. v2.1 Entry recordID scheme is `entry-<64 hex hash>`.
        // Flavor deletions are server-side cascades from the parent's
        // deleteSelf reference and don't need separate handling.
        let deletedHashes: [Data] = result.deletedRecordIDs.compactMap { id in
            Self.contentHashFromRecordName(id.recordName)
        }

        let entriesSnapshot = decodedEntries
        let flavorsSnapshot = decodedFlavors
        let deletedSnapshot = deletedHashes
        let blobStore = blobs
        let (pageInserted, pageUpdated, pageTombstoned) = try await store.dbQueue.write { db -> (Int, Int, Int) in
            var ins = 0, upd = 0, tomb = 0
            for d in entriesSnapshot {
                let outcome = try Self.upsert(decoded: d, in: db, fallbackDeviceID: fallbackID, fallbackDeviceName: fallbackName, blobs: blobStore)
                switch outcome {
                case .inserted:  ins += 1
                case .updated:   upd += 1
                case .unchanged: break
                }
            }
            for hash in deletedSnapshot {
                tomb += try Self.tombstone(contentHash: hash, in: db)
            }
            // Apply flavor upserts AFTER entries so the parent row
            // foreign-key constraint is satisfied.
            for f in flavorsSnapshot {
                try Self.upsertFlavor(
                    contentHash: f.contentHash,
                    uti: f.uti,
                    bytes: f.bytes,
                    blobs: blobStore,
                    in: db
                )
            }
            return (ins, upd, tomb)
        }

        // Process ActionRequests targeting THIS device AFTER the
        // write txn closes so the executor (e.g. Mac's Restorer,
        // which opens its own DB read) doesn't deadlock against
        // our write. Delete each request record after executing
        // so it doesn't fire again on the next pull.
        if !myActions.isEmpty, let handler = onPasteAction {
            for req in myActions {
                guard req.kind == CKSchema.ActionKind.paste else { continue }
                let entry: Entry? = try await store.dbQueue.read { db in
                    try Entry
                        .filter(Column("content_hash") == req.entryContentHash)
                        .filter(Column("deleted_at") == nil)
                        .fetchOne(db)
                }
                if let entry = entry {
                    Log.cli.info(
                        "action request: paste entry id=\(entry.id ?? 0, privacy: .public) kind=\(entry.kind.rawValue, privacy: .public)"
                    )
                    await handler(entry)
                } else {
                    Log.cli.info(
                        "action request: entry not present locally for content_hash, dropping"
                    )
                }
                do {
                    _ = try await client.modifyRecords(
                        saving: [], deleting: [req.recordID]
                    )
                } catch {
                    Log.cli.error(
                        "action request delete failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }

        return PullReport(
            inserted: pageInserted,
            updated: pageUpdated,
            tombstoned: pageTombstoned,
            skipped: skippedCount,
            moreComing: result.moreComing
        )
    }

    enum UpsertOutcome { case inserted, updated, unchanged }

    /// Decoded-and-read-from-disk form of a pulled Flavor record.
    /// Bytes are extracted from the CKAsset's fileURL eagerly because
    /// CloudKit removes that file on the next fetch call; we carry the
    /// bytes through the write transaction instead of an asset URL.
    private struct DecodedFlavorBytes: Sendable {
        var contentHash: Data
        var uti: String
        var bytes: Data
    }

    /// Insert or update a flavor row from a pulled Flavor CKRecord.
    /// Looks up the parent entry by content_hash; if no local entry
    /// with this hash exists (e.g. entry was skipped earlier in the
    /// pull because of a schema-drift decode error), the flavor is
    /// dropped silently.
    private static func upsertFlavor(
        contentHash: Data,
        uti: String,
        bytes: Data,
        blobs: BlobStore,
        in db: Database
    ) throws {
        // Look up the parent entry. Skip if missing (the entry
        // record landed but wasn't applied — orphan flavor) OR if
        // the entry is locally body-evicted. The body_evicted_at
        // gate prevents the evict→pull→re-evict loop: once any
        // device clears bodies for this content, this device leaves
        // them gone even when a sibling pushes flavor records that
        // still carry the bytes.
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, body_evicted_at
                FROM entries
                WHERE content_hash = ? AND deleted_at IS NULL
            """,
            arguments: [contentHash]
        ) else {
            // Parent entry not present yet — stash instead of dropping.
            // The flavor record arrived before its entry (cross-page
            // ordering) or before a uuid-merge re-keys a row onto this
            // hash. drainOrphanFlavors replays it once the entry exists;
            // a 7-day TTL sweep reaps any that never get a parent.
            let now = Date().timeIntervalSince1970
            let (inline, blobKey) = try blobs.storeForInsert(data: bytes)
            try db.execute(
                sql: """
                    INSERT INTO orphan_flavors (content_hash, uti, data, blob_key, received_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(content_hash, uti) DO UPDATE SET
                        data = excluded.data, blob_key = excluded.blob_key, received_at = excluded.received_at
                    """,
                arguments: [contentHash, uti, inline, blobKey, now]
            )
            return
        }
        if row["body_evicted_at"] as Double? != nil {
            // Entry has been evicted locally — drop the inbound
            // body bytes on the floor. The flavor row stays absent,
            // which is what eviction wants.
            return
        }
        let entryId: Int64 = row["id"]
        let (inline, blobKey) = try blobs.storeForInsert(data: bytes)
        var flavor = Flavor(
            entryId: entryId,
            uti: uti,
            size: Int64(bytes.count),
            data: inline,
            blobKey: blobKey
        )
        // Replace semantics: same (entry_id, uti) composite PK → insert
        // updates in place. Cheaper than two statements.
        try flavor.insert(db, onConflict: .replace)
    }

    /// Insert or update a local Entry from a decoded CKRecord. Handles
    /// apps + devices upsert by (bundleId, identifier) so the local
    /// foreign keys resolve. Uses `entry.uuid` as the stable key across
    /// devices — that's what `recordID` hashes on the way out.
    ///
    /// Static so it can run inside the GRDB write closure without
    /// capturing `self`. Pulls what it needs via parameters.
    static func upsert(
        decoded d: EntryRecordMapper.Decoded,
        in db: Database,
        fallbackDeviceID: String,
        fallbackDeviceName: String,
        blobs: BlobStore = BlobStore()
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

        // Entry — upsert by content_hash. v2.1 shift: records are
        // content-addressed on the wire, so the same CloudKit record
        // represents the same content across all devices. Locally we
        // key by content_hash when applying pulls so a device's own
        // UUID for this content (possibly different from the one the
        // originating device assigned) is preserved — we only overwrite
        // scalar fields, never the local `uuid`, `id`, or
        // `source_device_id` (originating device identity is kept via
        // the decoded `SourceInfo.deviceIdentifier` on the devices
        // table, not on the entry itself).
        //
        // We DON'T filter on `deleted_at IS NULL` here. If the local
        // row is tombstoned (e.g. cleaned up by `cpdb dedupe` while
        // the CloudKit record is still live pending push) we want to
        // treat this as "tombstone wins, the pushed-but-not-yet-
        // applied tombstone will catch up the server" and NOT insert
        // a new row. Inserting would collide on the unique UUID
        // (same content → same record → same UUID arrived back).
        // Live-preferred lookup: prefer a live row over a tombstoned
        // sibling sharing the same content_hash (delete-then-recopy
        // legitimately produces such pairs). Without the ordering, GRDB
        // returns the lowest rowid and the tombstone-wins guard below
        // would silently eat live updates and misroute inbound deletions
        // (adversarial finding, §5.2).
        if var existing = try Entry
            .filter(Column("content_hash") == d.contentHash)
            .order(sql: "(deleted_at IS NULL) DESC, created_at DESC")
            .fetchOne(db)
        {
            // Last-writer-wins on the USER-MUTATION fields (deleted_at,
            // pinned) by `modified_at`. This replaces the old
            // unconditional "tombstone wins" guard, which permanently
            // blocked undo-of-delete from propagating (a sibling holding a
            // tombstone ignored an incoming live copy, so an entry stayed
            // live here / deleted there). Now: a delete and a later undo
            // each bump modified_at, and the more recent action wins on
            // every device. Ties (>=) go to the remote, deterministically.
            //
            // Capture the PRE-mutation modified_at for the push-queue
            // prune decision below — `existing.modifiedAt` is overwritten
            // a few lines down when the remote wins.
            let localModifiedAtBeforePull = existing.modifiedAt
            let remoteMutationWins = d.modifiedAt >= existing.modifiedAt
            if remoteMutationWins {
                existing.deletedAt  = d.deletedAt
                existing.pinned     = d.pinned
                existing.modifiedAt = d.modifiedAt
            }
            // else keep local deleted_at / pinned / modified_at — our
            // local mutation is newer and already pushed; the sibling that
            // sent this older state will converge when it pulls ours.

            // Content + enrichment fields are content-addressed or
            // adopt-once enrichment, so take remote regardless of the
            // mutation LWW above.
            existing.createdAt   = d.createdAt
            existing.capturedAt  = d.capturedAt
            existing.kind        = d.kind
            existing.sourceAppId = appId
            existing.sourceDeviceId = devId
            existing.title       = d.title
            existing.textPreview = d.textPreview
            existing.totalSize   = d.totalSize
            existing.ocrText     = d.ocrText
            existing.imageTags   = d.imageTags
            existing.analyzedAt  = d.analyzedAt
            // bodyEvictedAt is sticky once set — if any device
            // evicted the bodies, sibling devices learn about it
            // here. Last-writer-wins assignment is correct both ways.
            existing.bodyEvictedAt = d.bodyEvictedAt
            // Link metadata: prefer remote when remote has fetched
            // and we haven't, so the "any device fetches → all
            // devices benefit" pattern works.
            if d.linkFetchedAt != nil {
                existing.linkTitle     = d.linkTitle
                existing.linkFetchedAt = d.linkFetchedAt
            }
            existing.hashVersion = d.hashVersion
            existing.identityTag = d.identityTag
            try existing.update(db)
            // FTS follows the RESOLVED liveness: a row that ends up live
            // is searchable; one that ends up tombstoned must not be (so
            // an inbound delete that wins drops it from search, and an
            // undo that wins restores it).
            if existing.deletedAt == nil {
                try FtsIndex.indexEntry(
                    db: db,
                    entryId: existing.id!,
                    title: existing.title,
                    text: existing.textPreview,
                    appName: d.source.appName,
                    ocrText: existing.ocrText,
                    imageTags: existing.imageTags,
                    linkTitle: existing.linkTitle
                )
            } else {
                try FtsIndex.removeEntry(db: db, entryId: existing.id!)
            }
            try applyThumbnails(d, entryId: existing.id!, in: db)
            try drainOrphanFlavors(forHash: d.contentHash, entryId: existing.id!, blobs: blobs, in: db)
            // Prune a redundant push-queue row (see shouldPrunePushQueueRow
            // doc). Runs inside this same write transaction, so there's no
            // window for a concurrent re-enqueue to race the delete — the
            // GRDB write queue serialises all writers.
            //
            // Only eligible when the entry's *current* queue row is still
            // exactly the row IdentityCutover's step 5 reseed inserted —
            // `enqueued_at <= cutover completedAt`. modified_at alone is
            // NOT a safe proxy: setLinkMetadata, setLinkPreviewThumbnails,
            // the Ingestor union-bump and EntryEvictor all re-enqueue
            // without bumping modified_at, so a genuine post-cutover local
            // edit can tie on modified_at while still needing its push.
            if let reseedCutoffAt = try IdentityCutover.state(db, IdentityCutover.completedAtKey).flatMap(Double.init),
               let queueRowEnqueuedAt = try PushQueue.enqueuedAt(entryId: existing.id!, in: db),
               queueRowEnqueuedAt <= reseedCutoffAt,
               Self.shouldPrunePushQueueRow(
                   localModifiedAtBeforePull: localModifiedAtBeforePull,
                   remoteModifiedAt: d.modifiedAt
               )
            {
                try PushQueue.remove(entryId: existing.id!, in: db)
            }
            return .updated
        } else if let localByUuid = try Entry.filter(Column("uuid") == d.uuid).fetchOne(db) {
            // content_hash miss + uuid match = the SAME logical entry
            // arrived with a DIFFERENT hash than our local copy (a
            // straggler v1→v2 upgrade, or an equal-version fork from a
            // partial-flavor capture). Resolve deterministically by
            // §5.3 — this MUST intercept the collision before the insert
            // below, or the uuid unique constraint aborts the page.
            return try resolveUuidConflict(
                decoded: d, local: localByUuid, appId: appId, devId: devId, blobs: blobs, in: db)
        } else {
            // Cross-device dedup. Same text landing here from
            // CloudKit within a few seconds of a row we already have
            // almost always means Universal Clipboard (or three Macs
            // all running cpdb) captured the same logical content on
            // each device with byte-different flavor sets — different
            // content_hash, same visible text. Collapse these at pull
            // time by bumping the existing row's created_at instead
            // of inserting a parallel entry. Lookup is symmetric with
            // the Ingestor's within-window check (5s window here to
            // account for iCloud delivery lag vs. the 3s local one).
            // Gated on hashVersion < 2: structurally DEAD from the first
            // cpdb-v3 pull (every record in the new zone is v2, so this
            // branch never runs there). Semantic identity already
            // converges the Universal-Clipboard echoes this rescue
            // existed to catch — keeping it live in cpdb-v3 would instead
            // swallow legitimately-distinct same-preview records during
            // the reseed storm (shared-pasteboard mirror pairs,
            // partial-flavor forks). Retained only so a stray v1 record
            // (e.g. a botched manual import) still collapses; deleted in
            // R2 once telemetry confirms zero fires.
            if d.hashVersion < 2,
               let text = d.textPreview?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty,
               d.deletedAt == nil
            {
                // Tight window: 2s catches Universal Clipboard echoes
                // and near-simultaneous captures on sibling Macs, but
                // not "I copied the same string twice on purpose 4s
                // apart" — that should yield two rows.
                let window: TimeInterval = 2.0
                let lo = d.createdAt - window
                let hi = d.createdAt + window
                if let siblingId = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM entries
                        WHERE deleted_at IS NULL
                          AND kind = ?
                          AND created_at BETWEEN ? AND ?
                          AND TRIM(COALESCE(text_preview, '')) = ?
                        ORDER BY created_at DESC
                        LIMIT 1
                    """,
                    arguments: [d.kind.rawValue, lo, hi, text]
                ) {
                    Log.cli.info(
                        "pull: cross-device dedup collapsed incoming record onto id=\(siblingId, privacy: .public) text=\"\(text.prefix(40), privacy: .public)\""
                    )
                    // Bump the existing row's created_at to the later
                    // of the two. Do NOT push this change — we don't
                    // want to re-sync a bump caused by an inbound pull
                    // or we'd loop with the other devices forever.
                    let newer = max(d.createdAt, try Double.fetchOne(
                        db,
                        sql: "SELECT created_at FROM entries WHERE id = ?",
                        arguments: [siblingId]
                    ) ?? d.createdAt)
                    try db.execute(
                        sql: "UPDATE entries SET created_at = ? WHERE id = ?",
                        arguments: [newer, siblingId]
                    )
                    return .updated
                }
            }
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
                analyzedAt: d.analyzedAt,
                pinned: d.pinned,
                bodyEvictedAt: d.bodyEvictedAt,
                linkTitle: d.linkTitle,
                linkFetchedAt: d.linkFetchedAt,
                hashVersion: d.hashVersion,
                identityTag: d.identityTag,
                modifiedAt: d.modifiedAt
            )
            // Insert hardening: a uuid (or content_hash) unique-constraint
            // collision must NOT abort the whole page's write transaction
            // and wedge the change token. Catch it, count it, treat as
            // .unchanged — every re-encounter resolves identically. This
            // is the belt under the §5.3 uuid-conflict resolution (which
            // is meant to intercept collisions before they reach here).
            do {
                try entry.insert(db)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                Self.recordInsertConstraintHit()
                Log.cli.error("pull: insert constraint hit for uuid/hash — treating as unchanged (count=\(Self.insertConstraintHits, privacy: .public))")
                return .unchanged
            }
            try FtsIndex.indexEntry(
                db: db,
                entryId: entry.id!,
                title: entry.title,
                text: entry.textPreview,
                appName: d.source.appName,
                ocrText: entry.ocrText,
                imageTags: entry.imageTags,
                linkTitle: entry.linkTitle
            )
            try applyThumbnails(d, entryId: entry.id!, in: db)
            try drainOrphanFlavors(forHash: d.contentHash, entryId: entry.id!, blobs: blobs, in: db)
            Log.cli.info(
                "pull: inserted id=\(entry.id ?? -1, privacy: .public) kind=\(d.kind.rawValue, privacy: .public) textprev=\"\(d.textPreview?.prefix(40) ?? "", privacy: .public)\""
            )
            return .inserted
        }
    }

    /// §5.3 — resolve a pull where the content_hash misses but the uuid
    /// matches a local row (the same logical entry arrived under a
    /// different hash). `local` is that row; the decoded record `d` is
    /// the inbound version. Returns the outcome and mutates as needed.
    /// `internal` so it's directly unit-testable.
    static func resolveUuidConflict(
        decoded d: EntryRecordMapper.Decoded,
        local: Entry,
        appId: Int64?,
        devId: Int64,
        blobs: BlobStore,
        in db: Database
    ) throws -> UpsertOutcome {
        let now = Date().timeIntervalSince1970
        let remoteWins: Bool
        if d.hashVersion > local.hashVersion {
            remoteWins = true                       // straggler v1→v2 upgrade
        } else if d.hashVersion < local.hashVersion {
            return .unchanged                       // never downgrade
        } else {
            // Equal version, different hash → deterministic rung priority:
            // lower rung index = computed from more-authoritative input
            // (missing flavors only demote identity DOWN the chain, so the
            // higher-rung hash was computed from a superset). Tie → smaller
            // hash bytes win. Both devices resolve identically.
            let rr = Self.rungIndex(d.identityTag)
            let lr = Self.rungIndex(local.identityTag)
            if rr != lr {
                remoteWins = rr < lr
            } else {
                remoteWins = d.contentHash.lexicographicallyPrecedes(local.contentHash)
            }
        }
        guard remoteWins else {
            // Local wins; the peer converges symmetrically when it pulls
            // OUR record. (Orphan lower-rung record on the server is
            // benign — every re-encounter resolves the same way. A
            // cloudkit_record_deletions cleanup queue is a deferred
            // optimization, see docs §5.3.)
            Self.recordForkResolved()
            return .unchanged
        }

        // Remote wins. If a DIFFERENT live local row already holds the
        // remote hash, the uuid-row must MERGE into it (coalesce + retire)
        // rather than re-key onto a colliding hash.
        if let survivor = try Entry
            .filter(Column("content_hash") == d.contentHash)
            .order(sql: "(deleted_at IS NULL) DESC, created_at DESC")
            .fetchOne(db),
           survivor.id != local.id, survivor.deletedAt == nil {
            try EntryCoalesce.merge(db: db, survivorId: survivor.id!, loserIds: [local.id!], now: now)
            try IdentityCutover.retireLoser(db: db, loserId: local.id!, now: now)
            try drainOrphanFlavors(forHash: d.contentHash, entryId: survivor.id!, blobs: blobs, in: db)
            Self.recordForkResolved()
            return .updated
        }

        // Re-key the uuid-row onto the remote identity + adopt the remote
        // scalar fields (it is the newer record by definition of winning).
        // prev_content_hash keeps the v1 lineage (COALESCE so a prior
        // rehash's prev is preserved).
        try db.execute(
            sql: """
                UPDATE entries SET
                    prev_content_hash = COALESCE(prev_content_hash, content_hash),
                    content_hash = ?, hash_version = ?, identity_tag = ?,
                    created_at = ?, captured_at = ?, kind = ?,
                    source_app_id = ?, source_device_id = ?,
                    title = ?, text_preview = ?, total_size = ?, deleted_at = ?,
                    ocr_text = ?, image_tags = ?, analyzed_at = ?,
                    pinned = ?, body_evicted_at = ?
                WHERE id = ?
                """,
            arguments: [
                d.contentHash, d.hashVersion, d.identityTag,
                d.createdAt, d.capturedAt, d.kind.rawValue,
                appId, devId,
                d.title, d.textPreview, d.totalSize, d.deletedAt,
                d.ocrText, d.imageTags, d.analyzedAt,
                d.pinned ? 1 : 0, d.bodyEvictedAt,
                local.id!,
            ]
        )
        if d.linkFetchedAt != nil {
            try db.execute(
                sql: "UPDATE entries SET link_title = ?, link_fetched_at = ? WHERE id = ?",
                arguments: [d.linkTitle, d.linkFetchedAt, local.id!])
        }
        try FtsIndex.indexEntry(
            db: db, entryId: local.id!, title: d.title, text: d.textPreview,
            appName: d.source.appName, ocrText: d.ocrText, imageTags: d.imageTags,
            linkTitle: d.linkFetchedAt != nil ? d.linkTitle : local.linkTitle)
        try applyThumbnails(d, entryId: local.id!, in: db)
        try drainOrphanFlavors(forHash: d.contentHash, entryId: local.id!, blobs: blobs, in: db)
        // Re-enqueue: our re-keyed row now matches the remote record name,
        // so the push is an idempotent LWW upsert that also revives the
        // record if we were mid-flight.
        try PushQueue.enqueue(entryId: local.id!, in: db, now: now)
        Self.recordForkResolved()
        return .updated
    }

    /// Pure decision: after a pull applies an inbound remote record onto
    /// an already-existing local row (the `existing` branch of `upsert`),
    /// should we discard any pending `cloudkit_push_queue` row for that
    /// entry?
    ///
    /// Why this matters: `IdentityCutover` (canonical-hash v2) blindly
    /// re-enqueues every live entry so a device that originates content
    /// re-uploads it under the new zone/identity scheme. On a device
    /// that's a pure CloudKit replica (e.g. an iPhone that never
    /// originated most of its entries), that reseed is redundant — the
    /// content is already on the server. Without this prune, the first
    /// post-cutover pull would re-fetch records that are already
    /// current and then the push queue would re-upload them anyway,
    /// burning gigabytes of CKAsset flavor bytes for no effect.
    ///
    /// SAFETY: this is only ONE of two conditions the call site checks —
    /// see the caller in `upsert`. It is necessary but NOT sufficient on
    /// its own: several writers (setLinkMetadata, setLinkPreviewThumbnails,
    /// the Ingestor union-bump, EntryEvictor) enqueue a push WITHOUT
    /// bumping `modified_at`, so a genuine, never-pushed local edit can
    /// tie (or "lose") on `modified_at` while still needing to reach the
    /// server. The caller additionally requires the queue row's
    /// `enqueued_at` to predate the cutover's reseed timestamp, which
    /// restricts pruning to rows that are still exactly the reseed insert
    /// — i.e. genuinely never touched since. Do not call this function's
    /// result alone as license to prune; only the caller's combined
    /// check is safe.
    ///
    /// Given that: only prune when the incoming remote record is not
    /// OLDER than the local row's PRE-pull `modified_at` — the same
    /// condition `upsert` uses to decide the remote's mutation fields
    /// win. Equal timestamps count as "not older" (ties already go to
    /// the remote in `upsert`).
    static func shouldPrunePushQueueRow(
        localModifiedAtBeforePull: Double,
        remoteModifiedAt: Double
    ) -> Bool {
        remoteModifiedAt >= localModifiedAtBeforePull
    }

    /// Rung index for an `identityTag` string. Unknown / nil (a v1 record,
    /// or schema drift) sorts LAST so any real v2 rung outranks it.
    static func rungIndex(_ tag: String?) -> Int {
        guard let tag, let t = ContentIdentity.Tag(rawValue: tag) else { return Int.max }
        return t.rungIndex
    }

    /// Flavors can arrive on a pull page BEFORE their parent entry record
    /// (cross-page ordering) or before a uuid-merge re-keys a row onto
    /// their hash. `upsertFlavor` stashes such orphans into
    /// `orphan_flavors` (7-day TTL); this drains the stash for a hash once
    /// its entry exists. Idempotent.
    static func drainOrphanFlavors(forHash hash: Data, entryId: Int64, blobs: BlobStore, in db: Database) throws {
        // Skip if the entry is body-evicted — same rule as upsertFlavor.
        let evicted = try Bool.fetchOne(
            db, sql: "SELECT body_evicted_at IS NOT NULL FROM entries WHERE id = ?", arguments: [entryId]) ?? false
        let rows = try Row.fetchAll(
            db, sql: "SELECT uti, data, blob_key FROM orphan_flavors WHERE content_hash = ?", arguments: [hash])
        guard !rows.isEmpty else { return }
        if !evicted {
            for r in rows {
                let bytes = try blobs.load(inline: r["data"], blobKey: r["blob_key"])
                let (inline, blobKey) = try blobs.storeForInsert(data: bytes)
                var flavor = Flavor(entryId: entryId, uti: r["uti"], size: Int64(bytes.count),
                                    data: inline, blobKey: blobKey)
                try flavor.insert(db, onConflict: .ignore)
            }
        }
        try db.execute(sql: "DELETE FROM orphan_flavors WHERE content_hash = ?", arguments: [hash])
    }

    /// Observability counter for §5.3 fork resolutions.
    private nonisolated(unsafe) static var forkLock = NSLock()
    private nonisolated(unsafe) static var _forkResolved = 0
    static func recordForkResolved() {
        forkLock.lock(); defer { forkLock.unlock() }
        _forkResolved += 1
    }
    public static var forksResolved: Int {
        forkLock.lock(); defer { forkLock.unlock() }
        return _forkResolved
    }

    /// Observability counter for pull-side insert constraint collisions
    /// (§5.2 insert hardening). Expected to stay near zero; a rising
    /// count means the §5.3 conflict resolution is missing a case.
    private nonisolated(unsafe) static var insertConstraintLock = NSLock()
    private nonisolated(unsafe) static var _insertConstraintHits = 0
    static func recordInsertConstraintHit() {
        insertConstraintLock.lock(); defer { insertConstraintLock.unlock() }
        _insertConstraintHits += 1
    }
    public static var insertConstraintHits: Int {
        insertConstraintLock.lock(); defer { insertConstraintLock.unlock() }
        return _insertConstraintHits
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

    /// Soft-delete every live local entry matching `contentHash`.
    /// Returns the number of rows affected — usually 0 or 1, but if a
    /// user somehow has two live entries with the same hash we
    /// tombstone both.
    private static func tombstone(contentHash: Data, in db: Database) throws -> Int {
        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: "UPDATE entries SET deleted_at = ? WHERE content_hash = ? AND deleted_at IS NULL",
            arguments: [now, contentHash]
        )
        return db.changesCount
    }

    /// Parse the 32-byte content hash out of a v2.1 Entry recordName.
    /// v2.0 UUID-based recordNames (32 hex chars) return nil, and the
    /// caller silently skips them — the legacy records on the server
    /// get ignored by v2.1 clients until a future GC removes them.
    static func contentHashFromRecordName(_ name: String) -> Data? {
        let prefix = "entry-"
        guard name.hasPrefix(prefix) else { return nil }
        let hex = name.dropFirst(prefix.count)
        guard hex.count == 64 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var iter = hex.makeIterator()
        while let hi = iter.next(), let lo = iter.next() {
            guard let b = UInt8(String([hi, lo]), radix: 16) else { return nil }
            bytes.append(b)
        }
        return bytes.count == 32 ? Data(bytes) : nil
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
