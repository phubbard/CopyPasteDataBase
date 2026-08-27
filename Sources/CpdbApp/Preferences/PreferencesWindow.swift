import AppKit
import CloudKit
import SwiftUI
import UniformTypeIdentifiers
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
    /// Tri-state from the NWBrowser probe; defaults to .unknown so
    /// the row renders a neutral spinner-ish indicator until the
    /// first probe lands (typically <2s after the window opens).
    @State private var localNetworkStatus: LocalNetwork.Status = .unknown
    /// 5-second timer that re-runs the Accessibility check and
    /// (when not yet granted) the Local Network probe while the
    /// Preferences window is on screen. Cancelled in onDisappear so
    /// it doesn't burn CPU when the window is hidden.
    @State private var permissionPollerTask: Task<Void, Never>? = nil
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var dbPath = Paths.databaseURL.path
    @State private var dbSize = "—"
    @State private var totalEntries = "—"
    @State private var storageReport: StorageReport? = nil
    @State private var timeWindowEnabled: Bool = EvictionPrefs.timeWindowEnabled
    @State private var timeWindowDays: Int = EvictionPrefs.timeWindowDays
    @State private var evictionStatus: String = ""
    @State private var linkBackfillStatus: String = ""
    @State private var importExportStatus: String = ""
    @State private var exportFormat: HistoryExporter.Format = .md

    // Image analysis prefs — loaded once on appear, written back when
    // individual controls are edited.
    @State private var ocrLanguages: [String] = AnalysisPrefs.load().recognitionLanguages
    @State private var tagThreshold: Double = Double(AnalysisPrefs.load().tagConfidenceThreshold)
    @State private var reanalyzeStatus: String = ""

    // AI enrichment (Foundation Models title/summary) prefs.
    @State private var aiEnrichmentEnabled: Bool = AIEnrichmentPrefs.load().enabled
    /// Read once per view instance rather than per-render: Foundation
    /// Models' own availability doesn't change while Preferences is open
    /// (it depends on System Settings / model download state, not
    /// anything this window mutates), so there's no need for a poller
    /// like the permission rows below use.
    private let aiAvailability: AIAvailability = AIService.availability

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

            Section("AI enrichment") {
                Text("Long text clips get a short title and summary from Apple's on-device Foundation Models. Nothing leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch aiAvailability {
                case .available:
                    Toggle("Generate AI titles and summaries", isOn: $aiEnrichmentEnabled)
                        .onChange(of: aiEnrichmentEnabled) { _, newValue in
                            AIEnrichmentPrefs(enabled: newValue).save()
                        }
                case .notEnabled(let reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                case .unsupportedOS:
                    Text("Requires macOS 26 or later.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Permissions") {
                permissionRow(
                    granted: accessibilityGranted,
                    grantedLabel: "Accessibility — ⌘V pasting works",
                    deniedLabel: "Accessibility — cpdb can't press ⌘V for you",
                    deniedHelp: "Open System Settings → Privacy & Security → Accessibility, find cpdb in the list, and turn it on. Then relaunch cpdb.",
                    openSettings: Accessibility.openSystemSettings,
                    recheck: { accessibilityGranted = Accessibility.isTrusted() }
                )
                permissionRow(
                    granted: localNetworkStatus == .granted,
                    indeterminate: localNetworkStatus == .unknown,
                    grantedLabel: "Local Network — link-title fetch covers private IPs",
                    deniedLabel: "Local Network — link fetches stall on private IPs",
                    indeterminateLabel: "Local Network — checking…",
                    deniedHelp: "Open System Settings → Privacy & Security → Local Network, find cpdb in the list, and turn it on. Pages on your corporate VPN or intranet (private IP addresses) need this for title + preview fetch.",
                    openSettings: LocalNetwork.openSystemSettings,
                    recheck: { Task { await refreshLocalNetwork() } }
                )
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

                Divider()

                // Link-title backfill controls. The daemon runs
                // small batches automatically — this button is for
                // users who want to force a sweep (e.g. after being
                // offline) or refetch everything (URLs whose pages
                // changed titles since first capture).
                HStack {
                    Button("Fetch link titles") { runLinkBackfill(force: false) }
                        .help("Process links that have never been attempted (the normal background path, run on demand).")
                    Button("Retry empties") { runLinkBackfillRetryEmpty() }
                        .help("Re-run fetch on links that came back empty (failed, rate-limited, or genuinely had no title). Leaves successful titles alone — much friendlier than 'Refetch all'.")
                    Button("Refetch all") { runLinkBackfill(force: true) }
                        .help("Clear the per-entry sentinel and re-run the fetch on every link, including ones already titled. Use sparingly — hammers YouTube's rate limit on a large library.")
                    Spacer()
                }
                if !linkBackfillStatus.isEmpty {
                    Text(linkBackfillStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Background-fetches page or video titles for captured URLs so search finds links by their content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Import / Export") {
                HStack {
                    Button("Import URLs…") { importURLs() }
                    Spacer()
                }
                Text("Seed the database from a text file of one http(s):// or file:// URL per line. Each is treated like a clipboard copy, so links get titles + thumbnails fetched in the background. Blank lines and #-comments are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Export format", selection: $exportFormat) {
                    Text("Markdown").tag(HistoryExporter.Format.md)
                    Text("CSV").tag(HistoryExporter.Format.csv)
                    Text("HTML").tag(HistoryExporter.Format.html)
                }
                HStack {
                    Button("Export…") { exportHistory() }
                    Spacer()
                }
                Text("Writes the whole history (newest first) as a portable document. Metadata + text only — flavor bytes aren't included; this is a reading/searching archive, not a restore image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !importExportStatus.isEmpty {
                    Text(importExportStatus)
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
            startPermissionPoller()
        }
        .onDisappear {
            stopSyncPolling()
            permissionPollerTask?.cancel()
            permissionPollerTask = nil
        }
        .task {
            await refreshICloudAccount()
        }
    }

    /// Reusable row for the "Permissions" section. Renders a green
    /// checkmark / orange exclamation / neutral hourglass next to a
    /// state-appropriate label, plus a help blurb + "Open System
    /// Settings…" + "Re-check" buttons when not granted.
    @ViewBuilder
    private func permissionRow(
        granted: Bool,
        indeterminate: Bool = false,
        grantedLabel: String,
        deniedLabel: String,
        indeterminateLabel: String? = nil,
        deniedHelp: String,
        openSettings: @escaping () -> Void,
        recheck: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if indeterminate {
                    Image(systemName: "hourglass.circle")
                        .foregroundStyle(.secondary)
                    Text(indeterminateLabel ?? deniedLabel)
                        .font(.system(size: 13))
                } else {
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(granted ? .green : .orange)
                    Text(granted ? grantedLabel : deniedLabel)
                        .font(.system(size: 13))
                }
            }
            if !granted && !indeterminate {
                Text(deniedHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open System Settings…", action: openSettings)
                    Button("Re-check", action: recheck)
                }
            }
        }
    }

    /// Refresh the Local Network status with a fresh `NWBrowser`
    /// probe. Cheap (one-shot, ≤1.5s timeout) but we still gate
    /// behind the poller's not-granted check so we don't churn on
    /// happy systems.
    private func refreshLocalNetwork() async {
        let status = await LocalNetwork.probe()
        await MainActor.run { localNetworkStatus = status }
    }

    /// 5-second poller that re-runs both permission checks while
    /// the Preferences window is open. Skips the cheap re-checks
    /// when both permissions are already granted (don't burn CPU
    /// for nothing). The Accessibility re-check is synchronous +
    /// instant; the Local Network probe takes ≤1.5s but only fires
    /// when the previous result wasn't `.granted`. Net effect: when
    /// the user grants a permission in System Settings while this
    /// window is open, the green checkmark appears within ~5s
    /// without any user action.
    private func startPermissionPoller() {
        permissionPollerTask?.cancel()
        // Kick off an immediate Local Network probe so the row
        // doesn't sit at "checking…" for 5s before the first poll
        // tick.
        Task { await refreshLocalNetwork() }
        permissionPollerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                let acc = Accessibility.isTrusted()
                if acc != accessibilityGranted { accessibilityGranted = acc }
                if localNetworkStatus != .granted {
                    await refreshLocalNetwork()
                }
            }
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

    /// Manually run a link-title backfill from Preferences. Same
    /// runOnce path the daemon uses, but with a much larger batch
    /// (5000) so a one-shot user-initiated run sweeps the whole
    /// pending set. `force` clears the fetched_at sentinels first
    /// so even already-attempted links retry.
    private func runLinkBackfill(force: Bool) {
        linkBackfillStatus = force ? "Refetching…" : "Fetching…"
        Task.detached {
            do {
                let store = try Store.open()
                let repo = EntryRepository(store: store)
                if force {
                    try repo.resetLinkFetchedAt()
                }
                let backfiller = LinkMetadataBackfiller(repository: repo)
                let report = try await backfiller.runOnce(limit: 5000, force: force)
                let summary = report.attempted == 0
                    ? "Nothing to fetch."
                    : "Fetched \(report.successes) of \(report.attempted) (· \(report.emptyResults) blank · \(report.failures) failed)."
                await MainActor.run { linkBackfillStatus = summary }
            } catch {
                await MainActor.run { linkBackfillStatus = "Failed: \(error)" }
            }
        }
    }

    /// Targeted retry for the "I bulk-backfilled, hit YouTube's rate
    /// limit, now half my links are empty" scenario. Clears the
    /// fetched_at sentinel ONLY on rows whose link_title is null/
    /// empty — successful rows are untouched, so the network only
    /// re-hits the URLs that didn't work last time.
    private func runLinkBackfillRetryEmpty() {
        linkBackfillStatus = "Retrying empties…"
        Task.detached {
            do {
                let store = try Store.open()
                let repo = EntryRepository(store: store)
                let cleared = try repo.resetLinkFetchedAtForEmptyTitles()
                if cleared == 0 {
                    await MainActor.run { linkBackfillStatus = "Nothing to retry — all attempted links have titles." }
                    return
                }
                let backfiller = LinkMetadataBackfiller(repository: repo)
                let report = try await backfiller.runOnce(limit: 5000)
                let summary = "Retried \(cleared): \(report.successes) succeeded · \(report.emptyResults) still blank · \(report.failures) failed."
                await MainActor.run { linkBackfillStatus = summary }
            } catch {
                await MainActor.run { linkBackfillStatus = "Failed: \(error)" }
            }
        }
    }

    /// "Import URLs…" — NSOpenPanel for a .txt, then run the shared
    /// `UrlImporter` off the main thread. Imported links flow through
    /// the normal ingest path so the backfill enriches them.
    private func importURLs() {
        let panel = NSOpenPanel()
        panel.title = "Import URLs"
        panel.message = "Pick a text file with one http(s):// or file:// URL per line."
        panel.allowedContentTypes = [.plainText, .text, .utf8PlainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importExportStatus = "Importing…"
        Task.detached {
            do {
                let raw = try String(contentsOf: url, encoding: .utf8)
                let store = try Store.open()
                // Small forward-less spread: 60 s total, so the
                // batch gets distinct timestamps (stable popup
                // ordering) but stays clustered at "just now" where
                // the user looks right after an interactive import.
                // The old 3600 s backdated everything up to an hour
                // into the past, pushing fresh imports below the
                // fold so they looked missing / un-enriched.
                let r = try UrlImporter.run(rawText: raw, into: store, spreadSeconds: 60)
                let msg: String
                if r.acceptedCount == 0 {
                    msg = "No importable URLs found (\(r.rejected.count) rejected)."
                } else {
                    var parts = ["\(r.inserted) new", "\(r.bumped) bumped"]
                    if r.skipped > 0 { parts.append("\(r.skipped) skipped") }
                    if r.failed > 0 { parts.append("\(r.failed) failed") }
                    if r.rejected.count > 0 { parts.append("\(r.rejected.count) rejected") }
                    msg = "Imported " + parts.joined(separator: " · ") + ". Links enrich in the background."
                }
                await MainActor.run { importExportStatus = msg }
            } catch {
                await MainActor.run { importExportStatus = "Import failed: \(error.localizedDescription)" }
            }
        }
    }

    /// "Export…" — NSSavePanel pre-filled with a sensible name +
    /// the picked format's extension, then render via the shared
    /// `HistoryExporter` off the main thread.
    private func exportHistory() {
        let fmt = exportFormat
        let panel = NSSavePanel()
        panel.title = "Export Clipboard History"
        let stamp = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current,
            formatOptions: [.withFullDate]
        )
        panel.nameFieldStringValue = "cpdb-export-\(stamp).\(fmt.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importExportStatus = "Exporting…"
        Task.detached {
            do {
                let store = try Store.open()
                let (doc, count) = try HistoryExporter.export(from: store, format: fmt)
                try doc.write(to: url, atomically: true, encoding: .utf8)
                await MainActor.run {
                    importExportStatus = "Exported \(count) entries → \(url.lastPathComponent)"
                }
            } catch {
                await MainActor.run { importExportStatus = "Export failed: \(error.localizedDescription)" }
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
