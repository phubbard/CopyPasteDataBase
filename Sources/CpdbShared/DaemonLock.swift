import Foundation
import Darwin

// Darwin imports both `struct flock` and the `flock(2)` function, and Swift
// resolves the struct first when we write `flock`. Bind the C symbol
// explicitly to side-step the collision.
@_silgen_name("flock")
private func c_flock(_ fd: Int32, _ operation: Int32) -> Int32

/// Exclusive lock file that coordinates who gets to be the clipboard capture
/// writer. Both `cpdb daemon` (CLI) and `cpdb.app` (menu-bar app) take this
/// lock before starting a `PasteboardWatcher`. Exactly one writer at a time.
///
/// Implementation: a `flock(LOCK_EX | LOCK_NB)` advisory exclusive lock on
/// a file in the support directory. `flock(2)` is per-file-description
/// rather than per-process, so two different `open()`s in the same process
/// correctly conflict — which matters for the app calling acquire() twice
/// by accident. We write a small metadata blob inside the file so
/// `cpdb stats` / error messages can tell the user which process currently
/// owns capture.
///
/// The lock is advisory. Nothing stops a misbehaving process from ignoring
/// it, but our CLI and app both honour it, which is what we care about.
public final class DaemonLock {
    public enum Owner: String, Sendable {
        case cli
        case app
    }

    public enum LockError: Error, CustomStringConvertible {
        case heldBy(pid: Int32, owner: String, since: String)
        case cannotOpen(path: String, errno: Int32)

        public var description: String {
            switch self {
            case .heldBy(let pid, let owner, let since):
                return "daemon lock held by \(owner) pid \(pid) since \(since)"
            case .cannotOpen(let path, let errno):
                return "cannot open lock file \(path): errno \(errno)"
            }
        }
    }

    private let path: String
    private var fd: Int32 = -1
    public let owner: Owner

    /// Path to the lock file. Default: `~/Library/Application Support/<bundleId>/daemon.lock`.
    public static var defaultPath: String {
        Paths.supportDirectory.appendingPathComponent("daemon.lock").path
    }

    public init(path: String = DaemonLock.defaultPath, owner: Owner) {
        self.path = path
        self.owner = owner
    }

    /// Acquire the lock. Throws `LockError.heldBy` if another live process
    /// already holds it. Writes our metadata into the file on success.
    public func acquire() throws {
        try Paths.ensureDirectoriesExist()

        // Open (or create) the lock file.
        let opened = open(path, O_RDWR | O_CREAT, 0o644)
        guard opened >= 0 else {
            throw LockError.cannotOpen(path: path, errno: errno)
        }

        // Exclusive, non-blocking advisory lock on this specific file
        // description (not process-wide).
        if c_flock(opened, LOCK_EX | LOCK_NB) != 0 {
            let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            close(opened)
            let parsed = Self.parseMetadata(existing)
            throw LockError.heldBy(
                pid: parsed.pid,
                owner: parsed.owner,
                since: parsed.since
            )
        }

        self.fd = opened

        // Write our metadata. Truncate first because the old content may be
        // longer than ours.
        ftruncate(opened, 0)
        lseek(opened, 0, SEEK_SET)
        let iso = ISO8601DateFormatter().string(from: Date())
        let metadata = "pid=\(getpid())\nowner=\(owner.rawValue)\nsince=\(iso)\n"
        metadata.withCString { cstr in
            _ = write(opened, cstr, strlen(cstr))
        }
    }

    /// Release the lock and remove the file.
    public func release() {
        guard fd >= 0 else { return }
        _ = c_flock(fd, LOCK_UN)
        close(fd)
        fd = -1
        try? FileManager.default.removeItem(atPath: path)
    }

    deinit {
        if fd >= 0 {
            close(fd)
        }
    }

    // MARK: - Metadata parsing

    public struct Metadata: Equatable, Sendable {
        public var pid: Int32 = 0
        public var owner: String = "unknown"
        public var since: String = "unknown"
        public init(pid: Int32 = 0, owner: String = "unknown", since: String = "unknown") {
            self.pid = pid
            self.owner = owner
            self.since = since
        }
    }

    static func parseMetadata(_ raw: String) -> Metadata {
        var meta = Metadata()
        for line in raw.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "pid":   meta.pid = Int32(value) ?? 0
            case "owner": meta.owner = value
            case "since": meta.since = value
            default:      break
            }
        }
        return meta
    }

    /// Read the current holder's metadata (if any) without acquiring the
    /// lock. Useful for status displays. Returns `nil` if no lock file
    /// exists. If the file exists but nobody's holding it, returns the
    /// stale metadata anyway — callers that care should try `acquire()`
    /// (which will succeed on a stale file) and then decide.
    public static func currentHolder(at path: String = DaemonLock.defaultPath) -> Metadata? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // Probe the lock: open the file in a second fd and try a
        // non-blocking shared lock. If it succeeds, nobody exclusive-locked
        // it — metadata is stale.
        let probeFd = open(path, O_RDONLY)
        guard probeFd >= 0 else { return nil }
        defer { close(probeFd) }
        let probed = c_flock(probeFd, LOCK_SH | LOCK_NB)
        if probed == 0 {
            // We got a shared lock → nobody's writing. Release and report stale.
            _ = c_flock(probeFd, LOCK_UN)
            return nil
        }
        // Couldn't get a shared lock → someone has LOCK_EX. Read the metadata.
        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return parseMetadata(raw)
    }
}
