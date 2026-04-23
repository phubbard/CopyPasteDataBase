#if os(macOS)
import Foundation
import GRDB
import IOKit
import CpdbShared

/// Takes a `PasteboardSnapshot` and writes it to the store — or bumps the
/// existing row's `created_at` if we've seen this content before.
///
/// Stateless and testable: no AppKit, no global singletons.
public struct Ingestor {
    public let store: Store
    public let blobs: BlobStore

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
        let hash = CanonicalHash.hash(items: snapshot.flavorItemsForHashing)

        let outcome = try doIngest(snapshot, sourceApp: sourceApp, deviceId: deviceId, hash: hash)

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
        hash: Data
    ) throws -> Outcome {
        try store.dbQueue.write { db in
            // Dedup: if the same hash already exists and isn't tombstoned, bump its created_at.
            if let existingId = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM entries WHERE content_hash = ? AND deleted_at IS NULL",
                arguments: [hash]
            ) {
                let now = snapshot.capturedAt.timeIntervalSince1970
                try db.execute(
                    sql: "UPDATE entries SET created_at = ? WHERE id = ?",
                    arguments: [now, existingId]
                )
                // Bumped created_at is a visible change — other devices
                // should see it float back to the top of their list.
                try PushQueue.enqueue(entryId: existingId, in: db, now: now)
                return .bumped(existingId)
            }

            // Upsert source app (if we captured one).
            var appId: Int64? = nil
            if let info = sourceApp {
                appId = try Self.upsertApp(info, in: db)
            }

            // Insert entry.
            let now = snapshot.capturedAt.timeIntervalSince1970
            let plain = snapshot.plainText
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
                totalSize: snapshot.totalSize
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
#endif
