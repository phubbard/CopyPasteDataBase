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
    /// Injected by AppDelegate after the Store opens. The About view
    /// polls queue + entry counts from here to draw sync progress.
    /// Nil means sync isn't running (no iCloud account or read-only
    /// mode) — the progress section hides itself.
    private(set) var store: Store?

    private init() {}

    func configure(store: Store) {
        self.store = store
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AboutView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "About cpdb"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 420, height: 430))
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

/// Snapshot of sync backlog state at one sample point. The About view
/// keeps a sliding window of these to compute push rate + ETA.
private struct SyncSample {
    var timestamp: Date
    /// Entries still in the push queue.
    var queueDepth: Int
    /// Total live (non-tombstoned) entries in the local DB.
    var liveEntries: Int
}

private struct AboutView: View {
    @State private var cloudStatus: String = "Checking…"
    @State private var lastSyncText: String = AboutView.formattedLastSync()
    @State private var samples: [SyncSample] = []
    @State private var pollTask: Task<Void, Never>? = nil

    private static let repoURL = URL(string: "https://github.com/phubbard/CopyPasteDataBase")!

    /// How long the sliding window for rate computation covers. 30 s
    /// balances responsiveness (a fresh batch succeeds → ETA updates)
    /// with smoothing (one slow round-trip doesn't swing ETA wildly).
    private static let rateWindow: TimeInterval = 30

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
                if let latest = samples.last {
                    syncProgressBlock(sample: latest)
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 20)
        .frame(width: 420, height: 430)
        .task {
            await loadCloudStatus()
        }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    /// Progress section. Hidden when there's nothing pending, shown as
    /// a progress bar + "X of Y · ETA mm:ss" otherwise. ETA is the
    /// simple (queue / rate) formula — rate is the average records-
    /// pushed-per-second across the sliding window.
    @ViewBuilder
    private func syncProgressBlock(sample: SyncSample) -> some View {
        let pushed = max(0, sample.liveEntries - sample.queueDepth)
        let total = max(sample.liveEntries, 1)
        let fraction = Double(pushed) / Double(total)

        if sample.queueDepth == 0 {
            AboutRow(label: "Sync backlog", value: "Up to date")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sync backlog")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(pushed) of \(total)")
                        .font(.system(size: 12, design: .monospaced))
                }
                ProgressView(value: fraction)
                    .controlSize(.small)
                HStack {
                    Text(etaString())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(rateString())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Cap the sample history, compute a rate from the oldest in-window
    /// sample to the newest. Returns entries/sec (positive when the
    /// queue is shrinking).
    private func rate() -> Double? {
        guard samples.count >= 2 else { return nil }
        let newest = samples.last!
        let cutoff = newest.timestamp.addingTimeInterval(-Self.rateWindow)
        let oldest = samples.first { $0.timestamp >= cutoff } ?? samples.first!
        let dt = newest.timestamp.timeIntervalSince(oldest.timestamp)
        guard dt > 0.5 else { return nil }
        // Depth drops as we push; progress rate = -dDepth/dt.
        let drop = Double(oldest.queueDepth - newest.queueDepth)
        let r = drop / dt
        return r > 0 ? r : nil
    }

    private func etaString() -> String {
        guard let r = rate(), let latest = samples.last else {
            return "ETA —"
        }
        let seconds = Double(latest.queueDepth) / r
        return "ETA \(formatDuration(seconds))"
    }

    private func rateString() -> String {
        guard let r = rate() else { return "" }
        if r >= 10 {
            return String(format: "%.0f entries/s", r)
        } else {
            return String(format: "%.1f entries/s", r)
        }
    }

    /// Pretty-print a duration as `mm:ss` (under an hour) or `HH:mm:ss`.
    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                if let sample = await pollSample() {
                    appendSample(sample)
                }
                lastSyncText = AboutView.formattedLastSync()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollSample() async -> SyncSample? {
        guard let store = AboutWindowController.shared.store else { return nil }
        do {
            return try await store.dbQueue.read { db -> SyncSample in
                let queue = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloudkit_push_queue") ?? 0
                let live = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL"
                ) ?? 0
                return SyncSample(timestamp: Date(), queueDepth: queue, liveEntries: live)
            }
        } catch {
            return nil
        }
    }

    /// Append a new sample and drop anything older than twice the rate
    /// window (so the ring stays bounded but we always have enough data
    /// to average over).
    private func appendSample(_ s: SyncSample) {
        samples.append(s)
        let cutoff = s.timestamp.addingTimeInterval(-Self.rateWindow * 2)
        samples.removeAll { $0.timestamp < cutoff }
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
    /// until the syncer writes the key on its first successful pull.
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
