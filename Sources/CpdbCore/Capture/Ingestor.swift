#if os(macOS) || os(iOS)
import Foundation
import GRDB
import CpdbShared
#if os(macOS)
import IOKit
#endif

/// Takes a `PasteboardSnapshot` and writes it to the store — or bumps the
/// existing row's `created_at` if we've seen this content before.
///
/// Stateless and testable: no AppKit, no global singletons. The struct body
/// is platform-neutral (GRDB + CpdbShared only), so iOS captures route
/// through the *same* ingest engine the macOS daemon uses — content-hash
/// dedup, the 30s secondary text-dedup window, kind reclassification, and
/// push-queue enqueue all behave identically across devices. This is the
/// "never a parallel ingest path" requirement from hash-v2 §5.5.
public struct Ingestor {
    public let store: Store
    public let blobs: BlobStore

    /// Time window for the secondary text-preview probe. LOG-ONLY since
    /// canonical-hash v2 (the probe fires a counter, never merges — see
    /// the comment in `doIngest` and docs/canonical-hash-v2.md §7).
    /// Scheduled for deletion in R2 along with the probe itself.
    public static let secondaryDedupWindowSeconds: TimeInterval = 30.0

    public init(store: Store, blobs: BlobStore = BlobStore()) {
        self.store = store
        self.blobs = blobs
    }

    public enum Outcome: Sendable {
        case inserted(Int64)
        case bumped(Int64)
        case skipped(reason: String)
    }

    @discardableResult
    public func ingest(
        _ snapshot: PasteboardSnapshot,
        sourceApp: FrontmostAppInfo?,
        deviceId: Int64
    ) throws -> Outcome {
        guard !snapshot.items.isEmpty else { return .skipped(reason: "empty") }

        // Concealed/transient markers (nspasteboard.org convention) are
        // enforced HERE, not only in the macOS watcher: under semantic
        // identity a leaked concealed capture would BUMP an existing
        // visible entry fleet-wide instead of forking deletably, so the
        // guard must sit below every capture path (macOS, iOS, importers).
        // The watcher's NSPasteboardItem fast-path remains as the first
        // line; this is the one that can't be bypassed.
        if TransientGuard.shouldReject(snapshot) {
            return .skipped(reason: "transient/concealed marker")
        }

        let flavorItems = snapshot.flavorItemsForHashing

        // A snapshot whose every flavor is zero-length carries nothing.
        if ContentIdentity.snapshotIsAllEmpty(items: flavorItems) {
            return .skipped(reason: "all flavors empty")
        }

        // Universal Clipboard Mac-to-Mac *file* mirror: the shared-pasteboard
        // file-url is materialized under a fresh UUID per transfer and is the
        // snapshot's only substantive flavor — pure noise, skip. Echoes that
        // carry image bytes or text (iPhone-origin copies) are kept and key
        // via the image/text rungs. See docs/canonical-hash-v2.md §2.4.
        if ContentIdentity.isSoleSharedPasteboardEcho(items: flavorItems) {
            return .skipped(reason: "universal-clipboard file echo")
        }

        // Semantic content identity (canonical-hash v2): hash the PRIMARY
        // content only, so volatile sidecar flavors (Chromium tokens, UC
        // re-publication noise, linkpresentation metadata) can never fork
        // identity. ContentIdentity is the shared engine pinned by
        // Tests/Fixtures/hash-vectors-v2.json.
        let (tag, hash) = ContentIdentity.compute(items: flavorItems)

        let outcome = try doIngest(
            snapshot, sourceApp: sourceApp, deviceId: deviceId,
            hash: hash, identityTag: tag
        )

        // Wake the CloudKit push loop so this entry uploads right
        // now instead of waiting up to 5 minutes for the safety-net
        // tick. The daemon (AppDelegate) subscribes to this and
        // calls pushPendingChanges; the syncer's internal `pushing`
        // guard coalesces simultaneous wakes.
        switch outcome {
        case .inserted, .bumped:
            // Pass the entry's kind through userInfo so observers
            // can scope themselves. The CloudKit push observer
            // doesn't care; the link-backfill capture-wake observer
            // uses it to skip non-link captures (otherwise every
            // text/file/image capture re-runs the same stuck-at-the-
            // top-of-queue link batch and wastes network).
            NotificationCenter.default.post(
                name: .cpdbLocalEntryIngested,
                object: nil,
                userInfo: ["kind": snapshot.kind.rawValue]
            )
        case .skipped:
            break
        }

        // Kick off image analysis after the write transaction has committed.
        // Vision's `.accurate` OCR can run hundreds of milliseconds; the
        // capture loop returns immediately while the analyzer fills in
        // `ocr_text` / `image_tags` / `analyzed_at` asynchronously.
        if case .inserted(let entryId) = outcome,
           snapshot.kind == .image,
           let imageData = snapshot.imageFlavorData {
            let store = self.store
            Task.detached(priority: .utility) {
                ImageIndexer.analyzeAndStore(
                    entryId: entryId,
                    imageData: imageData,
                    store: store
                )
            }
        }

        return outcome
    }

    private func doIngest(
        _ snapshot: PasteboardSnapshot,
        sourceApp: FrontmostAppInfo?,
        deviceId: Int64,
        hash: Data,
        identityTag: ContentIdentity.Tag
    ) throws -> Outcome {
        try store.dbQueue.write { db in
            // Dedup: if the same hash already exists and isn't tombstoned, bump its created_at.
            if let existingId = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM entries WHERE content_hash = ? AND deleted_at IS NULL",
                arguments: [hash]
            ) {
                let now = snapshot.capturedAt.timeIntervalSince1970
                // Reclassify on bump if the new snapshot's kind
                // differs from the stored one. The classification
                // heuristic in PasteboardSnapshot evolves (v2.7.11
                // added "URL-shaped plain text → kind=link"); rows
                // captured before the new rule shipped would
                // otherwise stay misclassified forever even when
                // re-captured. When kind transitions to .link, also
                // clear link_fetched_at so the backfill picks the
                // row up.
                let newKind = snapshot.kind.rawValue
                let storedKind = try String.fetchOne(
                    db,
                    sql: "SELECT kind FROM entries WHERE id = ?",
                    arguments: [existingId]
                )
                if storedKind != newKind {
                    try db.execute(
                        sql: "UPDATE entries SET created_at = ?, kind = ?, link_fetched_at = CASE WHEN ? = 'link' THEN NULL ELSE link_fetched_at END WHERE id = ?",
                        arguments: [now, newKind, newKind, existingId]
                    )
                } else {
                    try db.execute(
                        sql: "UPDATE entries SET created_at = ? WHERE id = ?",
                        arguments: [now, existingId]
                    )
                }
                // Union-preserving bump (docs/canonical-hash-v2.md §3):
                // semantic identity means "same text from Safari" and
                // "same text from Warp" share one row, so a bump may
                // carry flavors the stored row lacks (html from one
                // route, rtf from another). Adopt UTIs the row is
                // missing; NEVER delete and NEVER overwrite same-UTI
                // bytes (first capture's rich bytes win — replace-on-
                // bump + iOS's string-only copy would strip rich
                // flavors fleet-wide via the UC echo). Skipped for
                // body-evicted rows: their flavors were deliberately
                // discarded, re-adding a partial set would make
                // eviction state incoherent.
                let evicted = try Bool.fetchOne(
                    db,
                    sql: "SELECT body_evicted_at IS NOT NULL FROM entries WHERE id = ?",
                    arguments: [existingId]
                ) ?? false
                if !evicted {
                    let added = try unionMissingFlavors(
                        from: snapshot, into: existingId, db: db
                    )
                    if added > 0 {
                        try db.execute(
                            sql: """
                                UPDATE entries SET total_size =
                                    (SELECT COALESCE(SUM(size), 0) FROM entry_flavors WHERE entry_id = ?)
                                WHERE id = ?
                                """,
                            arguments: [existingId, existingId]
                        )
                    }
                }
                // Bumped created_at is a visible change — other devices
                // should see it float back to the top of their list.
                try PushQueue.enqueue(entryId: existingId, in: db, now: now)
                return .bumped(existingId)
            }

            // Secondary text-preview window — LOG-ONLY since canonical-hash
            // v2 (docs §7, instrument-then-delete). Both of its reasons to
            // exist die under semantic identity: same-copy volatile jitter
            // is fixed by construction (sidecars never reach the hash) and
            // the Xcode RTF-append pattern is a plain hash hit handled by
            // primary dedup + union bump. The live window had no kind
            // filter and matched on the 2048-char-truncated preview, so
            // under v2 every hash-miss-plus-window-hit is by definition a
            // DIFFERENT identity — each fire it acted on would be a false
            // merge ("hello" vs "hello\n"; >2048-char prefix collisions).
            // Expected telemetry: zero legitimate fires. The counter +
            // log are kept for one release of observation; window AND
            // `secondaryDedupWindowSeconds` are deleted in R2.
            let plain = snapshot.plainText
            if let text = plain?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty
            {
                let cutoff = snapshot.capturedAt.timeIntervalSince1970 - Self.secondaryDedupWindowSeconds
                if let nearId = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM entries
                        WHERE deleted_at IS NULL
                          AND created_at >= ?
                          AND TRIM(COALESCE(text_preview, '')) = ?
                        ORDER BY created_at DESC
                        LIMIT 1
                    """,
                    arguments: [cutoff, text]
                ) {
                    Self.recordWindowFire()
                    Log.cli.info(
                        "secondary-window fire (log-only): new v2-distinct capture matches preview of entry \(nearId) — would have merged under v1"
                    )
                    // fall through: insert as a genuinely distinct entry
                }
            }

            // Upsert source app (if we captured one).
            var appId: Int64? = nil
            if let info = sourceApp {
                appId = try Self.upsertApp(info, in: db)
            }

            // Insert entry. `plain` was computed above for the
            // within-window dedup probe — reuse it.
            let now = snapshot.capturedAt.timeIntervalSince1970
            var entry = Entry(
                uuid: Self.newUUID(),
                createdAt: now,
                capturedAt: now,
                kind: snapshot.kind,
                sourceAppId: appId,
                sourceDeviceId: deviceId,
                title: Self.deriveTitle(from: snapshot, plainText: plain),
                textPreview: plain.map { String($0.prefix(2048)) },
                contentHash: hash,
                totalSize: snapshot.totalSize,
                hashVersion: 2,
                identityTag: identityTag.rawValue,
                modifiedAt: now
            )
            try entry.insert(db)
            let entryId = entry.id!

            // Insert flavors.
            for item in snapshot.items {
                for flavor in item.flavors {
                    let (inline, blobKey) = try blobs.storeForInsert(data: flavor.data)
                    var row = Flavor(
                        entryId: entryId,
                        uti: flavor.uti,
                        size: Int64(flavor.data.count),
                        data: inline,
                        blobKey: blobKey
                    )
                    // Flavors are 1:1 per (entry_id, uti) — NSPasteboardItem shouldn't
                    // publish the same UTI twice inside one item, but be defensive.
                    try row.insert(db, onConflict: .ignore)
                }
            }

            // Generate thumbnails for image-bearing captures. Runs inline
            // inside the write transaction — 256/640 px JPEG encodes are
            // sub-10ms on Apple Silicon, so the capture loop doesn't care.
            // Image I/O reads the raw flavor bytes (any supported format)
            // and produces two sizes that match what the Paste importer
            // already populates, so `ImageCard` renders uniformly for
            // both imported and freshly-captured image entries.
            if snapshot.kind == .image, let imageData = snapshot.imageFlavorData {
                let thumbs = Thumbnailer.generate(from: imageData)
                if thumbs.small != nil || thumbs.large != nil {
                    var preview = PreviewRecord(
                        entryId: entryId,
                        thumbSmall: thumbs.small,
                        thumbLarge: thumbs.large
                    )
                    try preview.insert(db, onConflict: .replace)
                }
            }

            // Maintain FTS5 index.
            try FtsIndex.indexEntry(
                db: db,
                entryId: entryId,
                title: entry.title,
                text: plain,
                appName: sourceApp?.name
            )

            // Queue for CloudKit push. Stays a no-op when the syncer
            // isn't running (the rows just accumulate until it starts).
            try PushQueue.enqueue(entryId: entryId, in: db, now: now)

            return .inserted(entryId)
        }
    }

    // MARK: - Helpers

    /// Insert the snapshot's flavors that the stored row does NOT already
    /// have (union-preserving bump, docs §3). Checks the existing UTI set
    /// first so blob spillover (`storeForInsert`) only runs for flavors
    /// that will actually land — a blind insert-with-ignore would write
    /// orphaned blob files for every already-present spilled flavor.
    /// Returns the number of flavor rows added.
    private func unionMissingFlavors(
        from snapshot: PasteboardSnapshot,
        into entryId: Int64,
        db: Database
    ) throws -> Int {
        let existing = try Set(String.fetchAll(
            db,
            sql: "SELECT uti FROM entry_flavors WHERE entry_id = ?",
            arguments: [entryId]
        ))
        var added = 0
        var seen = existing
        for item in snapshot.items {
            for flavor in item.flavors where !seen.contains(flavor.uti) {
                seen.insert(flavor.uti)  // first occurrence wins (flatten rule)
                let (inline, blobKey) = try blobs.storeForInsert(data: flavor.data)
                var row = Flavor(
                    entryId: entryId,
                    uti: flavor.uti,
                    size: Int64(flavor.data.count),
                    data: inline,
                    blobKey: blobKey
                )
                try row.insert(db, onConflict: .ignore)
                added += 1
            }
        }
        return added
    }

    /// Observation counter for the log-only secondary window (docs §7).
    /// Read by `cpdb storage` diagnostics + tests; expected to stay at the
    /// "fires happen but never merge" level until R2 deletes the window.
    private nonisolated(unsafe) static var windowFireLock = NSLock()
    private nonisolated(unsafe) static var _windowFireCount = 0
    static func recordWindowFire() {
        windowFireLock.lock(); defer { windowFireLock.unlock() }
        _windowFireCount += 1
    }
    public static var secondaryWindowFireCount: Int {
        windowFireLock.lock(); defer { windowFireLock.unlock() }
        return _windowFireCount
    }

    static func upsertApp(_ info: FrontmostAppInfo, in db: Database) throws -> Int64 {
        if let existing = try AppRecord
            .filter(Column("bundle_id") == info.bundleId)
            .fetchOne(db)
        {
            return existing.id!
        }
        var row = AppRecord(bundleId: info.bundleId, name: info.name, iconPng: info.iconPng)
        try row.insert(db)
        return row.id!
    }

    static func newUUID() -> Data {
        var uuid = UUID().uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    static func deriveTitle(from snapshot: PasteboardSnapshot, plainText: String?) -> String? {
        if let text = plainText {
            let firstLine = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(200))
            }
        }
        // File URL → filename
        for item in snapshot.items {
            for flavor in item.flavors where flavor.uti == "public.file-url" {
                if let s = String(data: flavor.data, encoding: .utf8),
                   let url = URL(string: s) {
                    return url.lastPathComponent
                }
            }
        }
        return nil
    }
}

// MARK: - Device identity

#if os(macOS)
/// macOS local-device identity (IOKit hardware UUID + host name). iOS has
/// no IOKit and resolves its own device identity in the app's
/// `AppContainer` (UIDevice.identifierForVendor), inserting the `devices`
/// row with `kind: "ios"` there — so this enum stays macOS-only.
public enum DeviceIdentity {
    /// Returns the row id of the local device, creating it on first call.
    public static func ensureLocalDevice(in store: Store) throws -> Int64 {
        let identifier = hardwareUUID() ?? ProcessInfo.processInfo.hostName
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return try store.dbQueue.write { db in
            if let existing = try Device.filter(Column("identifier") == identifier).fetchOne(db) {
                return existing.id!
            }
            var row = Device(identifier: identifier, name: name, kind: "mac")
            try row.insert(db)
            return row.id!
        }
    }

    /// Pulls the stable hardware UUID from IOKit so entries stay correlated
    /// across reinstalls.
    public static func hardwareUUID() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }
        guard let cfValue = IORegistryEntryCreateCFProperty(
            platformExpert,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            return nil
        }
        return cfValue
    }
}
#endif // os(macOS) — DeviceIdentity (IOKit) is macOS-only
#endif // os(macOS) || os(iOS)
