import Testing
import Foundation
@testable import CpdbCore

@Suite("Daemon lock")
struct DaemonLockTests {
    /// Writes the lock to a unique temp path so parallel tests don't collide.
    private func tempLockPath() -> String {
        let dir = NSTemporaryDirectory()
        return dir + "cpdb-lock-\(UUID().uuidString).lock"
    }

    @Test("acquire writes pid + owner metadata")
    func acquireWritesMetadata() throws {
        let path = tempLockPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let lock = DaemonLock(path: path, owner: .cli)
        try lock.acquire()
        defer { lock.release() }

        let raw = try String(contentsOfFile: path, encoding: .utf8)
        #expect(raw.contains("pid=\(getpid())"))
        #expect(raw.contains("owner=cli"))
        #expect(raw.contains("since="))
    }

    @Test("second acquire in same process fails while first is held")
    func secondAcquireFailsWhileHeld() throws {
        let path = tempLockPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = DaemonLock(path: path, owner: .app)
        try first.acquire()
        defer { first.release() }

        // Another DaemonLock over the same path must fail.
        let second = DaemonLock(path: path, owner: .cli)
        #expect(throws: DaemonLock.LockError.self) {
            try second.acquire()
        }
    }

    @Test("release allows re-acquire")
    func releaseAllowsReAcquire() throws {
        let path = tempLockPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let lock1 = DaemonLock(path: path, owner: .cli)
        try lock1.acquire()
        lock1.release()

        let lock2 = DaemonLock(path: path, owner: .app)
        try lock2.acquire()
        defer { lock2.release() }

        let raw = try String(contentsOfFile: path, encoding: .utf8)
        #expect(raw.contains("owner=app"))
    }

    @Test("currentHolder returns metadata while lock is held")
    func currentHolderReturnsMetadata() throws {
        let path = tempLockPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let lock = DaemonLock(path: path, owner: .app)
        try lock.acquire()
        defer { lock.release() }

        let holder = DaemonLock.currentHolder(at: path)
        #expect(holder != nil)
        #expect(holder?.owner == "app")
        #expect(holder?.pid == getpid())
    }

    @Test("currentHolder returns nil when no lock file exists")
    func currentHolderNilWhenMissing() {
        let path = tempLockPath()
        #expect(DaemonLock.currentHolder(at: path) == nil)
    }

    @Test("metadata parser handles expected shape")
    func metadataParser() {
        let raw = "pid=1234\nowner=cli\nsince=2026-04-14T12:00:00Z\n"
        let meta = DaemonLock.parseMetadata(raw)
        #expect(meta.pid == 1234)
        #expect(meta.owner == "cli")
        #expect(meta.since == "2026-04-14T12:00:00Z")
    }
}
