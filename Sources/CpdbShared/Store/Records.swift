import Foundation
import GRDB

// MARK: - Entry kind

public enum EntryKind: String, Codable, CaseIterable, Sendable {
    case text, link, image, file, color, other
}

// MARK: - Entry

public struct Entry: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Sendable {
    public var id: Int64?
    public var uuid: Data
    public var createdAt: Double      // unix seconds (display ordering)
    public var capturedAt: Double     // unix seconds (when we saw it)
    public var kind: EntryKind
    public var sourceAppId: Int64?
    public var sourceDeviceId: Int64
    public var title: String?
    public var textPreview: String?
    public var contentHash: Data      // sha256, 32 bytes
    public var totalSize: Int64
    public var deletedAt: Double?
    /// Populated by the image-analysis pipeline for image entries. Nil for
    /// non-image entries and for image entries that haven't been analysed
    /// yet.
    public var ocrText: String?
    public var imageTags: String?     // comma-separated, lowercased
    public var analyzedAt: Double?    // NULL = never analysed; set even on empty results
    /// User-pinned entries skip eviction policies and float to the top
    /// of the popup. Stored as INTEGER 0/1 in SQLite. Defaults to false.
    public var pinned: Bool = false
    /// Set by the time-window / size-budget eviction policies when
    /// flavor body bytes are discarded for this entry. Metadata +
    /// thumbnails remain. Nil = body bytes still present locally.
    /// Survives CloudKit round-trip so other devices know not to
    /// resurrect the body bytes.
    public var bodyEvictedAt: Double?
    /// Page / video title fetched in the background for kind=.link
    /// entries. YouTube URLs hit oEmbed; everything else gets an
    /// HTML scrape (og:title → <title>). NULL when never fetched OR
    /// fetched but page had no title. Indexed by FTS5.
    public var linkTitle: String?
    /// Sentinel for the link-title backfill: NULL = haven't tried;
    /// non-NULL = at least one fetch attempt completed (success or
    /// failure). The backfill query skips non-NULL rows by default.
    public var linkFetchedAt: Double?

    /// Canonical-hash era of `contentHash`: 1 = legacy full-flavor-set
    /// hash, 2 = semantic content identity (idv2-r1). Rows that cannot
    /// be rehashed (body evicted, blob missing) stay 1 forever. See
    /// docs/canonical-hash-v2.md.
    public var hashVersion: Int = 1
    /// v1 hash retained after the v2 rehash — forensics + the importer's
    /// dual-era dedup probe. NULL on rows that were born v2.
    public var prevContentHash: Data?
    /// The identity rung that produced a v2 hash (image/file/url/text/
    /// color/fallback). NULL on v1 rows. Carried on the CloudKit wire
    /// for deterministic conflict resolution.
    public var identityTag: String?

    /// Unix-epoch seconds of the last user-visible mutable-state change
    /// (pin, delete, restore). Drives last-writer-wins on pull so undo
    /// propagates and pin/unpin races resolve deterministically. Set to
    /// `created_at` on insert; bumped on every mutation.
    public var modifiedAt: Double = 0

    /// JSON array of data chips detected in this entry's text (dates,
    /// addresses, phone numbers, URLs, tracking numbers, flights,
    /// money). NULL = not yet scanned by the chip detector. Adopt-once
    /// enrichment, same convention as `linkTitle`.
    public var chipsJson: String?
    /// On-device Foundation-Models-generated short title. Distinct from
    /// `title` (UTI/pasteboard-derived, never model-generated). NULL =
    /// not yet enriched.
    public var aiTitle: String?
    /// On-device Foundation-Models-generated summary. NULL = not yet
    /// enriched.
    public var aiSummary: String?

    public static let databaseTableName = "entries"

    enum CodingKeys: String, CodingKey {
        case id
        case uuid
        case createdAt       = "created_at"
        case capturedAt      = "captured_at"
        case kind
        case sourceAppId     = "source_app_id"
        case sourceDeviceId  = "source_device_id"
        case title
        case textPreview     = "text_preview"
        case contentHash     = "content_hash"
        case totalSize       = "total_size"
        case deletedAt       = "deleted_at"
        case ocrText         = "ocr_text"
        case imageTags       = "image_tags"
        case analyzedAt      = "analyzed_at"
        case pinned
        case bodyEvictedAt   = "body_evicted_at"
        case linkTitle       = "link_title"
        case linkFetchedAt   = "link_fetched_at"
        case hashVersion     = "hash_version"
        case prevContentHash = "prev_content_hash"
        case identityTag     = "identity_tag"
        case modifiedAt      = "modified_at"
        case chipsJson       = "chips_json"
        case aiTitle         = "ai_title"
        case aiSummary       = "ai_summary"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(
        id: Int64? = nil,
        uuid: Data,
        createdAt: Double,
        capturedAt: Double,
        kind: EntryKind,
        sourceAppId: Int64? = nil,
        sourceDeviceId: Int64,
        title: String? = nil,
        textPreview: String? = nil,
        contentHash: Data,
        totalSize: Int64,
        deletedAt: Double? = nil,
        ocrText: String? = nil,
        imageTags: String? = nil,
        analyzedAt: Double? = nil,
        pinned: Bool = false,
        bodyEvictedAt: Double? = nil,
        linkTitle: String? = nil,
        linkFetchedAt: Double? = nil,
        hashVersion: Int = 1,
        prevContentHash: Data? = nil,
        identityTag: String? = nil,
        modifiedAt: Double = 0,
        chipsJson: String? = nil,
        aiTitle: String? = nil,
        aiSummary: String? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.createdAt = createdAt
        self.capturedAt = capturedAt
        self.kind = kind
        self.sourceAppId = sourceAppId
        self.sourceDeviceId = sourceDeviceId
        self.title = title
        self.textPreview = textPreview
        self.contentHash = contentHash
        self.totalSize = totalSize
        self.deletedAt = deletedAt
        self.ocrText = ocrText
        self.imageTags = imageTags
        self.analyzedAt = analyzedAt
        self.pinned = pinned
        self.bodyEvictedAt = bodyEvictedAt
        self.linkTitle = linkTitle
        self.linkFetchedAt = linkFetchedAt
        self.hashVersion = hashVersion
        self.prevContentHash = prevContentHash
        self.identityTag = identityTag
        self.modifiedAt = modifiedAt
        self.chipsJson = chipsJson
        self.aiTitle = aiTitle
        self.aiSummary = aiSummary
    }
}

// MARK: - Flavor

public struct Flavor: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var entryId: Int64
    public var uti: String
    public var size: Int64
    public var data: Data?
    public var blobKey: String?

    public static let databaseTableName = "entry_flavors"

    enum CodingKeys: String, CodingKey {
        case entryId = "entry_id"
        case uti
        case size
        case data
        case blobKey = "blob_key"
    }

    public init(entryId: Int64, uti: String, size: Int64, data: Data?, blobKey: String?) {
        self.entryId = entryId
        self.uti = uti
        self.size = size
        self.data = data
        self.blobKey = blobKey
    }
}

// MARK: - App

public struct AppRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var bundleId: String
    public var name: String
    public var iconPng: Data?

    public static let databaseTableName = "apps"

    enum CodingKeys: String, CodingKey {
        case id
        case bundleId = "bundle_id"
        case name
        case iconPng  = "icon_png"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(id: Int64? = nil, bundleId: String, name: String, iconPng: Data? = nil) {
        self.id = id
        self.bundleId = bundleId
        self.name = name
        self.iconPng = iconPng
    }
}

// MARK: - Device

public struct Device: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var identifier: String
    public var name: String
    public var kind: String

    public static let databaseTableName = "devices"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(id: Int64? = nil, identifier: String, name: String, kind: String) {
        self.id = id
        self.identifier = identifier
        self.name = name
        self.kind = kind
    }
}

// MARK: - Pinboard

public struct Pinboard: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var uuid: Data
    public var name: String
    public var colorArgb: Int64?
    public var displayOrder: Int64

    public static let databaseTableName = "pinboards"

    enum CodingKeys: String, CodingKey {
        case id
        case uuid
        case name
        case colorArgb    = "color_argb"
        case displayOrder = "display_order"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(id: Int64? = nil, uuid: Data, name: String, colorArgb: Int64?, displayOrder: Int64) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.colorArgb = colorArgb
        self.displayOrder = displayOrder
    }
}

// MARK: - PinboardEntry

public struct PinboardEntry: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var pinboardId: Int64
    public var entryId: Int64
    public var displayOrder: Int64

    public static let databaseTableName = "pinboard_entries"

    enum CodingKeys: String, CodingKey {
        case pinboardId   = "pinboard_id"
        case entryId      = "entry_id"
        case displayOrder = "display_order"
    }

    public init(pinboardId: Int64, entryId: Int64, displayOrder: Int64) {
        self.pinboardId = pinboardId
        self.entryId = entryId
        self.displayOrder = displayOrder
    }
}

// MARK: - Preview

public struct PreviewRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var entryId: Int64
    public var thumbSmall: Data?
    public var thumbLarge: Data?

    public static let databaseTableName = "previews"

    enum CodingKeys: String, CodingKey {
        case entryId    = "entry_id"
        case thumbSmall = "thumb_small"
        case thumbLarge = "thumb_large"
    }

    public init(entryId: Int64, thumbSmall: Data?, thumbLarge: Data?) {
        self.entryId = entryId
        self.thumbSmall = thumbSmall
        self.thumbLarge = thumbLarge
    }
}
