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
