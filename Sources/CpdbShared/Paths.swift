import Foundation

/// Filesystem locations used by cpdb.
///
/// `bundleId` is the reverse-DNS used throughout the app — Application
/// Support directory name, LaunchAgent label, log subsystem, UserDefaults
/// keys, DaemonLock path, etc. Keep it consistent with the app bundle's
/// `CFBundleIdentifier` in `Sources/CpdbApp/Resources/Info.plist` and with
/// the CloudKit container name (`iCloud.<bundleId>`).
public enum Paths {
    public static let bundleId = "net.phfactor.cpdb"

    /// The `local.cpdb` name used pre-v2.0. `Store.open()` migrates from
    /// this path on first launch so the user's existing DB isn't stranded
    /// when we rename.
    public static let legacyBundleId = "local.cpdb"

    /// Platform-specific support directory.
    ///
    /// On macOS: `~/Library/Application Support/net.phfactor.cpdb/`
    /// (shared across apps, which is why we subdirectory by bundle id).
    ///
    /// On iOS: the app's own Application Support directory (already
    /// sandboxed per-app, no bundle-id subdirectory needed).
    ///
    /// **Override via `CPDB_SUPPORT_DIR` environment variable** — used
    /// by the `cpdb fixture` test scaffolding to redirect the binary
    /// at a snapshot copy of the live data without touching the real
    /// directory. The override applies to ALL derived paths
    /// (databaseURL, blobsDirectory, etc.) since they branch off this
    /// one. iOS doesn't honour the env var (no shell from the iOS app
    /// to set one anyway).
    public static var supportDirectory: URL {
        #if os(macOS)
        if let override = ProcessInfo.processInfo.environment["CPDB_SUPPORT_DIR"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(bundleId, isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
        #endif
    }

    /// Where v1.x stored its data. Used only by the one-time migrator
    /// on macOS — iOS has never had a v1.x to migrate from.
    public static var legacySupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #if os(macOS)
        return base.appendingPathComponent(legacyBundleId, isDirectory: true)
        #else
        return base.appendingPathComponent(legacyBundleId, isDirectory: true)
        #endif
    }

    /// `~/Library/Application Support/net.phfactor.cpdb/cpdb.db`
    public static var databaseURL: URL {
        supportDirectory.appendingPathComponent("cpdb.db", isDirectory: false)
    }

    /// `~/Library/Application Support/net.phfactor.cpdb/blobs/`
    public static var blobsDirectory: URL {
        supportDirectory.appendingPathComponent("blobs", isDirectory: true)
    }

    #if os(macOS)
    /// `~/Library/Logs/cpdb/` — macOS LaunchAgent stdout/stderr sink.
    /// iOS apps log only through `os_log`; no equivalent filesystem
    /// location and no need for one.
    public static var logsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/cpdb", isDirectory: true)
    }

    /// `~/Library/LaunchAgents/net.phfactor.cpdb.daemon.plist`.
    /// LaunchAgents don't exist on iOS.
    public static var launchAgentPlistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(bundleId).daemon.plist", isDirectory: false)
    }

    /// Canonical location of Paste's Core Data store for import.
    /// Paste is macOS-only and so is this importer path.
    public static var defaultPasteDatabaseURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/com.wiheads.paste", isDirectory: true)
            .appendingPathComponent("Paste.db", isDirectory: false)
    }
    #endif

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

    /// Ensures the data directories exist. `logsDirectory` is macOS-only.
    public static func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        #if os(macOS)
        let dirs = [supportDirectory, blobsDirectory, logsDirectory]
        #else
        let dirs = [supportDirectory, blobsDirectory]
        #endif
        for dir in dirs {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    /// One-time migration from `~/Library/Application Support/local.cpdb/`
    /// to the new bundle-id-based path. Called before `Store.open()` opens
    /// the database so we don't accidentally create an empty DB at the new
    /// path while the old one still has the user's history.
    ///
    /// Idempotent:
    ///   - New path already present, old one gone → no-op (we're past the move).
    ///   - Old path present, new one absent → move (the expected case for first
    ///     launch of v2.0 on an existing install).
    ///   - Both present → log and leave alone. User resolves manually.
    @discardableResult
    public static func migrateFromLegacySupportDirectoryIfNeeded() -> Bool {
        let fm = FileManager.default
        let oldURL = legacySupportDirectory
        let newURL = supportDirectory
        guard fm.fileExists(atPath: oldURL.path) else { return false }
        if fm.fileExists(atPath: newURL.path) {
            Log.store.warning(
                "both \(oldURL.path, privacy: .public) and \(newURL.path, privacy: .public) exist — skipping migration; resolve manually"
            )
            return false
        }
        do {
            try fm.moveItem(at: oldURL, to: newURL)
            Log.store.info(
                "migrated Application Support from \(oldURL.lastPathComponent, privacy: .public) to \(newURL.lastPathComponent, privacy: .public)"
            )
            return true
        } catch {
            Log.store.error("migration failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
