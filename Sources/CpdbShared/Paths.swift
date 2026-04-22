import Foundation

/// Filesystem locations used by cpdb.
///
/// The placeholder bundle id `local.cpdb` is used until we ship a signed app
/// bundle with a real reverse-DNS id. When that happens, `migrateFromLegacy()`
/// will handle the move.
public enum Paths {
    public static let bundleId = "local.cpdb"

    /// `~/Library/Application Support/local.cpdb/`
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(bundleId, isDirectory: true)
    }

    /// `~/Library/Application Support/local.cpdb/cpdb.db`
    public static var databaseURL: URL {
        supportDirectory.appendingPathComponent("cpdb.db", isDirectory: false)
    }

    /// `~/Library/Application Support/local.cpdb/blobs/`
    public static var blobsDirectory: URL {
        supportDirectory.appendingPathComponent("blobs", isDirectory: true)
    }

    /// `~/Library/Logs/cpdb/`
    public static var logsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/cpdb", isDirectory: true)
    }

    /// `~/Library/LaunchAgents/local.cpdb.daemon.plist`
    public static var launchAgentPlistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(bundleId).daemon.plist", isDirectory: false)
    }

    /// Canonical location of Paste's Core Data store for import.
    public static var defaultPasteDatabaseURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/com.wiheads.paste", isDirectory: true)
            .appendingPathComponent("Paste.db", isDirectory: false)
    }

    /// Content-addressed path under `blobsDirectory` for a given sha256 hex string.
    /// Two-level fan-out: `blobs/ab/cd/<full hex>`.
    public static func blobPath(forSHA256Hex hex: String) -> URL {
        precondition(hex.count >= 4, "sha256 hex too short")
        let a = String(hex.prefix(2))
        let b = String(hex.dropFirst(2).prefix(2))
        return blobsDirectory
            .appendingPathComponent(a, isDirectory: true)
            .appendingPathComponent(b, isDirectory: true)
            .appendingPathComponent(hex, isDirectory: false)
    }

    /// Ensures `supportDirectory`, `blobsDirectory`, and `logsDirectory` exist.
    public static func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        for dir in [supportDirectory, blobsDirectory, logsDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }
}
