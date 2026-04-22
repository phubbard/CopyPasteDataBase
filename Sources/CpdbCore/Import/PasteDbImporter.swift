import Foundation
import CryptoKit
import GRDB
import CpdbShared

/// Ingests a Paste (`com.wiheads.paste`) Core Data SQLite store into the
/// cpdb database.
///
/// Safe to re-run: entries are deduplicated by `content_hash`, so repeating
/// an import simply skips anything already present.
public struct PasteDbImporter {
    public let source: PasteCoreDataReader
    public let target: Store
    public let blobs: BlobStore
    public let decoder: TransformablePasteboardDecoder

    public init(
        sourcePath: URL = Paths.defaultPasteDatabaseURL,
        target: Store,
        blobs: BlobStore = BlobStore()
    ) throws {
        self.source = try PasteCoreDataReader(databaseURL: sourcePath)
        self.target = target
        self.blobs = blobs
        self.decoder = TransformablePasteboardDecoder(
            externalDataDirectory: TransformablePasteboardDecoder
                .externalDataDirectory(forPasteDatabase: sourcePath)
        )
    }

    public struct Report: Sendable {
        public var totalRows: Int = 0
        public var inserted: Int = 0
        public var skippedDuplicate: Int = 0
        public var skippedEmpty: Int = 0
        public var decodeFailures: Int = 0
    }

    public func run(progress: ((Report) -> Void)? = nil) throws -> Report {
        // Core Data reference-date epoch is 2001-01-01 00:00:00 UTC.
        let coreDataEpochOffset: Double = 978307200.0

        // Pre-load apps and devices into id maps.
        let sourceApps = try source.allApplications()
        let sourceDevices = try source.allDevices()
        let sourcePinboards = try source.allPinboards()

        var pasteAppPkToCpdbId: [Int64: Int64] = [:]
        var pasteDevicePkToCpdbId: [Int64: Int64] = [:]
        var pastePinboardPkToCpdbId: [Int64: Int64] = [:]

        try target.dbQueue.write { db in
            // Apps
            for app in sourceApps {
                guard let bundleId = app.bundleId else { continue }
                let name = app.name ?? bundleId
                if let existing = try AppRecord
                    .filter(Column("bundle_id") == bundleId)
                    .fetchOne(db)
                {
                    pasteAppPkToCpdbId[app.pk] = existing.id!
                } else {
                    var row = AppRecord(
                        bundleId: bundleId,
                        name: name,
                        iconPng: Self.decodeIcon(app.icon)
                    )
                    try row.insert(db)
                    pasteAppPkToCpdbId[app.pk] = row.id!
                }
            }

            // Devices
            for dev in sourceDevices {
                let identifier = dev.identifier ?? "paste-device-\(dev.pk)"
                let name = dev.name ?? "Imported device"
                if let existing = try Device.filter(Column("identifier") == identifier).fetchOne(db) {
                    pasteDevicePkToCpdbId[dev.pk] = existing.id!
                } else {
                    var row = Device(identifier: identifier, name: name, kind: "mac")
                    try row.insert(db)
                    pasteDevicePkToCpdbId[dev.pk] = row.id!
                }
            }

            // Pinboards. Derive a deterministic uuid so re-imports are idempotent
            // even when Paste's ZIDENTIFIER isn't itself a UUID (e.g. the string
            // "Useful Links"). Using a stable hash of the source identifier
            // means we recognise the same pinboard across runs.
            for pb in sourcePinboards {
                let uuid = Self.uuidFromIdentifier(pb.identifier)
                    ?? Self.deterministicUUID(
                        namespace: "cpdb-import-pinboard",
                        key: pb.identifier ?? pb.name
                    )
                if let existing = try Pinboard.filter(Column("uuid") == uuid).fetchOne(db) {
                    pastePinboardPkToCpdbId[pb.pk] = existing.id!
                } else {
                    var row = Pinboard(
                        uuid: uuid,
                        name: pb.name,
                        colorArgb: pb.colorArgb,
                        displayOrder: Int64(pastePinboardPkToCpdbId.count)
                    )
                    try row.insert(db)
                    pastePinboardPkToCpdbId[pb.pk] = row.id!
                }
            }
        }

        // Ensure a fallback device if Paste's table was empty.
        let fallbackDeviceId = try DeviceIdentity.ensureLocalDevice(in: target)

        var report = Report()
        // Map Paste snippet pk → cpdb entry id so we can populate pinboards after.
        var pastePkToCpdbEntryId: [Int64: Int64] = [:]

        try target.dbQueue.write { db in
            try source.forEachSnippet { snippet in
                report.totalRows += 1
                guard let blob = snippet.pasteboardBlob else {
                    report.skippedEmpty += 1
                    return
                }

                let items: [PasteboardSnapshot.Item]
                do {
                    items = try decoder.decode(blob)
                } catch TransformablePasteboardDecoder.DecodeError.emptyBlob {
                    report.skippedEmpty += 1
                    return
                } catch {
                    Log.importer.error("decode failed for Z_PK=\(snippet.pk, privacy: .public): \(String(describing: error), privacy: .public)")
                    report.decodeFailures += 1
                    return
                }

                if items.isEmpty {
                    report.skippedEmpty += 1
                    return
                }

                let snapshot = PasteboardSnapshot(
                    items: items,
                    capturedAt: Date(timeIntervalSince1970: snippet.createdAt + coreDataEpochOffset)
                )
                let hash = CanonicalHash.hash(items: snapshot.flavorItemsForHashing)

                if let existingId = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM entries WHERE content_hash = ? AND deleted_at IS NULL",
                    arguments: [hash]
                ) {
                    pastePkToCpdbEntryId[snippet.pk] = existingId
                    report.skippedDuplicate += 1
                    return
                }

                let appId: Int64? = snippet.sourceAppFk.flatMap { pasteAppPkToCpdbId[$0] }
                let deviceId = snippet.deviceFk.flatMap { pasteDevicePkToCpdbId[$0] } ?? fallbackDeviceId

                let kind = Self.kind(forZEnt: snippet.zEnt, snapshot: snapshot)
                let plain = snapshot.plainText
                let createdAt = snippet.createdAt + coreDataEpochOffset

                var entry = Entry(
                    uuid: Ingestor.newUUID(),
                    createdAt: createdAt,
                    capturedAt: createdAt,
                    kind: kind,
                    sourceAppId: appId,
                    sourceDeviceId: deviceId,
                    title: Self.title(for: snippet, snapshot: snapshot, plainText: plain),
                    textPreview: plain.map { String($0.prefix(2048)) },
                    contentHash: hash,
                    totalSize: snapshot.totalSize
                )
                try entry.insert(db)
                let entryId = entry.id!
                pastePkToCpdbEntryId[snippet.pk] = entryId

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
                        try row.insert(db, onConflict: .ignore)
                    }
                }

                // Thumbnails from Paste.
                if snippet.preview != nil || snippet.preview1 != nil {
                    var preview = PreviewRecord(
                        entryId: entryId,
                        thumbSmall: snippet.preview,
                        thumbLarge: snippet.preview1
                    )
                    try preview.insert(db, onConflict: .replace)
                }

                // FTS
                let appName = appId.flatMap { id in try? AppRecord.fetchOne(db, key: id)?.name } ?? nil
                try FtsIndex.indexEntry(
                    db: db,
                    entryId: entryId,
                    title: entry.title,
                    text: plain,
                    appName: appName
                )

                report.inserted += 1
                if report.inserted % 500 == 0 {
                    progress?(report)
                }
            }

            // Pinboard memberships — do last, once entries exist.
            let memberships = try source.pinboardMemberships()
            var displayOrder: [Int64: Int64] = [:]
            for (snippetPk, pinboardPk) in memberships {
                guard
                    let entryId = pastePkToCpdbEntryId[snippetPk],
                    let pinboardId = pastePinboardPkToCpdbId[pinboardPk]
                else { continue }
                let next = (displayOrder[pinboardId] ?? 0) + 1
                displayOrder[pinboardId] = next
                var row = PinboardEntry(
                    pinboardId: pinboardId,
                    entryId: entryId,
                    displayOrder: next
                )
                try row.insert(db, onConflict: .ignore)
            }
        }

        progress?(report)
        return report
    }

    // MARK: - Helpers

    static func kind(forZEnt ent: Int64, snapshot: PasteboardSnapshot) -> EntryKind {
        switch ent {
        case 7:  return .color
        case 8:  return .file
        case 9:  return .image
        case 10: return .link
        case 11: return .text
        default: return snapshot.kind
        }
    }

    static func title(
        for snippet: PasteCoreDataReader.Snippet,
        snapshot: PasteboardSnapshot,
        plainText: String?
    ) -> String? {
        if let title = snippet.title, !title.isEmpty { return title }
        if let urlName = snippet.urlName, !urlName.isEmpty { return urlName }
        return Ingestor.deriveTitle(from: snapshot, plainText: plainText)
    }

    static func uuidFromIdentifier(_ s: String?) -> Data? {
        guard let s = s, let uuid = UUID(uuidString: s) else { return nil }
        var bytes = uuid.uuid
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }

    static func randomUUIDData() -> Data {
        var bytes = UUID().uuid
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }

    /// Deterministic 16-byte "UUID" derived from a namespace + key via SHA-256.
    /// Stable across runs, so importers key on it without needing to store
    /// the original source identifier.
    static func deterministicUUID(namespace: String, key: String) -> Data {
        var hasher = CryptoKit.SHA256()
        hasher.update(data: Data(namespace.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(key.utf8))
        let digest = hasher.finalize()
        return Data(digest.prefix(16))
    }

    /// Paste stores app icons as either raw PNG/TIFF bytes or NSKeyedArchived
    /// NSImage. We only keep it if we can coerce it to something png-shaped;
    /// otherwise we drop it — icon isn't worth a multi-step decode here.
    static func decodeIcon(_ data: Data?) -> Data? {
        guard let data = data, data.count > 4 else { return nil }
        // Already a PNG?
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        // JPEG?
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return data }
        // Anything else (TIFF / bplist) — skip for now; NSWorkspace can derive
        // the icon at render time from the bundle id instead.
        return nil
    }
}
