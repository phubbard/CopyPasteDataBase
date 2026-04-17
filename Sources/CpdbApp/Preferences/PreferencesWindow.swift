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

    private func byteFormat(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        if n < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(n) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(n) / (1024 * 1024 * 1024))
    }
}
