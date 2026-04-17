import ArgumentParser
import CpdbCore
import Foundation
import GRDB

// Placeholder error for anything still unimplemented.
struct NotImplemented: LocalizedError {
    let what: String
    var errorDescription: String? { "\(what) is not implemented yet" }
    static func stub(_ what: String) -> NotImplemented { .init(what: what) }
}

// MARK: - import

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import an existing Paste.db (com.wiheads.paste)."
    )
    @Argument(help: "Path to Paste.db. Defaults to the canonical location under ~/Library/Application Support.")
    var path: String?

    func run() throws {
        let url = path.map { URL(fileURLWithPath: $0) } ?? Paths.defaultPasteDatabaseURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.stderr("error: no Paste database at \(url.path)")
            throw ExitCode.failure
        }
        Log.stderr("Importing from \(url.path)")
        let store = try Store.open()
        let importer = try PasteDbImporter(sourcePath: url, target: store)
        let report = try importer.run { progress in
            Log.stderr("  … \(progress.inserted) inserted, \(progress.skippedDuplicate) dup, \(progress.decodeFailures) fail of \(progress.totalRows)")
        }
        print("Import complete.")
        print("  total rows in Paste.db : \(report.totalRows)")
        print("  inserted               : \(report.inserted)")
        print("  duplicates (skipped)   : \(report.skippedDuplicate)")
        print("  empty  (skipped)       : \(report.skippedEmpty)")
        print("  decode failures        : \(report.decodeFailures)")
    }
}

// MARK: - list

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List recent clipboard entries."
    )
    @Option(name: .shortAndLong, help: "Maximum rows to show.")
    var limit: Int = 20
    @Option(name: .shortAndLong, help: "Filter by kind (text|link|image|file|color|other).")
    var kind: String?

    func run() throws {
        let store = try Store.open()
        let rows: [Row] = try store.dbQueue.read { db in
            var sql = """
                SELECT e.id, e.created_at, e.kind, e.title, e.text_preview, e.total_size,
                       a.name AS app_name
                FROM entries e
                LEFT JOIN apps a ON a.id = e.source_app_id
                WHERE e.deleted_at IS NULL
            """
            var args: StatementArguments = []
            if let k = kind {
                sql += " AND e.kind = ?"
                args += [k]
            }
            sql += " ORDER BY e.created_at DESC LIMIT ?"
            args += [limit]
            return try Row.fetchAll(db, sql: sql, arguments: args)
        }
        for row in rows {
            Output.printListRow(row)
        }
    }
}

// MARK: - search

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Full-text search across clipboard history."
    )
    @Argument(help: "Query (tokens AND together by default).")
    var query: String
    @Option(name: .shortAndLong, help: "Maximum rows to show.")
    var limit: Int = 20

    func run() throws {
        let store = try Store.open()
        try store.dbQueue.read { db in
            let hits = try FtsIndex.search(db: db, query: query, limit: limit)
            for hit in hits {
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT e.id, e.created_at, e.kind, e.title, e.text_preview, e.total_size,
                               a.name AS app_name
                        FROM entries e
                        LEFT JOIN apps a ON a.id = e.source_app_id
                        WHERE e.id = ?
                    """,
                    arguments: [hit.entryId]
                )
                guard let row else { continue }
                Output.printSearchHit(row: row, snippet: hit.snippet)
            }
        }
    }
}

// MARK: - show

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show details of a specific entry."
    )
    @Argument(help: "Entry id.")
    var id: Int64

    func run() throws {
        let store = try Store.open()
        try store.dbQueue.read { db in
            guard let entry = try Entry.fetchOne(db, key: id) else {
                throw NotImplemented(what: "entry \(id) not found")
            }
            let appRow = try entry.sourceAppId.flatMap { try AppRecord.fetchOne(db, key: $0) }
            let flavors = try Row.fetchAll(
                db,
                sql: "SELECT uti, size, (blob_key IS NOT NULL) AS spilled FROM entry_flavors WHERE entry_id = ? ORDER BY size DESC",
                arguments: [id]
            )
            Output.printEntryDetail(entry: entry, app: appRow, flavors: flavors)
        }
    }
}

// MARK: - copy

struct CopyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy",
        abstract: "Restore an entry to the pasteboard."
    )
    @Argument(help: "Entry id.")
    var id: Int64

    func run() throws {
        let store = try Store.open()
        let restorer = Restorer(store: store)
        try restorer.restoreToPasteboard(entryId: id)
        Log.stderr("Restored entry \(id) to pasteboard.")
    }
}

// MARK: - stats

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Show database statistics."
    )
    func run() throws {
        let store = try Store.open()
        try store.dbQueue.read { db in
            let entries = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL") ?? 0
            let tombs   = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NOT NULL") ?? 0
            let flavors = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry_flavors") ?? 0
            let apps    = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM apps") ?? 0
            let pinboards = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pinboards") ?? 0
            let inlineBytes = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM entry_flavors WHERE data IS NOT NULL") ?? 0
            let spilledBytes = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM entry_flavors WHERE blob_key IS NOT NULL") ?? 0

            let dbSize = (try? FileManager.default.attributesOfItem(atPath: Paths.databaseURL.path)[.size] as? Int) ?? 0
            let blobsDirSize = Output.directorySize(Paths.blobsDirectory)

            print("cpdb database  : \(Paths.databaseURL.path)")
            print("db file size   : \(Output.bytes(Int64(dbSize)))")
            print("blob dir size  : \(Output.bytes(blobsDirSize))")
            print("entries (live) : \(entries)")
            print("entries (tomb.): \(tombs)")
            print("flavor rows    : \(flavors)")
            print("inline bytes   : \(Output.bytes(inlineBytes))")
            print("spilled bytes  : \(Output.bytes(spilledBytes))")
            print("apps           : \(apps)")
            print("pinboards      : \(pinboards)")
        }
    }
}

// MARK: - regenerate-thumbnails

struct RegenerateThumbnails: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "regenerate-thumbnails",
        abstract: "(Re-)generate thumbnail previews and fix misclassified image entries.",
        discussion: """
        Handles two related jobs:

        1. Generates thumbnails for kind=image entries that don't have them
           (image entries captured before v1.1.0, or from the Paste import
           that only got a large thumbnail).

        2. Reclassifies kind=file entries whose pasteboard actually contained
           a substantive image payload (>= 1 KB of PNG/JPEG/TIFF/HEIC) and
           was misclassified as 'file' by the old heuristic. Screenshot tools
           like CleanShot copy both a file-URL and the inline PNG — the
           image is the real content, so these should render as images, not
           generic file icons.

        By default, only entries with no preview are processed. Use --force
        to rebuild thumbnails for every image entry.
        """
    )

    @Flag(name: .long, help: "Regenerate even for entries that already have a preview.")
    var force: Bool = false

    @Flag(name: .long, help: "Skip the reclassification pass; only touch thumbnails.")
    var noReclassify: Bool = false

    @Option(name: .shortAndLong, help: "Cap the number of entries processed (for spot-checks).")
    var limit: Int?

    /// UTI priority when an entry has multiple image flavors. Matches
    /// PasteboardSnapshot.imageFlavorData — keeps ingestion and backfill
    /// producing thumbnails from the same source where possible.
    private static let imageUtiPriority = [
        "public.png",
        "public.jpeg",
        "public.tiff",
        "public.heic",
        "public.image",
    ]

    func run() throws {
        let store = try Store.open()
        let blobs = BlobStore()

        var reclassified = 0
        if !noReclassify {
            reclassified = try reclassifyMisclassifiedFileEntries(store: store, blobs: blobs)
            if reclassified > 0 {
                Log.stderr("Reclassified \(reclassified) file entries to image.")
            }
        }

        // Find candidate entry ids for thumbnail generation. Runs after the
        // reclassification pass so newly-minted image entries get thumbs too.
        let candidates: [Int64] = try store.dbQueue.read { db in
            var sql = """
                SELECT e.id FROM entries e
                WHERE e.kind = 'image' AND e.deleted_at IS NULL
            """
            if !force {
                sql += """

                      AND NOT EXISTS (
                          SELECT 1 FROM previews p
                          WHERE p.entry_id = e.id
                            AND (p.thumb_large IS NOT NULL OR p.thumb_small IS NOT NULL)
                      )
                """
            }
            sql += " ORDER BY e.created_at DESC"
            if let limit = limit {
                sql += " LIMIT \(limit)"
            }
            return try Int64.fetchAll(db, sql: sql)
        }

        if candidates.isEmpty && reclassified == 0 {
            print("Nothing to do.")
            return
        }

        Log.stderr("Processing \(candidates.count) image entries…")

        var generated = 0
        var decodeFailed = 0
        var noImageFlavor = 0

        for entryId in candidates {
            let imageData = try Self.loadImageBytes(entryId: entryId, store: store, blobs: blobs)
            guard let imageData = imageData else {
                noImageFlavor += 1
                continue
            }

            let thumbs = Thumbnailer.generate(from: imageData)
            guard thumbs.small != nil || thumbs.large != nil else {
                decodeFailed += 1
                continue
            }

            try store.dbQueue.write { db in
                var preview = PreviewRecord(
                    entryId: entryId,
                    thumbSmall: thumbs.small,
                    thumbLarge: thumbs.large
                )
                try preview.insert(db, onConflict: .replace)
            }

            generated += 1
            if generated % 25 == 0 {
                Log.stderr("  … \(generated) / \(candidates.count)")
            }
        }

        print("Done.")
        print("  reclassified file→image : \(reclassified)")
        print("  thumbnails generated    : \(generated)")
        print("  decode failures         : \(decodeFailed)")
        print("  no image flavor         : \(noImageFlavor)")
    }

    /// Find `kind=file` entries whose flavor set contains a substantive image
    /// payload (>= 1 KB of PNG/JPEG/TIFF/HEIC) and bump their kind to
    /// 'image'. This retroactively applies the v1.1.1 classifier to entries
    /// ingested by the earlier file-wins heuristic.
    private func reclassifyMisclassifiedFileEntries(store: Store, blobs: BlobStore) throws -> Int {
        let imageUtis = [
            "public.png",
            "public.jpeg",
            "public.tiff",
            "public.heic",
            "public.heif",
            "public.image",
        ]
        // Parameterise the IN clause.
        let placeholders = Array(repeating: "?", count: imageUtis.count).joined(separator: ",")
        let ids: [Int64] = try store.dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT e.id
                    FROM entries e
                    JOIN entry_flavors f ON f.entry_id = e.id
                    WHERE e.kind = 'file'
                      AND e.deleted_at IS NULL
                      AND f.uti IN (\(placeholders))
                      AND f.size >= \(PasteboardSnapshot.minImageBytes)
                    ORDER BY e.created_at DESC
                """,
                arguments: StatementArguments(imageUtis)
            )
        }
        guard !ids.isEmpty else { return 0 }
        try store.dbQueue.write { db in
            let idList = ids.map(String.init).joined(separator: ",")
            try db.execute(
                sql: "UPDATE entries SET kind = 'image' WHERE id IN (\(idList))"
            )
        }
        return ids.count
    }

    /// Find the best image flavor for an entry and return its decoded bytes
    /// (inline or spilled). Returns nil if the entry has no image flavor —
    /// rare but possible for legacy rows.
    private static func loadImageBytes(
        entryId: Int64,
        store: Store,
        blobs: BlobStore
    ) throws -> Data? {
        try store.dbQueue.read { db in
            for uti in imageUtiPriority {
                if let row = try Row.fetchOne(
                    db,
                    sql: "SELECT data, blob_key FROM entry_flavors WHERE entry_id = ? AND uti = ?",
                    arguments: [entryId, uti]
                ) {
                    return try blobs.load(
                        inline: row["data"] as Data?,
                        blobKey: row["blob_key"] as String?
                    )
                }
            }
            return nil
        }
    }
}

// MARK: - gc

struct Gc: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "Vacuum the database and remove orphan blobs."
    )
    func run() throws {
        let store = try Store.open()
        try store.dbQueue.write { db in
            try db.execute(sql: "VACUUM")
        }
        // Orphan blob cleanup comes later — keep this safe for now.
        Log.stderr("VACUUM complete. (Orphan blob cleanup not yet implemented.)")
    }
}
