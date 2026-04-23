import AppKit
import CloudKit
import CpdbCore
import CpdbShared
import KeyboardShortcuts

/// Central coordinator for the menu-bar app. Owns the status item, the
/// popup, the in-process capture watcher, and their lifetimes.
///
/// Kept intentionally small — each responsibility lives in its own type and
/// is strung together here.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private let lifecycle = DaemonLifecycle()
    private(set) var store: Store?
    private var syncer: CloudKitSyncer?
    private var periodicSyncTask: Task<Void, Never>?
    /// NotificationCenter token for `.cpdbLocalEntryIngested`. We
    /// subscribe once the syncer is ready; handler triggers an
    /// immediate push so a new capture lands in CloudKit within
    /// seconds instead of waiting for the 5-minute timer.
    private var ingestedObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.cli.info("cpdb.app starting (pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public))")

        // Subscribe to frontmost-app activations BEFORE we start the
        // PasteboardWatcher, so the 5 s sliding window is already
        // populated when the first clipboard event fires.
        FrontmostAppMonitor.warmUp()

        var captureMode: PopupState.CaptureMode = .capturing
        do {
            self.store = try lifecycle.start()
            switch lifecycle.mode {
            case .capturing:
                Log.cli.info("capture mode: writer")
                captureMode = .capturing
            case .readOnly(let pid, let owner):
                Log.cli.warning("capture mode: read-only (held by \(owner, privacy: .public) pid \(pid, privacy: .public))")
                captureMode = .readOnly(holder: "\(owner) pid \(pid)")
            case .notStarted:
                Log.cli.error("daemon lifecycle did not start")
            }
        } catch {
            Log.cli.error("daemon lifecycle failed to start: \(String(describing: error), privacy: .public)")
        }

        if let store = store {
            PopupController.shared.configure(store: store, captureMode: captureMode)
            AboutWindowController.shared.configure(store: store)
            PreferencesWindowController.shared.configure(store: store)
        }

        statusItem = StatusItemController()

        // Register the global hotkey handler. KeyboardShortcuts handles the
        // actual key registration via Carbon / AppKit — we just hand it a
        // closure to run whenever the user's chosen combo fires.
        KeyboardShortcuts.onKeyDown(for: .summonPopup) { [weak self] in
            self?.handleSummonPopup()
        }

        // Reflect initial "no hotkey set" state on the status item.
        refreshFirstRunBadge()
        // Re-check whenever the user changes the binding in Preferences.
        NotificationCenter.default.addObserver(
            forName: .init("KeyboardShortcuts_shortcutByNameDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFirstRunBadge() }
        }
        // If a paste attempt discovers missing Accessibility permission,
        // steer the user to Preferences immediately.
        NotificationCenter.default.addObserver(
            forName: .cpdbNeedsAccessibility,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in PreferencesWindowController.shared.show() }
        }

        // First-launch nudge: no hotkey set at all means they've never
        // opened Preferences. Surface the window once on first launch so
        // they know where to go.
        if KeyboardShortcuts.getShortcut(for: .summonPopup) == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                PreferencesWindowController.shared.show()
            }
        }

        // Kick off CloudKit sync. Only runs if the user has an iCloud
        // account; no-op in capturing-mode daemons that happen not to be
        // signed in. Pull path (step 5) isn't wired yet — this just
        // drains the push queue on launch and every 5 minutes.
        if let store = store, lifecycle.mode == .capturing {
            startCloudKitSync(store: store)
        }

        // "Sync Now" menu item → pull-then-push.
        NotificationCenter.default.addObserver(
            forName: .cpdbSyncNow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let syncer = self?.syncer else {
                    Log.cli.info("sync now: syncer not running (no iCloud account or read-only mode)")
                    return
                }
                do {
                    let pull = try await syncer.pullRemoteChanges()
                    Log.cli.info(
                        "sync now pull: inserted=\(pull.inserted) updated=\(pull.updated) tombstoned=\(pull.tombstoned) skipped=\(pull.skipped)"
                    )
                    let push = try await syncer.pushPendingChanges()
                    Log.cli.info(
                        "sync now push: attempted=\(push.attempted) saved=\(push.saved) failed=\(push.failed) remaining=\(push.remaining)"
                    )
                } catch {
                    Log.cli.error("sync now failed: \(String(describing: error), privacy: .public)")
                }
            }
        }

        // "Pull from iCloud" → pull path only.
        NotificationCenter.default.addObserver(
            forName: .cpdbPullNow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let syncer = self?.syncer else { return }
                do {
                    let pull = try await syncer.pullRemoteChanges()
                    Log.cli.info(
                        "pull now: inserted=\(pull.inserted) updated=\(pull.updated) tombstoned=\(pull.tombstoned) skipped=\(pull.skipped)"
                    )
                } catch {
                    Log.cli.error("pull now failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func startCloudKitSync(store: Store) {
        let containerID = "iCloud.\(Paths.bundleId)"
        let client = LiveCloudKitClient(containerIdentifier: containerID)
        let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let deviceID = DeviceIdentity.hardwareUUID() ?? ProcessInfo.processInfo.hostName
        // `onPasteAction`: the iOS companion writes an ActionRequest
        // CKRecord targeting this Mac; the syncer consumes it during
        // the next pull and invokes this closure with the local
        // Entry. Writing to NSPasteboard lives in Restorer so this
        // closure is a thin adapter. Note the escape hatch: Restorer
        // is macOS-only so we can't move it into CpdbShared, which is
        // why the syncer accepts a closure rather than calling
        // Restorer directly.
        let pasteHandler: @Sendable (Entry) async -> Void = { entry in
            guard let id = entry.id else { return }
            let restorer = Restorer(store: store)
            do {
                try restorer.restoreToPasteboard(entryId: id)
                Log.cli.info(
                    "remote paste: wrote entry \(id, privacy: .public) to NSPasteboard"
                )
            } catch {
                Log.cli.error(
                    "remote paste failed for entry \(id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        let syncer = CloudKitSyncer(
            store: store,
            client: client,
            device: .init(identifier: deviceID, name: deviceName),
            onPasteAction: pasteHandler
        )
        self.syncer = syncer

        // Wake the push loop immediately on every local capture.
        // Ingestor posts `.cpdbLocalEntryIngested` inside its write
        // transaction; we run `pushPendingChanges` right after so the
        // entry reaches CloudKit in seconds, not up to 5 minutes
        // (the periodic safety-net loop below). The syncer's
        // internal `pushing` guard coalesces simultaneous wakes, so
        // a burst of rapid captures only triggers one network trip.
        ingestedObserver = NotificationCenter.default.addObserver(
            forName: .cpdbLocalEntryIngested,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                do {
                    let push = try await syncer.pushPendingChanges()
                    if push.attempted > 0 {
                        Log.cli.info(
                            "cloudkit push (wake): attempted=\(push.attempted) saved=\(push.saved) failed=\(push.failed) remaining=\(push.remaining)"
                        )
                    }
                } catch {
                    Log.cli.error("cloudkit push (wake) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }

        // Register for silent push + install the zone subscription so
        // the server wakes us when another device writes. APNs is
        // granted by our `com.apple.developer.aps-environment`
        // entitlement; no user prompt.
        NSApp.registerForRemoteNotifications()
        Task.detached {
            do {
                try await syncer.ensureSubscription()
                Log.cli.info("cloudkit zone subscription installed")
            } catch {
                Log.cli.error("cloudkit subscription failed: \(String(describing: error), privacy: .public)")
            }
        }

        // Periodic loop: pull first (other devices' changes), then push
        // (our local changes). Aggressive while there's push work to
        // drain, otherwise idles for 5 minutes. APNs-delivered silent
        // pushes (handled below) trigger a pull outside this loop, so
        // this timer is just a safety net against missed notifications.
        periodicSyncTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                var shouldPause = true
                do {
                    let pull = try await syncer.pullRemoteChanges()
                    if pull.inserted + pull.updated + pull.tombstoned > 0 {
                        Log.cli.info(
                            "cloudkit pull: inserted=\(pull.inserted) updated=\(pull.updated) tombstoned=\(pull.tombstoned) skipped=\(pull.skipped)"
                        )
                    }
                } catch {
                    Log.cli.error("cloudkit pull failed: \(String(describing: error), privacy: .public)")
                }
                do {
                    let push = try await syncer.pushPendingChanges()
                    if push.attempted > 0 {
                        Log.cli.info(
                            "cloudkit push: attempted=\(push.attempted) saved=\(push.saved) failed=\(push.failed) remaining=\(push.remaining)"
                        )
                    }
                    if push.failed == 0 && push.remaining > 0 {
                        shouldPause = false
                    }
                } catch {
                    Log.cli.error("cloudkit push failed: \(String(describing: error), privacy: .public)")
                }
                if shouldPause {
                    try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                }
                _ = self
            }
        }
    }

    // MARK: - APNs silent push handling

    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        // Any silent push that mentions our container → the zone changed.
        // We don't bother parsing the CKNotification payload; just run a
        // pull (and immediately follow with a push so late outbound work
        // doesn't wait the 5-minute idle timer).
        guard let syncer = syncer else { return }
        Task {
            do {
                let pull = try await syncer.pullRemoteChanges()
                Log.cli.info(
                    "apns pull: inserted=\(pull.inserted) updated=\(pull.updated) tombstoned=\(pull.tombstoned) skipped=\(pull.skipped)"
                )
                _ = try await syncer.pushPendingChanges()
            } catch {
                Log.cli.error("apns pull failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Log.cli.info("registered for remote notifications (\(deviceToken.count, privacy: .public) byte token)")
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        Log.cli.error("remote-notification registration failed: \(String(describing: error), privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.cli.info("cpdb.app terminating")
        periodicSyncTask?.cancel()
        lifecycle.stop()
    }

    // MARK: - Actions

    private func handleSummonPopup() {
        PopupController.shared.toggle()
    }

    /// Show an orange dot on the status item if the user hasn't picked a
    /// hotkey yet. Clicking the status item still works — the "Show cpdb"
    /// menu item remains wired. The dot is just a nudge toward Preferences.
    private func refreshFirstRunBadge() {
        let hasHotkey = KeyboardShortcuts.getShortcut(for: .summonPopup) != nil
        statusItem?.setNeedsAttention(!hasHotkey)
    }
}
