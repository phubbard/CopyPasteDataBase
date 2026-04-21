import AppKit
import CpdbCore
import SwiftUI

/// Owns the `PopupPanel` and its lifecycle: creation, positioning, showing,
/// hiding, and the escape / outside-click monitors.
///
/// Singleton because the status item menu, the hotkey, and `PasteAction` all
/// need to talk to the same panel. Configured exactly once at startup via
/// `configure(store:)`.
///
/// One-window-at-a-time contract with Quick Look: when the user summons QL
/// from the popup, we dismiss the popup so there's a single foreground
/// window (matches Finder). Re-summoning with the hotkey takes priority
/// over any QL that happens to still be open.
@MainActor
final class PopupController {
    static let shared = PopupController()

    private var panel: PopupPanel?
    private var state: PopupState?
    private var escapeMonitor: Any?
    private var outsideClickMonitor: Any?
    private(set) var previousApp: NSRunningApplication?

    private init() {}

    /// Call once, from `AppDelegate.applicationDidFinishLaunching`.
    func configure(store: Store, captureMode: PopupState.CaptureMode) {
        let state = PopupState(store: store)
        state.captureMode = captureMode
        self.state = state

        let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 420))
        let hosting = NSHostingController(rootView: PopupRootView(state: state, onPaste: { [weak self] in
            self?.pasteSelected()
        }))
        hosting.view.frame = panel.contentLayoutRect
        panel.contentViewController = hosting
        self.panel = panel
    }

    func show() {
        guard let panel = panel, let state = state else {
            Log.cli.error("PopupController.show called before configure")
            return
        }
        // If a QL panel is still visible from a prior preview, close it —
        // the summon means the user wants the picker, not whatever they
        // last looked at.
        PreviewCoordinator.shared.dismiss()

        previousApp = NSWorkspace.shared.frontmostApplication
        state.refresh()
        // Bump after refresh so EntryStripView's onChange sees the freshly
        // populated `rows.first` when it scrolls to the newest entry.
        state.scrollToken &+= 1
        repositionOnActiveScreen(panel)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        Log.cli.info("popup shown (previous=\(self.previousApp?.bundleIdentifier ?? "nil", privacy: .public))")
    }

    /// Fully hide the popup AND close any open Quick Look. This is the
    /// default; the preview-summon path uses `hide(closeQL: false)` because
    /// QL is the thing we're trying to surface.
    ///
    /// Preserves the current `query` + `selectedIndex` when this is a
    /// preview-triggered dismiss AND the user has opted in via the
    /// "Remember position when opening Quick Look" preference — so the
    /// next summon resumes where they were. Any other dismissal path
    /// (Escape, outside-click, paste) always resets to a clean slate.
    func hide(closeQL: Bool = true) {
        let preservePosition = !closeQL && (state?.rememberScrollOnPreview ?? false)

        removeMonitors()
        panel?.orderOut(nil)
        if closeQL {
            PreviewCoordinator.shared.dismiss()
        }
        if !preservePosition {
            state?.query = ""
            state?.selectedIndex = 0
        }
        Log.cli.info("popup hidden (closeQL=\(closeQL, privacy: .public), preserved=\(preservePosition, privacy: .public))")
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    /// Called on ⌘Y or space-when-search-empty. Hands the currently
    /// selected entry to Quick Look and then dismisses the popup so QL is
    /// the only visible window (Finder-like one-at-a-time semantics).
    /// The popup's `previousApp` capture survives the dismissal, so if the
    /// user eventually pastes after QL, focus returns correctly.
    func previewSelected() {
        guard let state = state, let id = state.selectedEntry?.id else { return }
        PreviewCoordinator.shared.preview(entryId: id, store: state.store)
        hide(closeQL: false)
    }

    /// Called when the user hits Return on a selected entry. Runs the full
    /// paste-into-previous-app flow.
    func pasteSelected() {
        guard let state = state, let entry = state.selectedEntry, let id = entry.id else { return }
        let action = PasteAction(store: state.store, previousApp: previousApp)
        // Hide before pasting so our panel isn't the key window when the
        // synthesised ⌘V flies through.
        hide()
        action.paste(entryId: id)
        Log.cli.info("pasteSelected entry \(id, privacy: .public) (previous=\(self.previousApp?.bundleIdentifier ?? "nil", privacy: .public))")
    }

    // MARK: - Positioning

    private func repositionOnActiveScreen(_ panel: PopupPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = screen else { return }
        let visible = screen.visibleFrame

        // Span the full width of the active display. Height stays fixed at
        // 420; vertical anchor stays at ~35% from the bottom of the visible
        // frame (matches Paste's "just above centre" placement).
        let panelHeight: CGFloat = 420
        let frame = NSRect(
            x: visible.minX,
            y: visible.minY + visible.height * 0.35 - panelHeight / 2,
            width: visible.width,
            height: panelHeight
        )
        panel.setFrame(frame, display: true)
    }

    // MARK: - Monitors

    private func installMonitors() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return MainActor.assumeIsolated {
                switch event.keyCode {
                case 53: // Escape
                    self.hide()
                    return nil
                case 123: // Left arrow
                    self.state?.selectPrevious()
                    return nil
                case 124: // Right arrow
                    self.state?.selectNext()
                    return nil
                case 36, 76: // Return / Enter
                    self.pasteSelected()
                    return nil
                case 16 where event.modifierFlags.contains(.command):
                    // ⌘Y — universal QL shortcut, works regardless of
                    // whether the search field has content.
                    self.previewSelected()
                    return nil
                case 49 where (self.state?.query.isEmpty ?? false):
                    // Space — QL shortcut, but only when the search field
                    // is empty. If the user is typing, space remains a
                    // literal character into the query.
                    self.previewSelected()
                    return nil
                default:
                    return event
                }
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func removeMonitors() {
        if let m = escapeMonitor {
            NSEvent.removeMonitor(m)
            escapeMonitor = nil
        }
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }
}
