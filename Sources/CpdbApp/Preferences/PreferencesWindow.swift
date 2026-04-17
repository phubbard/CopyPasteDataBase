import AppKit
import SwiftUI
import KeyboardShortcuts
import ServiceManagement
import CpdbCore

/// Lazily-created Preferences window. One instance reused across opens.
///
/// The SwiftUI content lives in `PreferencesView`; the `NSWindowController`
/// wrapper exists so we can position, focus, and dismiss the window
/// explicitly from AppKit.
@MainActor
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: PreferencesView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "cpdb Preferences"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 480, height: 420))
            window.center()
            self.window = window
        }
        // Preferences needs normal foreground activation so the user can
        // type in the recorder — temporarily bump the activation policy.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
        // Drop back to accessory mode so the Dock icon disappears again.
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - SwiftUI content

private struct PreferencesView: View {
    @State private var accessibilityGranted = Accessibility.isTrusted()
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var dbPath = Paths.databaseURL.path
    @State private var dbSize = "—"
    @State private var totalEntries = "—"

    // Image analysis prefs — loaded once on appear, written back when
    // individual controls are edited.
    @State private var ocrLanguages: [String] = AnalysisPrefs.load().recognitionLanguages
    @State private var tagThreshold: Double = Double(AnalysisPrefs.load().tagConfidenceThreshold)
    @State private var reanalyzeStatus: String = ""

    var body: some View {
        Form {
            Section("Hotkey") {
                KeyboardShortcuts.Recorder("Show cpdb popup", name: .summonPopup)
                Text("Pick any key combination. Shown whenever you want to look at your clipboard history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch cpdb at login", isOn: $launchAtLoginEnabled)
                    .onChange(of: launchAtLoginEnabled) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            Log.cli.error("launch at login toggle failed: \(String(describing: error), privacy: .public)")
                        }
                    }
            }

            Section("Image analysis") {
                Text("Image entries are run through Apple's on-device OCR and image classifier. Extracted text and tags are folded into the search index.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Language multi-select. We list Apple's supported languages
                // for `.accurate` OCR and let the user toggle each one.
                DisclosureGroup("OCR languages (\(ocrLanguages.count) selected)") {
                    let all = ImageAnalyzer.supportedLanguages()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(all, id: \.self) { lang in
                                Toggle(lang, isOn: Binding(
                                    get: { ocrLanguages.contains(lang) },
                                    set: { on in
                                        if on {
                                            if !ocrLanguages.contains(lang) { ocrLanguages.append(lang) }
                                        } else {
                                            ocrLanguages.removeAll { $0 == lang }
                                        }
                                        // Guard against an empty list — Vision
                                        // needs at least one language.
                                        if ocrLanguages.isEmpty { ocrLanguages = ["en-US"] }
                                        saveAnalysisPrefs()
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12, design: .monospaced))
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }

                HStack {
                    Text("Tag confidence threshold")
                    Spacer()
                    Text(String(format: "%.2f", tagThreshold))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $tagThreshold, in: 0.05...0.50, step: 0.05) { _ in
                    saveAnalysisPrefs()
                }
                Text("Higher → fewer but more-confident tags. Lower → more tags, some noise.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                HStack {
                    Button("Re-analyze all images…") {
                        runReanalyze()
                    }
                    if !reanalyzeStatus.isEmpty {
                        Text(reanalyzeStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Accessibility") {
                HStack {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(accessibilityGranted ? .green : .orange)
                    Text(accessibilityGranted
                         ? "Granted — ⌘V pasting works"
                         : "Not granted — cpdb can't press ⌘V for you")
                        .font(.system(size: 13))
                }
                if !accessibilityGranted {
                    Text("Open System Settings → Privacy & Security → Accessibility, find cpdb in the list, and turn it on. Then relaunch cpdb.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Open System Settings…") {
                            Accessibility.openSystemSettings()
                        }
                        Button("Re-check") {
                            accessibilityGranted = Accessibility.isTrusted()
                        }
                    }
                }
            }

            Section("Storage") {
                LabeledContent("Database", value: dbPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                LabeledContent("Size", value: dbSize)
                LabeledContent("Entries", value: totalEntries)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 420)
        .onAppear {
            refreshStats()
        }
    }

    private func refreshStats() {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: Paths.databaseURL.path),
           let size = attrs[.size] as? Int {
            dbSize = byteFormat(Int64(size))
        }
        if let store = try? Store.open() {
            let repo = EntryRepository(store: store)
            if let total = try? repo.totalLiveCount() {
                totalEntries = "\(total)"
            }
        }
    }

    private func saveAnalysisPrefs() {
        AnalysisPrefs(
            recognitionLanguages: ocrLanguages,
            tagConfidenceThreshold: Float(tagThreshold)
        ).save()
    }

    /// Spawns the CLI binary that lives next to the app bundle to run the
    /// backfill. Keeping it out-of-process means a long re-analysis doesn't
    /// block the UI, and the user gets the same progress/stderr stream as
    /// running it from the terminal. We locate the CLI via the signed app
    /// bundle's MacOS directory if possible, falling back to `cpdb` on PATH.
    private func runReanalyze() {
        reanalyzeStatus = "Running…"
        let cli = resolveCliPath()
        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cli)
            proc.arguments = ["analyze-images", "--force"]
            do {
                try proc.run()
                proc.waitUntilExit()
                let ok = proc.terminationStatus == 0
                await MainActor.run {
                    reanalyzeStatus = ok ? "Done." : "Exited with status \(proc.terminationStatus)."
                }
            } catch {
                await MainActor.run {
                    reanalyzeStatus = "Couldn't run cpdb: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Find the `cpdb` CLI. Priority: sibling of the app bundle (common
    /// developer layout where both are built into `.build/release/`), then
    /// PATH via `/usr/bin/env cpdb`.
    private func resolveCliPath() -> String {
        // `.build/app/cpdb.app/../cpdb` during `make run-app`
        // or `/Applications/cpdb.app/Contents/MacOS/cpdb` — but the CLI
        // binary and the app binary are separate products. When installed
        // via `make install-app`, the CLI isn't copied alongside; for
        // now we defer to PATH.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/bin/cpdb",
            "/usr/local/bin/cpdb",
            "/opt/homebrew/bin/cpdb",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/env"  // falls through to args[0] = "cpdb" on PATH
    }

    private func byteFormat(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        if n < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(n) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(n) / (1024 * 1024 * 1024))
    }
}
