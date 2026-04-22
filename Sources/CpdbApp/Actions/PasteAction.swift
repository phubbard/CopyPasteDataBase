import AppKit
import Foundation
import CpdbCore
import CpdbShared

/// The "pick an entry → paste into the previously focused app" flow.
///
/// Called from `PopupController.pasteSelected()`. Three steps:
///
/// 1. Write the entry's full `NSPasteboardItem` to `NSPasteboard.general`.
/// 2. Re-activate the app that was frontmost when the popup was summoned.
/// 3. Synthesise `⌘V` via `CGEvent` so the paste lands in the right place.
///
/// Step 3 requires Accessibility permission. If we don't have it, we still
/// perform steps 1–2 so the user can press ⌘V themselves. An onboarding
/// sheet (step 12) teaches them to grant the permission.
@MainActor
struct PasteAction {
    let store: Store
    let previousApp: NSRunningApplication?

    /// Delay between re-activating the previous app and posting the
    /// keystroke. macOS needs a moment to actually switch the key window
    /// before `CGEvent.post(tap:)` is routed to it.
    static let reactivationDelay: TimeInterval = 0.04

    func paste(entryId: Int64) {
        let writer = PasteboardWriter(store: store)
        do {
            try writer.write(entryId: entryId, to: .general)
        } catch {
            Log.cli.error("PasteAction writer failed: \(String(describing: error), privacy: .public)")
            return
        }

        // Re-activate the previous app. Without this, the frontmost app at
        // the moment of the keystroke is still `cpdb` (or whichever app we
        // handed focus to during the popup), and ⌘V would be routed there.
        previousApp?.activate()

        guard Accessibility.isTrusted() else {
            Log.cli.warning("Accessibility not granted; skipping ⌘V synthesis")
            NotificationCenter.default.post(name: .cpdbNeedsAccessibility, object: nil)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reactivationDelay) {
            Self.synthesizeCmdV()
        }
    }

    /// Post a Cmd+V keystroke to the frontmost application. Uses the
    /// combined session event source so Dead Keys, key repeat, etc. don't
    /// leak into our synthesised events.
    private static func synthesizeCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        // kVK_ANSI_V = 0x09
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags   = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

extension Notification.Name {
    /// Fired when `PasteAction` tried to synthesise a keystroke but TCC
    /// Accessibility was denied. The AppDelegate watches for this and
    /// surfaces the onboarding sheet in Preferences.
    static let cpdbNeedsAccessibility = Notification.Name("cpdbNeedsAccessibility")
}
