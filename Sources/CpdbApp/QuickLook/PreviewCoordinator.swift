import AppKit
import Quartz
import CpdbCore

/// Drives `QLPreviewPanel` for the currently-selected entry.
///
/// `QLPreviewPanel` is a process-wide AppKit singleton. AppKit walks the
/// responder chain looking for an object that answers `true` to
/// `acceptsPreviewPanelControl(_:)`. Our `PopupPanel` provides those
/// methods (see `Popup/PopupPanel.swift`) and forwards here.
///
/// Temp-file lifecycle:
///   - Text / image entries → we write an ephemeral file under Caches and
///     own its deletion.
///   - File entries → the URL we pass to QL is the user's real file, we
///     do NOT own it, and we must never delete it.
@MainActor
final class PreviewCoordinator: NSObject,
    @preconcurrency QLPreviewPanelDataSource,
    @preconcurrency QLPreviewPanelDelegate {

    static let shared = PreviewCoordinator()

    /// True while the QL panel is on-screen. `PopupController` reads this
    /// to skip dismiss-on-outside-click, so the user can alternate between
    /// popup and QL without the popup closing behind QL.
    private(set) var isShowing = false

    private var currentURL: URL?
    private var ownsCurrentURL = false

    private override init() { super.init() }

    // MARK: - Show / dismiss

    /// Build a preview URL for the entry and bring up `QLPreviewPanel`. If
    /// the entry kind has no preview (link / color / other), logs and does
    /// nothing — QL is not summoned in that case so the user gets an
    /// obvious "nothing happened" signal.
    func preview(entryId: Int64, store: Store) {
        cleanupCurrent()

        let builder = QuickLookItemBuilder(store: store)
        let url: URL?
        do {
            url = try builder.build(entryId: entryId)
        } catch {
            Log.cli.error("QuickLook build failed for entry \(entryId, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        guard let url = url else {
            Log.cli.info("QuickLook: nothing previewable for entry \(entryId, privacy: .public)")
            return
        }

        currentURL = url
        ownsCurrentURL = url.path.hasPrefix(
            QuickLookItemBuilder.defaultTempDir.path
        )

        let panel = QLPreviewPanel.shared()!
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        isShowing = true
    }

    /// Close the panel and clean up our temp file (if any). Safe to call
    /// when QL isn't visible.
    func dismiss() {
        if QLPreviewPanel.sharedPreviewPanelExists(),
           QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        cleanupCurrent()
        isShowing = false
    }

    // MARK: - Forwarded from PopupPanel's responder-chain hooks

    func acceptsPanelControl(_ panel: QLPreviewPanel) -> Bool {
        currentURL != nil
    }

    func beginPanelControl(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        isShowing = true
    }

    func endPanelControl(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        isShowing = false
        cleanupCurrent()
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        currentURL as NSURL?
    }

    // MARK: -

    private func cleanupCurrent() {
        if ownsCurrentURL, let url = currentURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentURL = nil
        ownsCurrentURL = false
    }
}
