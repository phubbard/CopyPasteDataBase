import Foundation
import CpdbCore
import CpdbShared

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
    /// Polls `NSPasteboard.general.accessBehavior` (macOS 15.4+ preview;
    /// see `PasteboardAccessMonitor`'s doc comment) and pauses/resumes
    /// `watcher` when the OS reports the app has been denied pasteboard
    /// access. Only created in `.capturing` mode — read-only mode never
    /// owns a watcher to pause in the first place.
    private var privacyMonitor: PasteboardAccessMonitor?
    /// Tracks whether `watcher` is currently paused for a `.denied`
    /// privacy status, so `applyPrivacyStatus` only calls `stop()`/
    /// `start()` on an actual edge rather than on every poll tick
    /// (`PasteboardWatcher.start()` isn't idempotent — a second call
    /// without an intervening `stop()` would leak a second timer).
    private var isPrivacyPaused = false
    /// Fired whenever the pasteboard-access status changes, whether or
    /// not it caused a pause — the Preferences/popup banner reacts to
    /// every observed status, not just the pause edge. `AppDelegate`
    /// wires this to update `PopupState.captureMode`.
    var onPrivacyStatusChange: ((PasteboardAccessStatus) -> Void)?
    /// Latest observed status. Set synchronously inside `start()` (in
    /// `.capturing` mode) before that call returns, so `AppDelegate` can
    /// read it once to seed the popup's *initial* banner — assigning
    /// `onPrivacyStatusChange` only catches changes from that point on,
    /// which would miss "already denied at launch". Stays nil in
    /// read-only/not-started mode (no monitor is created there).
    private(set) var privacyStatus: PasteboardAccessStatus?

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

            let monitor = PasteboardAccessMonitor()
            monitor.onStatusChange = { [weak self] status in
                self?.applyPrivacyStatus(status)
            }
            self.privacyMonitor = monitor
            monitor.start()
            applyPrivacyStatus(monitor.status)
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
        privacyMonitor?.stop()
        privacyMonitor = nil
        watcher?.stop()
        watcher = nil
        lock?.release()
        lock = nil
        mode = .notStarted
    }

    /// Pause/resume `watcher` on the `.denied` ↔ not-`.denied` edge, and
    /// always forward the raw status to `onPrivacyStatusChange` for the
    /// UI. Guarded by `isPrivacyPaused` so repeated polls at the same
    /// status are no-ops on the watcher itself.
    private func applyPrivacyStatus(_ status: PasteboardAccessStatus) {
        privacyStatus = status
        let shouldPause = PasteboardAccessClassifier.shouldPauseCapture(for: status)
        if shouldPause != isPrivacyPaused {
            isPrivacyPaused = shouldPause
            if shouldPause {
                watcher?.stop()
                Log.daemon.warning("pasteboard access denied — capture paused")
            } else if mode == .capturing {
                watcher?.start()
                Log.daemon.info("pasteboard access restored — capture resumed")
            }
        }
        onPrivacyStatusChange?(status)
    }
}
