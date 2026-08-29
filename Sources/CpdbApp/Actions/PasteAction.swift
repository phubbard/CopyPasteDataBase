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

    /// `pasteboard` defaults to `.general` for real use; tests pass a
    /// scratch pasteboard so they can assert on written content without
    /// touching the developer's actual clipboard.
    func paste(entryId: Int64, pasteboard: NSPasteboard = .general) {
        let writer = PasteboardWriter(store: store)
        do {
            try writer.write(entryId: entryId, to: pasteboard)
        } catch {
            Log.paste.error("paste: PasteAction writer failed entry=\(entryId, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }

        // Re-activate the previous app. Without this, the frontmost app at
        // the moment of the keystroke is still `cpdb` (or whichever app we
        // handed focus to during the popup), and ⌘V would be routed there.
        if let previousApp, !previousApp.activate() {
            Log.paste.error("paste: activate(previousApp:) failed entry=\(entryId, privacy: .public) app=\(previousApp.bundleIdentifier ?? "nil", privacy: .public)")
        }

        guard Accessibility.isTrusted() else {
            Log.paste.warning("paste: Accessibility not granted, skipping \u{2318}V synthesis entry=\(entryId, privacy: .public)")
            NotificationCenter.default.post(name: .cpdbNeedsAccessibility, object: nil)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reactivationDelay) {
            Self.synthesizeCmdV(entryId: entryId)
        }
    }

    /// Post a Cmd+V keystroke to the frontmost application. Uses the
    /// combined session event source so Dead Keys, key repeat, etc. don't
    /// leak into our synthesised events.
    private static func synthesizeCmdV(entryId: Int64) {
        let src = CGEventSource(stateID: .combinedSessionState)
        // kVK_ANSI_V = 0x09
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        guard let keyDown, let keyUp else {
            // CGEventSource/CGEvent init returns nil when the event
            // source can't be created (e.g. no window server session,
            // the state this always hit under `swift test`) — silently
            // no-op'd before, leaving the pasteboard written but no
            // keystroke ever posted with no trace of why.
            Log.paste.error("paste: synthesizeCmdV failed to construct CGEvent entry=\(entryId, privacy: .public)")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}

extension Notification.Name {
    /// Fired when `PasteAction` tried to synthesise a keystroke but TCC
    /// Accessibility was denied. The AppDelegate watches for this and
    /// surfaces the onboarding sheet in Preferences.
    static let cpdbNeedsAccessibility = Notification.Name("cpdbNeedsAccessibility")
}
