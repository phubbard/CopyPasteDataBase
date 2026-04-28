import Foundation
import GRDB

/// Storage usage breakdown for the cpdb library.
///
/// Three layers, ordered from "always cheap" to "expensive and
/// evictable":
///
///   1. Metadata — entries + FTS shadow rows + apps + devices +
///      pinboards + cloudkit_state. SQLite scalar fields. Tiny per
///      row (~200 bytes), forever-keep even at 100k+ entries.
///   2. Thumbnails — JPEG previews under previews.thumb_small /
///      thumb_large. Medium-sized (~30 KB per image entry). Always
///      kept; evicting them loses the visual anchor on cards.
///   3. Flavor bodies — raw NSPasteboard flavor bytes, stored
///      inline in entry_flavors.data when small or spilled to
///      disk under blobs/<ab>/<cd>/<sha256> when ≥ 256 KB. The
///      tier eviction policies (time-window, size-budget) target.
///
/// `total` is the sum across all three layers. This is the number
/// the user sees in Preferences and on `cpdb storage` output.
public struct StorageReport: Sendable, Equatable {
    public var metadataBytes: Int64
    public var thumbnailBytes: Int64
    /// Inline-flavor bytes in entry_flavors.data. Counted separately
    /// from spilled blobs because the SQLite page accounting includes
    /// these in the .db file's size on disk.
    public var inlineFlavorBytes: Int64
    /// On-disk blob bytes (entries with blob_key, content-addressed
    /// under the blob store directory). Sum of file sizes.
    public var blobBytes: Int64
    /// Total live (non-tombstoned) entry count. Useful as a
    /// denominator for "average entry size" calculations.
    public var liveEntryCount: Int64
    /// Pinned entry count — never evicted.
    public var pinnedEntryCount: Int64
    /// Live entries whose flavor body bytes were discarded by an
    /// eviction policy. Search history + thumbnails are still
    /// present; only the paste-back content is gone.
    public var bodyEvictedEntryCount: Int64

    public var flavorBytes: Int64 { inlineFlavorBytes + blobBytes }
    public var total: Int64 { metadataBytes + thumbnailBytes + flavorBytes }

    public init(
        metadataBytes: Int64,
        thumbnailBytes: Int64,
        inlineFlavorBytes: Int64,
        blobBytes: Int64,
        liveEntryCount: Int64,
        pinnedEntryCount: Int64,
        bodyEvictedEntryCount: Int64 = 0
    ) {
        self.metadataBytes = metadataBytes
        self.thumbnailBytes = thumbnailBytes
        self.inlineFlavorBytes = inlineFlavorBytes
        self.blobBytes = blobBytes
        self.liveEntryCount = liveEntryCount
        self.pinnedEntryCount = pinnedEntryCount
        self.bodyEvictedEntryCount = bodyEvictedEntryCount
    }

    /// Pretty-printed tabular output for CLI / About-window display.
    /// Right-aligned bytes column with `ByteCountFormatter` so 1.4 GB
    /// reads as "1.4 GB" not "1,400,000,000 bytes."
    public func formatted(width: Int = 18) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        func row(_ label: String, _ bytes: Int64, _ note: String = "") -> String {
            let b = fmt.string(fromByteCount: bytes)
            let pad = max(0, width - label.count)
            let padded = label + String(repeating: " ", count: pad)
            return note.isEmpty
                ? "  \(padded)\(b.padded(left: 12))"
                : "  \(padded)\(b.padded(left: 12))  \(note)"
        }
        var lines: [String] = []
        lines.append("Library size:     \(fmt.string(fromByteCount: total))")
        lines.append("")
        lines.append(row("Metadata", metadataBytes, "always kept"))
        lines.append(row("Thumbnails", thumbnailBytes, "always kept"))
        lines.append(row("Flavor bodies", flavorBytes, "evictable"))
        lines.append(row("    inline", inlineFlavorBytes))
        lines.append(row("    on-disk blobs", blobBytes))
        lines.append("")
        lines.append("  \(liveEntryCount) live entries (\(pinnedEntryCount) pinned, skipped by eviction)")
        if bodyEvictedEntryCount > 0 {
            lines.append("  \(bodyEvictedEntryCount) entries with bodies discarded by retention policy")
        }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    /// Pad a string with spaces on the LEFT to a target visual width.
    /// Used by StorageReport.formatted() to right-align byte columns.
    func padded(left width: Int) -> String {
        let pad = max(0, width - self.count)
        return String(repeating: " ", count: pad) + self
    }
}

/// Compute a `StorageReport` against a live cpdb database. Single
/// public entry point; combines four cheap COUNT/SUM queries with
/// an O(N-blobs) directory walk for on-disk blob sizes.
public enum StorageInspector {

    public static func report(store: Store, blobsRoot: URL = Paths.blobsDirectory) throws -> StorageReport {
        let counts = try store.dbQueue.read { db -> (
            entries: Int64,
            pinned: Int64,
            evicted: Int64,
            metadataBytes: Int64,
            thumbBytes: Int64,
            inlineBytes: Int64
        ) in
            // Metadata: every scalar column in `entries` plus the
            // FTS shadow + apps + devices. We approximate as
            // SUM(LENGTH(every TEXT/BLOB column)) + a fixed-cost
            // estimate per row for the integers/reals (~64 bytes).
            // Tight enough for "is it KB or MB?" UX; not exact.
            let entries: Int64 = try Int64.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL"
            ) ?? 0
            let pinned: Int64 = try Int64.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL AND pinned = 1"
            ) ?? 0
            let evicted: Int64 = try Int64.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL AND body_evicted_at IS NOT NULL"
            ) ?? 0
            let entryRowBytes: Int64 = try Int64.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(
                        64
                        + LENGTH(uuid)
                        + LENGTH(COALESCE(title, ''))
                        + LENGTH(COALESCE(text_preview, ''))
                        + LENGTH(content_hash)
                        + LENGTH(COALESCE(ocr_text, ''))
                        + LENGTH(COALESCE(image_tags, ''))
                    ), 0)
                    FROM entries WHERE deleted_at IS NULL
                """
            ) ?? 0
            // FTS shadow: per-row ~ 1.5x text_preview + ocr_text size,
            // approximated.
            let ftsBytes: Int64 = try Int64.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(
                        LENGTH(COALESCE(title, ''))
                        + LENGTH(COALESCE(text, ''))
                        + LENGTH(COALESCE(app_name, ''))
                        + LENGTH(COALESCE(ocr_text, ''))
                        + LENGTH(COALESCE(image_tags, ''))
                    ), 0)
                    FROM entries_fts
                """
            ) ?? 0
            let metadataBytes = entryRowBytes + ftsBytes
            // Thumbnails — both columns inline in the previews table.
            let thumbBytes: Int64 = try Int64.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(
                        IFNULL(LENGTH(thumb_small), 0)
                        + IFNULL(LENGTH(thumb_large), 0)
                    ), 0) FROM previews
                """
            ) ?? 0
            // Inline flavor bytes — entry_flavors.data when set.
            let inlineBytes: Int64 = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(IFNULL(LENGTH(data), 0)), 0) FROM entry_flavors"
            ) ?? 0
            return (entries, pinned, evicted, metadataBytes, thumbBytes, inlineBytes)
        }

        // On-disk blob bytes — walk the blob store. Skip silently
        // when the directory doesn't exist (fresh install / no
        // spilled flavors yet).
        var blobBytes: Int64 = 0
        if FileManager.default.fileExists(atPath: blobsRoot.path) {
            if let enumerator = FileManager.default.enumerator(
                at: blobsRoot,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator {
                    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        blobBytes += Int64(size)
                    }
                }
            }
        }

        return StorageReport(
            metadataBytes: counts.metadataBytes,
            thumbnailBytes: counts.thumbBytes,
            inlineFlavorBytes: counts.inlineBytes,
            blobBytes: blobBytes,
            liveEntryCount: counts.entries,
            pinnedEntryCount: counts.pinned,
            bodyEvictedEntryCount: counts.evicted
        )
    }
}
