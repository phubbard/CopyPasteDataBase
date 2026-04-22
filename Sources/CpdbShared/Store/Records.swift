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
        analyzedAt: Double? = nil
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
