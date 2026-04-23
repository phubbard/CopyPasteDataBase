import AppKit
import SwiftUI
import CloudKit
import CpdbShared

/// Lazily-created About window. Mirrors `PreferencesWindowController`'s
/// activation-policy dance so the window actually takes key focus — our
/// `.accessory` app can't hold a regular window without bumping the
/// policy to `.regular` first.
@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AboutView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "About cpdb"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 400, height: 380))
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

private struct AboutView: View {
    @State private var cloudStatus: String = "Checking…"
    @State private var lastSyncText: String = AboutView.formattedLastSync()

    private static let repoURL = URL(string: "https://github.com/phubbard/CopyPasteDataBase")!

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "list.clipboard.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            Text("cpdb")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text("v\(CpdbVersion.current)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)

            Text("A local-first clipboard history for macOS, with on-device OCR and image search.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            Link(destination: Self.repoURL) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("github.com/phubbard/CopyPasteDataBase")
                }
                .font(.system(size: 12))
            }

            Divider()
                .padding(.horizontal, 24)

            VStack(spacing: 6) {
                AboutRow(label: "iCloud account", value: cloudStatus)
                AboutRow(label: "Last sync", value: lastSyncText)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 20)
        .frame(width: 400, height: 380)
        .task {
            await loadCloudStatus()
        }
    }

    @MainActor
    private func loadCloudStatus() async {
        do {
            let status = try await CKContainer(identifier: "iCloud.\(Paths.bundleId)").accountStatus()
            cloudStatus = Self.describe(status)
        } catch {
            cloudStatus = "Could not determine"
        }
    }

    private static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available:              return "Signed in"
        case .noAccount:              return "Not signed in"
        case .restricted:             return "Restricted"
        case .couldNotDetermine:      return "Unknown"
        case .temporarilyUnavailable: return "Temporarily unavailable"
        @unknown default:             return "Unknown"
        }
    }

    /// Renders the last-sync timestamp from UserDefaults. Shows "Never"
    /// while the CloudKit syncer (steps 4–5) hasn't been wired yet —
    /// that code will write the key on every successful pull and this
    /// string will start updating.
    private static func formattedLastSync() -> String {
        let raw = UserDefaults.standard.double(forKey: CloudKitSyncer.lastSyncSuccessKey)
        guard raw > 0 else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(
            for: Date(timeIntervalSince1970: raw),
            relativeTo: Date()
        )
    }
}

private struct AboutRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}
