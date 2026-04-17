import Foundation
import CpdbCore

/// Manages the in-process `PasteboardWatcher` lifetime for the menu-bar app.
///
/// - `start()` takes the `DaemonLock` as owner `.app` and kicks off the
///   watcher. If the lock is already held (by the CLI daemon), the app
///   records that fact and runs in **read-only UI mode**: popup + search
///   still work, but no new captures.
/// - `stop()` releases the watcher and the lock.
@MainActor
final class DaemonLifecycle {
    enum Mode: Equatable {
        case capturing
        case readOnly(holderPid: Int32, holderOwner: String)
        case notStarted
    }

    private(set) var mode: Mode = .notStarted
    private var lock: DaemonLock?
    private var watcher: PasteboardWatcher?
    private var store: Store?

    /// Open the store and attempt to acquire the daemon lock. On success,
    /// start the in-process watcher. On `heldBy` failure, fall back to
    /// read-only mode.
    func start() throws -> Store {
        let store = try Store.open()
        self.store = store

        let deviceId = try DeviceIdentity.ensureLocalDevice(in: store)

        let lock = DaemonLock(owner: .app)
        do {
            try lock.acquire()
            self.lock = lock
            let ingestor = Ingestor(store: store)
            let watcher = PasteboardWatcher(ingestor: ingestor, deviceId: deviceId)
            watcher.start()
            self.watcher = watcher
            self.mode = .capturing
            Log.daemon.info("cpdb.app captured daemon lock; watcher started")
        } catch let error as DaemonLock.LockError {
            switch error {
            case .heldBy(let pid, let owner, _):
                self.mode = .readOnly(holderPid: pid, holderOwner: owner)
                Log.daemon.warning("daemon lock held by \(owner, privacy: .public) pid \(pid, privacy: .public); running in read-only UI mode")
            case .cannotOpen:
                throw error
            }
        }

        return store
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        lock?.release()
        lock = nil
        mode = .notStarted
    }
}
