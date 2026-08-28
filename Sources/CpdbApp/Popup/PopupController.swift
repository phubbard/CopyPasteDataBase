import AppKit
import CpdbCore
import CpdbShared
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

    /// The strip needs card height (360) + vertical padding (28) = 388pt,
    /// plus ~90pt of search/chips/divider chrome. The historical "420"
    /// never actually held: before v3.2.2 the NSHostingView's default
    /// sizingOptions silently grew the window to fit (~478pt). Once
    /// v3.2.3 pinned window sizing (sizingOptions = []), 420 became a
    /// real constraint — the horizontal ScrollView vertically centered
    /// its too-tall content and clipped every card ~29pt top and
    /// bottom. 480 is the honest number.
    static let panelHeight: CGFloat = 480

    private var panel: PopupPanel?
    /// `private(set)` (rather than fully private) so the same-module
    /// App Intents plumbing tests can assert on post-intent state
    /// (query, selection, scrollToken) without a parallel API surface
    /// just for testing.
    private(set) var state: PopupState?
    private var escapeMonitor: Any?
    private var outsideClickMonitor: Any?
    private(set) var previousApp: NSRunningApplication?

    private init() {}

    /// Call once, from `AppDelegate.applicationDidFinishLaunching`.
    func configure(store: Store, captureMode: PopupState.CaptureMode) {
        let state = PopupState(store: store)
        state.captureMode = captureMode
        self.state = state

        let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: Self.panelHeight))
        // .environment(\.cpdbStore, store) threads the Store down to
        // ImageCard/LinkCard so they read thumbnails via the shared
        // DatabaseQueue instead of each opening their own with
        // Store.open() per render (see PopupEnvironment.swift).
        let hosting = NSHostingController(rootView: PopupRootView(state: state, onPaste: { [weak self] in
            self?.pasteSelected()
        }).environment(\.cpdbStore, store))
        // The panel's frame is authoritative (repositionOnActiveScreen sets
        // it explicitly on every summon) — SwiftUI must never drive the
        // window size. The default sizingOptions let intrinsic-size changes
        // resize the window; the eager HStack never exercised that path,
        // but the LazyHStack's estimated sizing does: the panel ballooned
        // past its 420pt height and covered the menu bar/Dock (v3.2.2
        // regression).
        hosting.sizingOptions = []
        hosting.view.frame = panel.contentLayoutRect
        panel.contentViewController = hosting
        self.panel = panel
    }

    func show() {
        guard let panel = panel, let state = state else {
            Log.cli.error("PopupController.show called before configure")
            return
        }
        // perf: stage timestamps for the popup-perf log line emitted
        // below, one runloop turn after makeKeyAndOrderFront. Measurement
        // only — no behavior change. See PopupPerfCounters for the
        // card-load (thumbnail) side of the accounting.
        let perfEntry = ContinuousClock.now
        PopupPerfCounters.shared.reset()

        // If a QL panel is still visible from a prior preview, close it —
        // the summon means the user wants the picker, not whatever they
        // last looked at.
        PreviewCoordinator.shared.dismiss()
        let perfAfterDismiss = ContinuousClock.now

        previousApp = NSWorkspace.shared.frontmostApplication
        state.refresh()
        let perfAfterRefresh = ContinuousClock.now
        // Bump after refresh so EntryStripView's onChange sees the freshly
        // populated `rows.first` when it scrolls to the newest entry.
        state.scrollToken &+= 1
        repositionOnActiveScreen(panel)
        let perfAfterReposition = ContinuousClock.now
        panel.makeKeyAndOrderFront(nil)
        let perfAfterMakeKey = ContinuousClock.now
        installMonitors()
        Log.cli.info("popup shown (previous=\(self.previousApp?.bundleIdentifier ?? "nil", privacy: .public))")

        // perf: fire on the next runloop turn (≈ first CA commit after
        // makeKeyAndOrderFront) so `firstFrame` approximates time-to-
        // first-paint. Card loads that land after this point (e.g. from
        // scrolling) keep accumulating into PopupPerfCounters and are
        // reported by the `popup-perf-session` line in `hide()`.
        //
        // startLiveUpdates() is deliberately started here too, AFTER
        // makeKeyAndOrderFront rather than before it. `Store` uses a
        // single-connection `DatabaseQueue`, so its initial aggregate
        // fetch (5 SQL statements, measured ~250ms for rows=200) and
        // ImageCard/LinkCard's per-thumbnail `await dbQueue.read`s all
        // serialize on the same dispatch queue in enqueue order.
        // Starting live updates before the cards render — as this code
        // originally did — enqueues that ~250ms fetch first and forces
        // every visible thumbnail to wait behind it, producing a
        // placeholder flash on every summon that the old fully-
        // synchronous implementation never had (it used a separate,
        // uncontended `Store.open()` connection per card). Starting it
        // here instead lets the cards' `.task`s — which fire as part of
        // the makeKeyAndOrderFront layout/appear pass just completed —
        // enqueue their reads first. The aggregate fetch is background
        // bookkeeping; a delay of one runloop turn before it starts is
        // not user-visible.
        let rowCount = state.rows.count
        DispatchQueue.main.async {
            // Guard against a hide() racing ahead of this deferred
            // block (e.g. a fast toggle()/Escape in the same runloop
            // turn as show()): hide() calls stopLiveUpdates() before
            // this runs, so without the check we'd start a live
            // observation for a popup that's already closed and leave
            // it running (pinning the DB) until the *next* hide().
            if panel.isVisible {
                state.startLiveUpdates()
            }
            let perfFirstFrame = ContinuousClock.now
            let refreshMs = Self.perfMs(perfAfterDismiss, perfAfterRefresh)
            let repositionMs = Self.perfMs(perfAfterRefresh, perfAfterReposition)
            let makeKeyMs = Self.perfMs(perfAfterReposition, perfAfterMakeKey)
            let firstFrameMs = Self.perfMs(perfAfterMakeKey, perfFirstFrame)
            let totalMs = Self.perfMs(perfEntry, perfFirstFrame)
            let counters = PopupPerfCounters.shared
            let thumbMs = Self.perfMs(nanos: counters.thumbNanos)
            Log.cli.info(
                "popup-perf: refresh=\(refreshMs, privacy: .public) reposition=\(repositionMs, privacy: .public) makeKey=\(makeKeyMs, privacy: .public) firstFrame=\(firstFrameMs, privacy: .public) total=\(totalMs, privacy: .public) rows=\(rowCount, privacy: .public) thumbLoads=\(counters.thumbLoads, privacy: .public) thumbMs=\(thumbMs, privacy: .public) storeOpens=\(counters.storeOpens, privacy: .public)"
            )
        }
    }

    /// perf: milliseconds (one decimal) between two `ContinuousClock`
    /// instants, as used by the `popup-perf` log line.
    private static func perfMs(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> String {
        let components = from.duration(to: to).components
        let millis = Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.1f", millis)
    }

    /// perf: milliseconds (one decimal) from a raw nanosecond count, as
    /// used for `PopupPerfCounters.thumbNanos`.
    private static func perfMs(nanos: UInt64) -> String {
        String(format: "%.1f", Double(nanos) / 1_000_000)
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
        state?.stopLiveUpdates()
        panel?.orderOut(nil)
        if closeQL {
            PreviewCoordinator.shared.dismiss()
        }
        if !preservePosition {
            state?.query = ""
            state?.selectedIndex = 0
        }
        // perf: session totals for card loads triggered by this summon,
        // including any that landed after the `popup-perf` first-frame
        // marker in `show()` (e.g. from scrolling). Counters are reset
        // at the top of the next `show()`.
        let counters = PopupPerfCounters.shared
        let thumbMs = Self.perfMs(nanos: counters.thumbNanos)
        Log.cli.info(
            "popup-perf-session: thumbLoads=\(counters.thumbLoads, privacy: .public) thumbMs=\(thumbMs, privacy: .public) storeOpens=\(counters.storeOpens, privacy: .public)"
        )
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

    /// Delete (tombstone) the selected entry. Mirrors
    /// `EntryStripView.delete(row:)` — same repository.tombstone +
    /// explicit refresh path — so the keyboard shortcut and the
    /// context-menu Delete behave identically. Selection is clamped
    /// by `PopupState.refresh()` so focus lands on the next row.
    func deleteSelected() {
        guard let state = state, let id = state.selectedEntry?.id else { return }
        // Routed through PopupState → UndoCoordinator so the delete is
        // recorded for ⌘Z. The single-row tombstone is a sub-ms write.
        state.delete(id: id)
    }

    // MARK: - App Intents entry points
    //
    // Thin glue for `SearchClipsIntent` / `PasteLatestIntent` /
    // `PasteNthIntent` / `TogglePinLatestIntent` / the Spotlight
    // click-through deep link (see `Intents/`). Kept here rather than
    // in the intents themselves so an intent's `perform()` body is
    // just "wait for readiness, call one of these" — the actual
    // row-selection logic (`ClipIntentSupport.entry(atRecentIndex:)`)
    // stays in the AppKit-free, directly-testable file.

    /// Backs `SearchClipsIntent`. Opens the popup exactly like a hotkey
    /// summon, then pre-fills the search field — same effect as the
    /// user typing it themselves, so it goes through the normal
    /// `query` `didSet` → `refresh()` path.
    func searchAndShow(query: String) {
        show()
        state?.query = query
    }

    /// Backs `PasteNthIntent`. Deliberately does NOT show the popup
    /// first — an intent-driven paste should be invisible when it
    /// succeeds, same as a Shortcut running silently. `previousApp` is
    /// captured here (frontmost app at intent-fire time) rather than
    /// relying on a stale value from the last popup summon, matching
    /// `pasteSelected()`'s contract.
    ///
    /// Uses popup-card ordering (pinned-first) via
    /// `ClipIntentSupport.recentEntries` — "clip number N" means "the
    /// Nth card", pins included, matching what `PasteNthIntent`
    /// documents. For "my *last* clip" regardless of pins, see
    /// `pasteLatest()`.
    func pasteRecent(atIndex n: Int) {
        guard let state = state else { return }
        let rows = (try? ClipIntentSupport.recentEntries(store: state.store, limit: max(n, 1))) ?? []
        guard let row = ClipIntentSupport.entry(atRecentIndex: n, in: rows), let id = row.entry.id else {
            Log.cli.info("pasteRecent(atIndex: \(n, privacy: .public)): nothing to paste")
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        let action = PasteAction(store: state.store, previousApp: previousApp)
        action.paste(entryId: id)
        Log.cli.info("pasteRecent(atIndex: \(n, privacy: .public)) entry \(id, privacy: .public)")
    }

    /// Backs `PasteLatestIntent`. Pastes the entry with the newest
    /// `created_at`, ignoring pin status — same no-popup contract as
    /// `pasteRecent(atIndex:)`, but resolved via `ClipIntentSupport
    /// .latestEntries` so a pinned entry from last week never shadows
    /// what was just copied.
    func pasteLatest() {
        guard let state = state else { return }
        let rows = (try? ClipIntentSupport.latestEntries(store: state.store, limit: 1)) ?? []
        guard let row = rows.first, let id = row.entry.id else {
            Log.cli.info("pasteLatest(): nothing to paste")
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        let action = PasteAction(store: state.store, previousApp: previousApp)
        action.paste(entryId: id)
        Log.cli.info("pasteLatest() entry \(id, privacy: .public)")
    }

    /// Backs `TogglePinLatestIntent`. Toggles the pin on the entry with
    /// the newest `created_at`, ignoring pin status — resolved via
    /// `ClipIntentSupport.latestEntries` so pinning a fresh copy can't
    /// instead un-pin whatever was pinned before it.
    func togglePinLatest() {
        guard let state = state else { return }
        let rows = (try? ClipIntentSupport.latestEntries(store: state.store, limit: 1)) ?? []
        guard let row = rows.first, let id = row.entry.id else { return }
        state.togglePin(id: id, currentlyPinned: row.entry.pinned)
    }

    /// Backs the Spotlight-donation / `cpdb://clip/<id>` click-through:
    /// show the popup and land selection + scroll on one specific
    /// entry. Uses `PopupState.revealAndSelect`, which resets any
    /// stale kind-filter/search state and falls back to a direct fetch
    /// for an entry older than the popup's default view — a Spotlight
    /// target is disproportionately likely to be exactly that. Only
    /// no-ops (still shows the popup, no selection) if the entry was
    /// deleted since it was donated.
    func showAndSelect(entryId: Int64) {
        show()
        guard let state = state, state.revealAndSelect(entryId: entryId) else {
            Log.cli.info("showAndSelect(entryId: \(entryId, privacy: .public)): entry no longer exists")
            return
        }
        state.scrollToken &+= 1
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
        let panelHeight = Self.panelHeight
        let frame = NSRect(
            x: visible.minX,
            y: visible.minY + visible.height * 0.35 - panelHeight / 2,
            width: visible.width,
            height: panelHeight
        )
        // display:false when the panel is currently ordered out (the
        // common case — every show() call starting from hidden): a
        // synchronous display pass would force layout+draw of the whole
        // card tree before makeKeyAndOrderFront ever runs, and ordering
        // the panel front right after this triggers the real display
        // pass once anyway. But show() is also reachable while the
        // panel is ALREADY visible (AppDelegate.applicationShouldHandleReopen
        // calls PopupController.shared.show() unconditionally) — on
        // that path makeKeyAndOrderFront on an already-front window
        // does not force a synchronous redraw, so a deferred display
        // pass could show stale backing-store content, stretched to
        // the new frame, for one frame on a screen change. Use a
        // synchronous display there, matching the pre-perf-fix behavior
        // for the already-visible case.
        panel.setFrame(frame, display: panel.isVisible)
    }

    // MARK: - Monitors

    private func installMonitors() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // NSEvent isn't Sendable, but the handler signature is
            // declared @Sendable for the API contract. AppKit
            // actually delivers these on the main thread — but the
            // compiler can't see that. Pull out the raw values we
            // need (Sendable scalars) BEFORE hopping onto MainActor,
            // so we don't carry the NSEvent across the isolation
            // boundary.
            let keyCode = event.keyCode
            let cmdHeld = event.modifierFlags.contains(.command)
            // Inner block returns a Sendable signal (`true` = consume,
            // `false` = pass through). The original NSEvent is then
            // returned from the outer closure based on that signal,
            // never crossing the MainActor boundary itself.
            let consumed: Bool = MainActor.assumeIsolated {
                switch keyCode {
                case 53: // Escape
                    // Time-pivot mode owns Escape — it exits the
                    // mode and restores the prior search query +
                    // selection. Only when NOT in pivot does Esc
                    // hide the popup. Matches the Quick Look /
                    // sheet convention: Esc closes one layer at a
                    // time, the outermost dismiss comes last.
                    if self.state?.timePivot != nil {
                        self.state?.exitTimePivot()
                    } else {
                        self.hide()
                    }
                    return true
                case 17 where cmdHeld:
                    // ⌘T — enter time-pivot mode anchored on the
                    // selected card. Shows neighbors captured
                    // within ±30 min (default) of the anchor's
                    // captured_at, ordered chronologically. [ / ]
                    // widen/narrow; Esc restores the prior search.
                    if let entry = self.state?.selectedEntry {
                        self.state?.enterTimePivot(anchoredOn: entry)
                    }
                    return true
                case 6 where cmdHeld && event.modifierFlags.contains(.shift):
                    // ⌘⇧Z — redo the last undone delete/pin.
                    self.state?.performRedo()
                    return true
                case 6 where cmdHeld:
                    // ⌘Z — undo the last delete/pin. Reversible across the
                    // session's action stack.
                    self.state?.performUndo()
                    return true
                case 33 where (self.state?.timePivot != nil):
                    // [ — narrow the time-pivot window. Gated to
                    // pivot mode so the bracket key remains a
                    // literal character in the search field
                    // otherwise.
                    self.state?.narrowTimePivot()
                    return true
                case 30 where (self.state?.timePivot != nil):
                    // ] — widen the time-pivot window. Same gate as
                    // [ above.
                    self.state?.widenTimePivot()
                    return true
                case 123: // Left arrow
                    self.state?.selectPrevious()
                    return true
                case 124: // Right arrow
                    self.state?.selectNext()
                    return true
                case 36, 76: // Return / Enter
                    self.pasteSelected()
                    return true
                case 16 where cmdHeld:
                    // ⌘Y — universal QL shortcut, works regardless of
                    // whether the search field has content.
                    self.previewSelected()
                    return true
                case 49 where (self.state?.query.isEmpty ?? false):
                    // Space — QL shortcut, but only when the search field
                    // is empty. If the user is typing, space remains a
                    // literal character into the query.
                    self.previewSelected()
                    return true
                case 51 where (self.state?.query.isEmpty ?? false):
                    // Delete/Backspace — tombstone the selected entry,
                    // but ONLY when the search field is empty. While
                    // the user is typing a query, Backspace must keep
                    // editing the text (same gating as Space above).
                    self.deleteSelected()
                    return true
                case 117:
                    // Forward-delete (fn+Delete / the dedicated
                    // Delete key on full keyboards). Not a
                    // text-editing key in this context, so no
                    // query-empty gate needed — always deletes the
                    // selected entry.
                    self.deleteSelected()
                    return true
                default:
                    return false
                }
            }
            return consumed ? nil : event
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
