import AppKit
import CloudKit
import SwiftUI
import KeyboardShortcuts
import ServiceManagement
import CpdbCore
import CpdbShared

/// Lazily-created Preferences window. One instance reused across opens.
///
/// The SwiftUI content lives in `PreferencesView`; the `NSWindowController`
/// wrapper exists so we can position, focus, and dismiss the window
/// explicitly from AppKit.
@MainActor
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()
    private var window: NSWindow?
    /// Injected by AppDelegate post-launch. The iCloud section's
    /// "Reset change token" and "Re-push everything" actions need a
    /// Store; pause is pure UserDefaults and works without one.
    private(set) var store: Store?

    private init() {}

    func configure(store: Store) {
        self.store = store
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: PreferencesView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "cpdb Preferences"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 480, height: 520))
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
    @State private var storageReport: StorageReport? = nil
    @State private var timeWindowEnabled: Bool = EvictionPrefs.timeWindowEnabled
    @State private var timeWindowDays: Int = EvictionPrefs.timeWindowDays
    @State private var evictionStatus: String = ""

    // Image analysis prefs — loaded once on appear, written back when
    // individual controls are edited.
    @State private var ocrLanguages: [String] = AnalysisPrefs.load().recognitionLanguages
    @State private var tagThreshold: Double = Double(AnalysisPrefs.load().tagConfidenceThreshold)
    @State private var reanalyzeStatus: String = ""

    // Popup UX
    @State private var rememberScrollOnPreview: Bool = UserDefaults.standard
        .bool(forKey: PopupState.rememberScrollKey)

    // iCloud / CloudKit sync
    @State private var syncPaused: Bool = CloudKitSyncer.isPaused
    @State private var iCloudAccount: String = "Checking…"
    @State private var syncQueueDepth: Int = 0
    @State private var syncLiveEntries: Int = 0
    @State private var syncLastPullText: String = PreferencesView.formattedLastSync()
    @State private var syncActionStatus: String = ""
    @State private var syncPollTask: Task<Void, Never>? = nil
    /// Adaptive step for the safety-net stepper: 5-min increments
    /// at the short end, bigger jumps as we climb. Keeps the total
    /// click count manageable (min→max is ~30 clicks).
    private var safetyNetStep: Int {
        switch safetyNetMinutes {
        case ..<30:      return 5        // 5, 10, 15, 20, 25
        case ..<120:     return 15       // 30, 45, 60, 75, 90, 105
        case ..<360:     return 30       // 120 … 360
        case ..<720:     return 60       // 360, 420, …, 720
        default:         return 120      // 720, 840, …, 1440
        }
    }

    private static func formatMinutes(_ m: Int) -> String {
        if m < 60 { return "\(m) min" }
        let h = m / 60
        let rem = m % 60
        if rem == 0 { return "\(h) h" }
        return "\(h) h \(rem) min"
    }

    @State private var safetyNetMinutes: Int = {
        let raw = UserDefaults.standard.object(forKey: CloudKitSyncer.safetyNetIntervalKey) as? Int
            ?? CloudKitSyncer.safetyNetIntervalDefaultMinutes
        return max(
            CloudKitSyncer.safetyNetIntervalMinMinutes,
            min(CloudKitSyncer.safetyNetIntervalMaxMinutes, raw)
        )
    }()

    var body: some View {
        Form {
            Section("Hotkey") {
                KeyboardShortcuts.Recorder("Show cpdb popup", name: .summonPopup)
                Text("Pick any key combination. Shown whenever you want to look at your clipboard history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("iCloud sync") {
                LabeledContent("iCloud account", value: iCloudAccount)

                HStack {
                    Text("Status")
                    Spacer()
                    Text(syncPaused ? "Paused" : "Running")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(syncPaused ? .secondary : .primary)
                }

                Toggle("Pause sync", isOn: $syncPaused)
                    .onChange(of: syncPaused) { _, newValue in
                        CloudKitSyncer.isPaused = newValue
                    }

                let pushed = max(0, syncLiveEntries - syncQueueDepth)
                LabeledContent("Pushed", value: "\(pushed) of \(syncLiveEntries)")
                LabeledContent("Last pull", value: syncLastPullText)

                // Safety-net interval. New captures push immediately
                // via an event-driven notification; silent push wakes
                // the app on inbound changes. This timer just catches
                // anything those two miss (e.g. a push that landed
                // while the Mac was asleep). Larger → quieter logs,
                // longer worst-case delay on a dropped silent push.
                HStack {
                    Text("Safety-net pull every")
                    Spacer()
                    Stepper(
                        value: $safetyNetMinutes,
                        in: (CloudKitSyncer.safetyNetIntervalMinMinutes)...(CloudKitSyncer.safetyNetIntervalMaxMinutes),
                        step: safetyNetStep
                    ) {
                        Text(Self.formatMinutes(safetyNetMinutes))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 90, alignment: .trailing)
                    }
                    .onChange(of: safetyNetMinutes) { _, new in
                        UserDefaults.standard.set(new, forKey: CloudKitSyncer.safetyNetIntervalKey)
                    }
                }
                .help("5 min to 24 h. Applies on the next idle cycle — no restart needed.")

                HStack {
                    Button("Reset change token") {
                        runResetChangeToken()
                    }
                    .help("Next pull re-fetches every record from CloudKit. Use if the local cache gets out of sync with what the Dashboard shows.")

                    Button("Re-push everything") {
                        runRequeueAll()
                    }
                    .help("Re-enqueue every live entry so CloudKit receives a full upload. Idempotent — server-side records are upserts.")
                }
                if !syncActionStatus.isEmpty {
                    Text(syncActionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Cpdb mirrors your clipboard history to your iCloud Private Database. Sync honours your iCloud account; nothing leaves your Apple ID.")
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

            Section("Popup") {
                Toggle("Remember position when opening Quick Look", isOn: $rememberScrollOnPreview)
                    .onChange(of: rememberScrollOnPreview) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: PopupState.rememberScrollKey)
                    }
                Text("When on, pressing ⌘Y or Space dismisses the popup but keeps your search and scroll position. Re-summon the popup and you'll resume where you were.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                // Tiered usage breakdown — drives the user's "should
                // I enable an eviction policy?" decision. Three rows:
                // metadata + thumbnails are always kept (cheap);
                // flavor bodies are the evictable layer that future
                // policies will target. Pinned count is informational
                // — those rows skip eviction.
                if let report = storageReport {
                    LabeledContent("  Metadata", value: byteFormat(report.metadataBytes))
                    LabeledContent("  Thumbnails", value: byteFormat(report.thumbnailBytes))
                    LabeledContent("  Flavor bodies", value: byteFormat(report.flavorBytes))
                    if report.pinnedEntryCount > 0 {
                        LabeledContent(
                            "  Pinned",
                            value: "\(report.pinnedEntryCount) (skip eviction)"
                        )
                    }
                }

                Divider()

                // Time-window eviction policy. Toggle off by default
                // — heavy-image users opt in. The daemon's daily
                // task runs the policy when enabled; the
                // "Discard now" button is for users who want
                // immediate cleanup without waiting for the loop.
                Toggle("Discard flavor bodies older than", isOn: $timeWindowEnabled)
                    .onChange(of: timeWindowEnabled) { _, newValue in
                        EvictionPrefs.timeWindowEnabled = newValue
                    }
                if timeWindowEnabled {
                    HStack {
                        Spacer()
                        Stepper(
                            value: $timeWindowDays,
                            in: (EvictionPrefs.timeWindowDaysMin)...(EvictionPrefs.timeWindowDaysMax),
                            step: timeWindowStep
                        ) {
                            Text("\(timeWindowDays) days")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 90, alignment: .trailing)
                        }
                        .onChange(of: timeWindowDays) { _, new in
                            EvictionPrefs.timeWindowDays = new
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Discard now") { runEvictNow() }
                    }
                    if !evictionStatus.isEmpty {
                        Text(evictionStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Pinned entries skip eviction. Metadata + thumbnails stay forever.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .onAppear {
            refreshStats()
            startSyncPolling()
        }
        .onDisappear {
            stopSyncPolling()
        }
        .task {
            await refreshICloudAccount()
        }
    }

    // MARK: - Sync polling + actions

    private func startSyncPolling() {
        syncPollTask?.cancel()
        syncPollTask = Task { @MainActor in
            while !Task.isCancelled {
                await refreshSyncCounts()
                syncLastPullText = PreferencesView.formattedLastSync()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopSyncPolling() {
        syncPollTask?.cancel()
        syncPollTask = nil
    }

    @MainActor
    private func refreshSyncCounts() async {
        guard let store = PreferencesWindowController.shared.store else { return }
        do {
            let (queue, live) = try await store.dbQueue.read { db -> (Int, Int) in
                let q = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloudkit_push_queue") ?? 0
                let l = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL"
                ) ?? 0
                return (q, l)
            }
            syncQueueDepth = queue
            syncLiveEntries = live
        } catch {
            // Swallow — no user-surfaceable progress update this tick.
        }
    }

    @MainActor
    private func refreshICloudAccount() async {
        do {
            let status = try await CKContainer(identifier: "iCloud.\(Paths.bundleId)").accountStatus()
            iCloudAccount = PreferencesView.describe(status)
        } catch {
            iCloudAccount = "Could not determine"
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

    private func runResetChangeToken() {
        syncActionStatus = "Resetting change token…"
        Task { @MainActor in
            guard let store = PreferencesWindowController.shared.store else {
                syncActionStatus = "No store available."
                return
            }
            do {
                try await store.dbQueue.write { db in
                    try PushQueue.State.delete(PushQueue.StateKey.zoneChangeToken, in: db)
                }
                syncActionStatus = "Change token reset. Next pull fetches everything."
                // Nudge the sync loop — menu bar's Pull from iCloud
                // handler picks this notification up and drains.
                NotificationCenter.default.post(name: .cpdbPullNow, object: nil)
            } catch {
                syncActionStatus = "Reset failed: \(error.localizedDescription)"
            }
        }
    }

    private func runRequeueAll() {
        syncActionStatus = "Re-enqueuing…"
        Task { @MainActor in
            guard let store = PreferencesWindowController.shared.store else {
                syncActionStatus = "No store available."
                return
            }
            do {
                try await store.dbQueue.write { db in
                    try db.execute(sql: "DELETE FROM cloudkit_push_queue;")
                    let now = Date().timeIntervalSince1970
                    try db.execute(
                        sql: """
                            INSERT INTO cloudkit_push_queue (entry_id, enqueued_at)
                            SELECT id, ? FROM entries WHERE deleted_at IS NULL
                        """,
                        arguments: [now]
                    )
                }
                await refreshSyncCounts()
                syncActionStatus = "Re-enqueued \(syncLiveEntries) entries."
                NotificationCenter.default.post(name: .cpdbSyncNow, object: nil)
            } catch {
                syncActionStatus = "Re-enqueue failed: \(error.localizedDescription)"
            }
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
            // Storage tier breakdown — runs O(N-blobs) directory walk
            // for blob sizes, so do it off the UI render path. The
            // detached-Task hop keeps us out of any actor surprises.
            Task.detached {
                let report = try? StorageInspector.report(store: store)
                if let report = report {
                    await MainActor.run { self.storageReport = report }
                }
            }
        }
    }

    /// Adaptive step for the eviction days stepper: per-day at the
    /// short end, weekly past a month, monthly past a year. Keeps
    /// the click count manageable for the 10-year max.
    private var timeWindowStep: Int {
        switch timeWindowDays {
        case ..<30:   return 1
        case ..<180:  return 7
        case ..<730:  return 30
        default:      return 90
        }
    }

    /// Manual one-shot run of the time-window policy. Same code path
    /// the daemon uses; kicks off-thread so the UI doesn't block on
    /// the (potentially I/O-heavy) blob deletion.
    private func runEvictNow() {
        evictionStatus = "Discarding…"
        let days = timeWindowDays
        Task.detached {
            do {
                let store = try Store.open()
                let evictor = EntryEvictor(store: store)
                let report = try evictor.evictOlderThan(days: days)
                EvictionPrefs.timeWindowLastRunAt = Date()
                let fmt = ByteCountFormatter()
                fmt.countStyle = .file
                let summary = report.entryCount == 0
                    ? "Nothing to discard."
                    : "Discarded \(report.entryCount) entries · \(fmt.string(fromByteCount: report.totalBytesFreed)) freed."
                await MainActor.run {
                    evictionStatus = summary
                    refreshStats()
                }
            } catch {
                await MainActor.run {
                    evictionStatus = "Failed: \(error)"
                }
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
