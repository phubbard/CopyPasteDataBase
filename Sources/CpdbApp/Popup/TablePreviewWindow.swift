import AppKit
import SwiftUI
import CpdbShared

/// Lazily-created "Copy as Table…" preview window. One instance reused
/// across opens — same singleton-window shape as
/// `PreferencesWindowController`, the lightest existing window pattern in
/// the app (a plain `NSWindow(contentViewController:)`, not the popup's
/// nonactivating/floating `NSPanel` machinery, since this is a one-off
/// utility window rather than something that needs to float over other
/// apps without stealing focus).
///
/// Gated at the call site (`EntryStripView`'s context menu) on
/// `#available(macOS 26.0, *)` — `DocumentTableService.isAvailable` is the
/// same check, just phrased as a runtime Bool for non-UI callers.
@available(macOS 26.0, *)
@MainActor
final class TablePreviewController: NSObject, NSWindowDelegate {
    static let shared = TablePreviewController()

    private var window: NSWindow?
    private var model: TablePreviewModel?
    /// The app frontmost before we bumped to `.regular` — captured in
    /// `showWindow` and restored in `windowWillClose`. Mirrors
    /// `PreviewCoordinator.previousAppOnOpen`.
    private var previousApp: NSRunningApplication?

    private override init() { super.init() }

    /// Show the window immediately in its loading state, then resolve
    /// asynchronously: load the entry's image bytes and run table
    /// recognition off the main actor (mirrors `Ingestor`'s
    /// `Task.detached` hand-off to `ImageIndexer.analyzeAndStore`), and
    /// update the visible window when it finishes.
    func present(entryId: Int64, store: Store) {
        // One-window-at-a-time with the popup — same contract Quick Look
        // (`previewSelected()`) and Preferences (`PopupRootView`'s gear
        // button) already follow. Without this, the popup's floating
        // panel visually overlaps this window AND its local keyDown
        // monitor (installed in `PopupController.show()`, removed only
        // by `hide()`) keeps intercepting Return/Escape/Space here —
        // Return would fire `pasteSelected()` instead of this window's
        // own Copy button.
        PopupController.shared.hide()

        let model = TablePreviewModel()
        self.model = model
        showWindow(model: model)

        Task.detached(priority: .userInitiated) {
            let phase = await Self.recognizeTablePhase(entryId: entryId, store: store)
            await MainActor.run {
                model.phase = phase
            }
        }
    }

    private func showWindow(model: TablePreviewModel) {
        let hosting = NSHostingController(rootView: TablePreviewView(model: model))
        if let window {
            window.contentViewController = hosting
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "Copy as Table"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 560, height: 420))
            window.center()
            window.delegate = self
            self.window = window
        }
        // Matches PreferencesWindowController: this is a normal utility
        // window, not the popup's nonactivating panel, so it needs
        // regular activation to become key and accept typing/clicks.
        // Reversed in `windowWillClose` — the accessory app has no menu
        // bar/Cmd-W, so the red close button is the only way out and
        // must restore .accessory the way `PreviewCoordinator.dismiss()`
        // does for Quick Look.
        previousApp = PopupController.shared.previousApp
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        previousApp?.activate()
        previousApp = nil
    }

    /// Off-main: load the entry's largest image flavor and run Vision
    /// table recognition against it. `nonisolated` so awaiting it from
    /// the detached `Task` above never touches the main actor until the
    /// final `model.phase` assignment.
    nonisolated private static func recognizeTablePhase(
        entryId: Int64,
        store: Store
    ) async -> TablePreviewModel.Phase {
        do {
            let repo = EntryRepository(store: store)
            guard let data = try repo.loadImageFlavorData(entryId: entryId, blobs: BlobStore()) else {
                return .failed("Couldn't load this image.")
            }
            let result = try await DocumentTableService.extractTables(from: data)
            return result.map(TablePreviewModel.Phase.found) ?? .notFound
        } catch let error as DocumentTableService.ServiceError {
            return .failed(error.description)
        } catch {
            return .failed("Couldn't read this image: \(error.localizedDescription)")
        }
    }
}

@available(macOS 26.0, *)
@Observable
@MainActor
final class TablePreviewModel {
    enum Phase: Equatable {
        case loading
        case found(DocumentTableService.TableResult)
        case notFound
        case failed(String)
    }

    enum Format: String, CaseIterable, Identifiable {
        case markdown = "Markdown"
        case csv = "CSV"
        var id: String { rawValue }
    }

    var phase: Phase = .loading
    var format: Format = .markdown

    var displayText: String {
        guard case .found(let result) = phase else { return "" }
        switch format {
        case .markdown: return result.markdown
        case .csv: return result.csv
        }
    }
}

@available(macOS 26.0, *)
private struct TablePreviewView: View {
    @Bindable var model: TablePreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .loading:
                statusView(systemImage: nil, text: "Recognizing table…", showsSpinner: true)
            case .notFound:
                statusView(systemImage: "tablecells", text: "No table found in this image.")
            case .failed(let message):
                statusView(systemImage: "exclamationmark.triangle", text: message)
            case .found:
                Picker("Format", selection: $model.format) {
                    ForEach(TablePreviewModel.Format.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ScrollView {
                    Text(model.displayText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack {
                    Spacer()
                    Button("Copy") {
                        copyToPasteboard(model.displayText)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private func statusView(systemImage: String?, text: String, showsSpinner: Bool = false) -> some View {
        VStack(spacing: 8) {
            if showsSpinner {
                ProgressView()
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Plain text only, deliberately — this pasteboard write is NOT
    /// wrapped in `TransientGuard`/an ignore-marker the way the popup's
    /// own paste action would be. Landing on the general pasteboard
    /// means the capture loop picks it up as a fresh entry, which is the
    /// point: the whole feature is "get this table into cpdb history as
    /// text", not just "get it onto the clipboard".
    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
