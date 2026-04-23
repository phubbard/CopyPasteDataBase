#if os(macOS)
import Foundation
import GRDB
import CpdbShared

/// Read-only view over a Paste (`com.wiheads.paste`) Core Data SQLite store.
///
/// Paste is a Core Data app, so tables use `Z_`-prefixed names and entity
/// subclassing is encoded in `Z_ENT`. This reader hides those details and
/// exposes the rows the importer actually cares about.
public final class PasteCoreDataReader {
    public let dbQueue: DatabaseQueue
    public let databaseURL: URL

    public init(databaseURL: URL) throws {
        var config = Configuration()
        config.readonly = true
        self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        self.databaseURL = databaseURL
    }

    // MARK: - Shape types

    public struct Application: Sendable {
        public var pk: Int64
        public var bundleId: String?
        public var name: String?
        public var icon: Data?
    }

    public struct DeviceRow: Sendable {
        public var pk: Int64
        public var identifier: String?
        public var name: String?
    }

    public struct PinboardRow: Sendable {
        public var pk: Int64
        public var name: String
        public var colorArgb: Int64?
        public var identifier: String?   // ZIDENTIFIER
    }

    public struct Snippet: Sendable {
        public var pk: Int64
        public var zEnt: Int64               // 7..11 for ColorSnippet..TextSnippet
        public var createdAt: Double         // Core Data reference date
        public var title: String?
        public var textLength: Int64?
        public var totalSize: Int64?
        public var numberOfFiles: Int64?
        public var checksum: String?
        public var dataPk: Int64?            // ZDATA FK
        public var deviceFk: Int64?
        public var sourceAppFk: Int64?
        public var preview: Data?            // JPEG @1x
        public var preview1: Data?           // JPEG @2x
        public var urlName: String?
        /// Joined from ZSNIPPETDATA.ZPASTEBOARDITEMS. Loaded in the same
        /// cursor query to avoid reentrant reads on the source database.
        public var pasteboardBlob: Data?
    }

    public struct SnippetPayload: Sendable {
        public var pasteboardItems: Data
    }

    // MARK: - Reads

    public func allApplications() throws -> [Application] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT Z_PK, ZBUNDLEIDENTIFIER, ZNAME, ZICON FROM ZAPPLICATION"
            ).map {
                Application(
                    pk: $0["Z_PK"],
                    bundleId: $0["ZBUNDLEIDENTIFIER"],
                    name: $0["ZNAME"],
                    icon: $0["ZICON"]
                )
            }
        }
    }

    public func allDevices() throws -> [DeviceRow] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT Z_PK, ZIDENTIFIER, ZNAME FROM ZDEVICE"
            ).map {
                DeviceRow(pk: $0["Z_PK"], identifier: $0["ZIDENTIFIER"], name: $0["ZNAME"])
            }
        }
    }

    /// Only `Pinboard` rows (Z_ENT=15). Skips the built-in PasteboardHistory (14).
    public func allPinboards() throws -> [PinboardRow] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT Z_PK, ZNAME, ZCOLOR, ZIDENTIFIER, ZDISPLAYORDER
                    FROM ZSNIPPETLIST
                    WHERE Z_ENT = 15
                    ORDER BY ZDISPLAYORDER
                """
            ).map {
                PinboardRow(
                    pk: $0["Z_PK"],
                    name: $0["ZNAME"] ?? "Pinboard",
                    colorArgb: $0["ZCOLOR"],
                    identifier: $0["ZIDENTIFIER"]
                )
            }
        }
    }

    /// Count of live snippets we expect to import.
    public func snippetCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ZSNIPPET") ?? 0
        }
    }

    /// Iterate snippets oldest-first so the newly-imported rows end up with
    /// ascending `created_at` order in the target DB. The pasteboard blob is
    /// joined in so the caller never needs to re-enter the source connection.
    public func forEachSnippet(_ body: (Snippet) throws -> Void) throws {
        try dbQueue.read { db in
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    SELECT s.Z_PK, s.Z_ENT, s.ZCREATEDAT, s.ZTITLE, s.ZTEXTLENGTH, s.ZTOTALSIZE,
                           s.ZNUMBEROFFILES, s.ZCHECKSUM, s.ZDATA, s.ZDEVICE, s.ZSOURCEAPPLICATION,
                           s.ZPREVIEW, s.ZPREVIEW1, s.ZURLNAME,
                           d.ZPASTEBOARDITEMS AS blob
                    FROM ZSNIPPET s
                    LEFT JOIN ZSNIPPETDATA d ON d.Z_PK = s.ZDATA
                    ORDER BY s.ZCREATEDAT ASC
                """
            )
            while let row = try cursor.next() {
                let s = Snippet(
                    pk: row["Z_PK"],
                    zEnt: row["Z_ENT"],
                    createdAt: row["ZCREATEDAT"] ?? 0.0,
                    title: row["ZTITLE"],
                    textLength: row["ZTEXTLENGTH"],
                    totalSize: row["ZTOTALSIZE"],
                    numberOfFiles: row["ZNUMBEROFFILES"],
                    checksum: row["ZCHECKSUM"],
                    dataPk: row["ZDATA"],
                    deviceFk: row["ZDEVICE"],
                    sourceAppFk: row["ZSOURCEAPPLICATION"],
                    preview: row["ZPREVIEW"],
                    preview1: row["ZPREVIEW1"],
                    urlName: row["ZURLNAME"],
                    pasteboardBlob: row["blob"]
                )
                try body(s)
            }
        }
    }

    /// Fetch the raw pasteboard blob for a snippet's `ZDATA` pk.
    public func pasteboardBlob(forDataPk pk: Int64) throws -> Data? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT ZPASTEBOARDITEMS FROM ZSNIPPETDATA WHERE Z_PK = ?",
                arguments: [pk]
            )?["ZPASTEBOARDITEMS"]
        }
    }

    /// Fetch raw blobs for N snippets of a given Z_ENT — test helper.
    public func sampleBlobs(forEntity ent: Int, limit: Int) throws -> [Data] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT d.ZPASTEBOARDITEMS AS blob
                    FROM ZSNIPPET s
                    JOIN ZSNIPPETDATA d ON d.Z_PK = s.ZDATA
                    WHERE s.Z_ENT = ? AND d.ZPASTEBOARDITEMS IS NOT NULL
                    ORDER BY s.ZCREATEDAT DESC
                    LIMIT ?
                """,
                arguments: [ent, limit]
            ).compactMap { $0["blob"] as Data? }
        }
    }

    /// Fetch N raw blobs whose first byte matches `leading` (0x01 for inline,
    /// 0x02 for external-ref). Used by decoder tests.
    public func sampleBlobs(withLeadingByte leading: UInt8, limit: Int) throws -> [Data] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT d.ZPASTEBOARDITEMS AS blob
                    FROM ZSNIPPETDATA d
                    WHERE d.ZPASTEBOARDITEMS IS NOT NULL
                      AND substr(hex(d.ZPASTEBOARDITEMS), 1, 2) = ?
                    LIMIT ?
                """,
                arguments: [String(format: "%02X", leading), limit]
            ).compactMap { $0["blob"] as Data? }
        }
    }

    /// Pairs of (snippet pk, pinboard pk) from the join table.
    public func pinboardMemberships() throws -> [(snippetPk: Int64, pinboardPk: Int64)] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT Z_6SNIPPETS, Z_13LISTS FROM Z_6LISTS"
            ).map { ($0["Z_6SNIPPETS"], $0["Z_13LISTS"]) }
        }
    }
}
#endif
