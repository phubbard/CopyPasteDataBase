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
    ///
    /// First runs the one-time v1.x → v2.0 Application Support rename, so
    /// users upgrading from `local.cpdb` to `net.phfactor.cpdb` carry their
    /// existing DB, blob store, and lock file with them instead of starting
    /// fresh at the new path.
    public static func open() throws -> Store {
        Paths.migrateFromLegacySupportDirectoryIfNeeded()
        try Paths.ensureDirectoriesExist()
        return try Store(path: Paths.databaseURL.path)
    }

    /// Opens a database at an arbitrary path — used by tests and for read-only
    /// access to the Paste.db source during import.
    public init(path: String, readonly: Bool = false) throws {
        var config = Configuration()
        config.readonly = readonly
        config.foreignKeysEnabled = true
        // Wait, don't throw, on a contended write lock. Without this
        // a second connection to the same file (e.g. the menu-bar
        // app's daemon Store + a Preferences "Import URLs…" Store in
        // the same process, or the CLI racing the running app) gets
        // an immediate SQLITE_BUSY and the operation fails. 5s is
        // far longer than any single cpdb write transaction, so in
        // practice contended writers just queue briefly.
        config.busyMode = .timeout(5.0)
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
