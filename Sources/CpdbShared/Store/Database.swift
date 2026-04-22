import Foundation
import GRDB

/// Thin wrapper around a GRDB `DatabaseQueue`.
///
/// We use `DatabaseQueue` rather than `DatabasePool` because all writes funnel
/// through a single daemon process, so there's no contention to absorb. If we
/// ever run concurrent readers from the CLI while the daemon is writing, SQLite
/// WAL mode (enabled by default by GRDB) handles that cleanly.
public final class Store {
    public let dbQueue: DatabaseQueue

    /// Opens (or creates) the database at `Paths.databaseURL` and runs migrations.
    public static func open() throws -> Store {
        try Paths.ensureDirectoriesExist()
        return try Store(path: Paths.databaseURL.path)
    }

    /// Opens a database at an arbitrary path — used by tests and for read-only
    /// access to the Paste.db source during import.
    public init(path: String, readonly: Bool = false) throws {
        var config = Configuration()
        config.readonly = readonly
        config.foreignKeysEnabled = true
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        if !readonly {
            try Self.migrate(dbQueue)
        }
    }

    /// In-memory store for unit tests.
    public static func inMemory() throws -> Store {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let q = try DatabaseQueue(configuration: config)
        try migrate(q)
        return Store(dbQueue: q)
    }

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        Schema.registerMigrations(in: &migrator)
        try migrator.migrate(dbQueue)
    }
}
