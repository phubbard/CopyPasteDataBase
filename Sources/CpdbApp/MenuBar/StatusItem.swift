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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Give the status item a stable `autosaveName` so macOS tracks
        // its visibility and position across launches. Without this,
        // macOS Sonoma+ is free to park newly-created status items in
        // Control Center overflow on first run and never surface them.
        item.autosaveName = "net.phfactor.cpdb.statusItem"
        item.behavior = .removalAllowed
        if let button = item.button {
            button.image = Self.normalImage
        }
        item.menu = Self.buildMenu()
        self.statusItem = item
        Log.cli.info("status item installed")
    }

    /// Toggle a "needs attention" (first-run, no hotkey bound) appearance.
    /// Swaps the SF Symbol for a filled variant with a badge-like colour so
    /// the user has a hint something's waiting.
    func setNeedsAttention(_ needs: Bool) {
        guard let button = statusItem.button else { return }
        if needs {
            button.image = Self.attentionImage
            button.toolTip = "cpdb — pick a hotkey in Preferences"
        } else {
            button.image = Self.normalImage
            button.toolTip = "cpdb"
        }
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
}

extension Notification.Name {
    /// Posted by the "Sync Now" menu item; AppDelegate handles it by
    /// running a pull-then-push pass.
    static let cpdbSyncNow = Notification.Name("cpdbSyncNow")
    /// Posted by "Pull from iCloud"; runs the pull path only.
    static let cpdbPullNow = Notification.Name("cpdbPullNow")
}
