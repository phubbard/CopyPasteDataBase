import AppKit
import CpdbCore
import CpdbShared

/// Owns the `NSStatusBarItem` and its dropdown menu.
///
/// Step 1 of the UI — gets a visible foothold in the menu bar before the
/// popup, hotkey, or anything else lands.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem

    init() {
        // Fixed length so a nil image can't silently collapse us to 0px.
        let item = NSStatusBar.system.statusItem(withLength: 24)

        // NO autosaveName. On macOS Sonoma / Sequoia+, setting one opts
        // the item in to the menu-bar manager's auto-hiding policy:
        // first launch, macOS notes the autosave name and may decide
        // the item is a candidate for Control Center overflow, then
        // hides it after rendering a single frame (matches user report
        // "flashes into place then disappears"). Without autosave,
        // macOS treats the item as transient and keeps it pinned
        // wherever it drops it in the menu bar.

        // Explicitly ensure visible, in case a prior deploy had
        // autosaveName set and wrote a "hidden" preference we can't
        // easily delete per-user.
        item.isVisible = true

        if let button = item.button {
            button.image = Self.normalImage
            if button.image == nil {
                button.title = "cpdb"
                Log.cli.warning("status item: falling back to text — SF Symbol unavailable?")
            }
        }
        item.menu = Self.buildMenu()
        self.statusItem = item
        let hasImage = item.button?.image != nil ? "yes" : "no"
        Log.cli.info(
            "status item installed (image=\(hasImage, privacy: .public), length=\(item.length, privacy: .public), visible=\(item.isVisible, privacy: .public))"
        )
    }

    /// Toggle a "needs attention" (first-run, no hotkey bound) appearance.
    /// Swaps the SF Symbol for a filled variant with a badge-like colour so
    /// the user has a hint something's waiting.
    func setNeedsAttention(_ needs: Bool) {
        guard let button = statusItem.button else { return }
        // Preserve the text fallback if the symbol couldn't load.
        // Never clear both image and title together — that's what
        // silently makes the item disappear from the menu bar.
        let desired = needs ? Self.attentionImage : Self.normalImage
        if let img = desired {
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = "cpdb"
        }
        button.toolTip = needs ? "cpdb — pick a hotkey in Preferences" : "cpdb"
    }

    // SF Symbols: `list.clipboard` is the closest native clipboard glyph.
    // Template tinting makes them follow the menu bar's light/dark state.
    private static let normalImage: NSImage? = {
        let image = NSImage(
            systemSymbolName: "list.clipboard",
            accessibilityDescription: "cpdb"
        )
        image?.isTemplate = true
        return image
    }()

    // `exclamationmark.circle.fill` overlay is too loud for a menu bar;
    // `list.clipboard.fill` with the non-template tint gives a softer "look
    // at me" signal that still reads on both light and dark menu bars.
    private static let attentionImage: NSImage? = {
        let image = NSImage(
            systemSymbolName: "list.clipboard.fill",
            accessibilityDescription: "cpdb — needs attention"
        )
        image?.isTemplate = false
        return image
    }()

    private static func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "cpdb")

        let showItem = NSMenuItem(
            title: "Show cpdb",
            action: #selector(StatusItemActions.showPopup),
            keyEquivalent: ""
        )
        showItem.target = StatusItemActions.shared
        menu.addItem(showItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "About cpdb",
            action: #selector(StatusItemActions.showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = StatusItemActions.shared
        menu.addItem(aboutItem)

        let prefsItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(StatusItemActions.showPreferences),
            keyEquivalent: ","
        )
        prefsItem.target = StatusItemActions.shared
        menu.addItem(prefsItem)

        // Manual sync triggers — post notifications that AppDelegate
        // handles by running the corresponding syncer path. Handy for
        // iteration on a single Mac (Sync Now pushes outbound changes)
        // and for verifying cross-device sync without waiting on the
        // 5-minute periodic timer (Pull Now fetches from CloudKit).
        // "Sync Now" does both pull then push, matching what the
        // periodic loop does each tick.
        let syncItem = NSMenuItem(
            title: "Sync Now",
            action: #selector(StatusItemActions.syncNow),
            keyEquivalent: "r"
        )
        syncItem.target = StatusItemActions.shared
        menu.addItem(syncItem)

        let pullItem = NSMenuItem(
            title: "Pull from iCloud",
            action: #selector(StatusItemActions.pullNow),
            keyEquivalent: ""
        )
        pullItem.target = StatusItemActions.shared
        menu.addItem(pullItem)

        menu.addItem(.separator())

        // Debug: opens Terminal with the `log stream` command for our
        // subsystem already running. Much faster than typing it out
        // when debugging a stuck Mac remotely or on-device.
        let logsItem = NSMenuItem(
            title: "Stream Logs in Terminal",
            action: #selector(StatusItemActions.streamLogs),
            keyEquivalent: ""
        )
        logsItem.target = StatusItemActions.shared
        menu.addItem(logsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit cpdb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }
}

/// Objective-C friendly action target. NSMenuItem needs a selector target;
/// a struct doesn't qualify, but a singleton NSObject subclass does.
/// `@MainActor` because AppKit dispatches menu actions on the main thread
/// and the controllers we call into are main-actor-isolated.
@MainActor
@objc private final class StatusItemActions: NSObject {
    static let shared = StatusItemActions()

    @objc func showPopup() {
        PopupController.shared.toggle()
    }

    @objc func showPreferences() {
        PreferencesWindowController.shared.show()
    }

    @objc func showAbout() {
        AboutWindowController.shared.show()
    }

    @objc func syncNow() {
        NotificationCenter.default.post(name: .cpdbSyncNow, object: nil)
    }

    @objc func pullNow() {
        NotificationCenter.default.post(name: .cpdbPullNow, object: nil)
    }

    @objc func streamLogs() {
        // Drive Terminal via AppleScript: open a new window and run
        // `log stream` filtered to our subsystem. Terminal is on every
        // Mac, so this works without shipping our own terminal UI.
        // The escaping is messy because we need the AppleScript `do
        // script` literal to contain a double-quoted log predicate —
        // each `\"` here becomes a literal `"` in the AppleScript
        // string, which in turn gets passed to the shell.
        let source = """
        tell application "Terminal"
            activate
            do script "log stream --predicate 'subsystem == \\"net.phfactor.cpdb\\"' --level info"
        end tell
        """
        var errorDict: NSDictionary? = nil
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&errorDict)
            if let err = errorDict {
                Log.cli.error("stream logs: AppleScript error \(String(describing: err), privacy: .public)")
            }
        }
    }
}

extension Notification.Name {
    /// Posted by the "Sync Now" menu item; AppDelegate handles it by
    /// running a pull-then-push pass.
    static let cpdbSyncNow = Notification.Name("cpdbSyncNow")
    /// Posted by "Pull from iCloud"; runs the pull path only.
    static let cpdbPullNow = Notification.Name("cpdbPullNow")
}
