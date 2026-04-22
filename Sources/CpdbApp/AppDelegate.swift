import AppKit
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.cli.info("cpdb.app terminating")
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
