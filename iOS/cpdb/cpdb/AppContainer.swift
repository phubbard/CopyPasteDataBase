#if os(iOS)
import Foundation
import Observation
import GRDB
import BackgroundTasks
import CpdbShared
#if canImport(UIKit)
import UIKit
#endif

/// Long-lived singleton wiring the iOS app's data layer.
///
/// Opens the shared `Store`, builds a `CloudKitSyncer`, and exposes a
/// couple of convenience methods to the views (pull-now, status). The
/// Mac app splits these responsibilities across `AppDelegate` +
/// `DaemonLifecycle`; on iOS there's no daemon, so everything lives
/// in this single container.
///
/// `@Observable` so SwiftUI views re-render when `syncReport` changes.
/// Views read the counts without holding a separate @State copy.
@Observable
@MainActor
final class AppContainer {
    /// Process-wide handle so the UIKit AppDelegate (which exists
    /// outside the SwiftUI environment) can reach us from silent-push
    /// callbacks. Weak so a scene tear-down doesn't keep us pinned.
    static weak var shared: AppContainer?

    private(set) var store: Store?
    private var syncer: CloudKitSyncer?

    /// Monotonic token that ticks whenever the `entries` table changes
    /// (local insert, CloudKit pull, remote tombstone). SearchView
    /// observes this via `.onChange` and re-runs its query, giving us
    /// live updates while the app is in the foreground — the iOS
    /// equivalent of the Mac popup's GRDB-driven refresh loop.
    private(set) var dbChangeToken: Int = 0
    private var entriesObservation: (any DatabaseCancellable)?

    /// Foreground polling task. Runs a pull every N seconds while
    /// the app is on-screen. Silent push + scene-activation pulls
    /// handle most cases, but APNs throttles freshly-installed apps
    /// for days and scene-activation only fires on the .active
    /// *transition* — if the user just sits in the app, nothing
    /// else triggers a pull. Cancelled when the scene goes away.
    private var foregroundPollTask: Task<Void, Never>?
    /// Interval between foreground polls. 30s is a reasonable floor
    /// — CloudKit's pull is a single HTTP round-trip for a
    /// no-change case, cheap on battery, and the user's experience
    /// of "open the app, see latest" feels instant at 30s.
    private static let foregroundPollInterval: TimeInterval = 30

    /// Identifier for our `BGAppRefreshTask`. Must match the value
    /// declared in the iOS app's Info.plist under
    /// `BGTaskSchedulerPermittedIdentifiers` — the Xcode project sets
    /// this via `INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers`.
    ///
    /// Hard-coded to the iOS app's bundle ID (not `Paths.bundleId`,
    /// which is the shared `net.phfactor.cpdb` — wrong suffix for
    /// the iOS app). Keep in sync with the pbxproj build setting.
    static let bgRefreshTaskID = "net.phfactor.cpdb.ios.refresh"

    /// Latest sync state for the progress indicator in SearchView's
    /// toolbar. Nil until the first pull completes.
    private(set) var lastPull: CloudKitSyncer.PullReport?
    private(set) var isSyncing: Bool = false
    private(set) var lastError: String?

    /// Running cumulative totals during an in-flight pull — published
    /// per page via the syncer's progress callback so SearchView can
    /// render a live counter. Nil between pulls.
    private(set) var pullProgress: CloudKitSyncer.PullReport?
    /// Wall-clock start of the current pull. Used with `pullProgress`
    /// to compute elapsed time and an overall rate.
    private(set) var pullStartedAt: Date?

    /// Called from CpdbiOSApp.task on first launch. Idempotent — if
    /// already bootstrapped, no-op.
    func bootstrap() async {
        Self.shared = self
        guard store == nil else { return }
        print("[cpdb] bootstrap: starting")
        do {
            let store = try Store.open()
            self.store = store
            print("[cpdb] bootstrap: store open at \(Paths.databaseURL.path)")
            let deviceID = await Self.iosDeviceIdentifier()
            let deviceName = await Self.iosDeviceName()
            print("[cpdb] bootstrap: device id=\(deviceID) name=\(deviceName)")
            let client = LiveCloudKitClient(containerIdentifier: "iCloud.\(Paths.bundleId)")
            let syncer = CloudKitSyncer(
                store: store,
                client: client,
                device: .init(identifier: deviceID, name: deviceName)
            )
            self.syncer = syncer
            print("[cpdb] bootstrap: ensuring zone subscription…")
            try await syncer.ensureSubscription()
            // Start observing the DB so SearchView can live-update as
            // new entries land (from silent-push pulls or future local
            // capture paths). Stopped never — the observation is
            // cheap and we want it running for the app's lifetime.
            startLiveUpdates()
            // Kick the 30 s foreground poll once the DB + syncer are
            // ready. scenePhase may have already moved to .active
            // before bootstrap completed (its guard on `store != nil`
            // would have skipped); catch that case here.
            startForegroundPolling()
            // Re-schedule BGAppRefreshTask every launch — iOS forgets
            // on reboot and after failed runs.
            scheduleBackgroundRefresh()
            print("[cpdb] bootstrap: subscription OK, pulling…")
            await pullNow()
            print("[cpdb] bootstrap: complete")
        } catch {
            lastError = "\(error)"
            Self.logError("bootstrap", error)
        }
    }

    /// Ask the user's target Mac to paste the given entry by writing
    /// an ActionRequest CKRecord to the shared zone. The Mac's syncer
    /// consumes the request on its next pull (or silent push) and
    /// writes the entry's flavors to its NSPasteboard; the user on
    /// that Mac then presses ⌘V to paste. Throws on CloudKit error.
    func sendPasteRequest(
        entryContentHash: Data,
        targetDeviceIdentifier: String
    ) async throws {
        guard let syncer = syncer else {
            throw NSError(
                domain: "cpdb.ios",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Sync not ready"]
            )
        }
        try await syncer.sendPasteRequest(
            entryContentHash: entryContentHash,
            targetDeviceIdentifier: targetDeviceIdentifier
        )
    }

    // MARK: - Live updates

    /// Subscribe to changes on the `entries` table so SearchView can
    /// re-query automatically whenever something lands in the DB —
    /// silent-push pulls, pull-to-refresh, or a future local-capture
    /// path. The subscription stays alive for the app's lifetime;
    /// it's cheap and there's no moment when we wouldn't want the UI
    /// to reflect the current DB.
    ///
    /// We don't read the observed value — SearchView re-runs its own
    /// query off `dbChangeToken` changing. Tracking a cheap projection
    /// just gives GRDB a handle to coalesce writes into one signal.
    private func startLiveUpdates() {
        guard entriesObservation == nil, let store = store else { return }
        let obs = ValueObservation.tracking { db in
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL"
            ) ?? 0
            let maxCreated = try Double.fetchOne(
                db, sql: "SELECT MAX(created_at) FROM entries WHERE deleted_at IS NULL"
            ) ?? 0
            return LiveSignal(count: count, maxCreated: maxCreated)
        }
        entriesObservation = obs.start(
            in: store.dbQueue,
            scheduling: .immediate,
            onError: { error in
                print("[cpdb] live updates errored: \(error)")
            },
            onChange: { [weak self] _ in
                Task { @MainActor in
                    self?.dbChangeToken &+= 1
                }
            }
        )
    }

    /// Equatable projection so GRDB suppresses duplicate change
    /// notifications — e.g. flavor-only writes that don't touch
    /// `entries` stats.
    private struct LiveSignal: Equatable {
        let count: Int
        let maxCreated: Double
    }

    // MARK: - Foreground polling

    /// Start a recurring `pullNow()` tick while the app is active.
    /// Idempotent — calling twice leaves a single live task.
    func startForegroundPolling() {
        guard foregroundPollTask == nil, store != nil else { return }
        print("[cpdb] fg-poll: start (every \(Int(Self.foregroundPollInterval))s)")
        foregroundPollTask = Task { [weak self] in
            let interval = UInt64(Self.foregroundPollInterval * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { return }
                print("[cpdb] fg-poll: tick")
                await self?.pullNow()
            }
        }
    }

    /// Stop the foreground poll loop. Called from scene-phase
    /// handling when we leave `.active`, and implicitly on app
    /// teardown.
    func stopForegroundPolling() {
        foregroundPollTask?.cancel()
        foregroundPollTask = nil
    }

    // MARK: - Background refresh

    /// Register the BGAppRefreshTask handler. Called once, from the
    /// iOSAppDelegate's `didFinishLaunchingWithOptions` — iOS requires
    /// all task handlers to be registered before the app finishes
    /// launch, so we can't do this lazily from `bootstrap()`.
    static func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: bgRefreshTaskID,
            using: nil
        ) { task in
            Task { @MainActor in
                await Self.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
            }
        }
    }

    /// Ask iOS to grant us ~30 s of background CPU time at some point
    /// in the next ~15 min. iOS decides when based on usage patterns,
    /// charging state, etc. — this is the "catch-up" safety net for
    /// periods where silent pushes either weren't delivered or the
    /// app was fully suspended when they fired.
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgRefreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[cpdb] bgrefresh: scheduled")
        } catch {
            // Common when running in the simulator or when iOS has
            // throttled us — not fatal, foreground pulls still work.
            print("[cpdb] bgrefresh: schedule failed: \(error)")
        }
    }

    @MainActor
    private static func handleBackgroundRefresh(task: BGAppRefreshTask) async {
        // ALWAYS re-submit the next request before we can get cancelled —
        // iOS stops granting future slots if we ever let the chain
        // break without scheduling a successor.
        Self.shared?.scheduleBackgroundRefresh()

        // Wire the expiration handler so we exit cleanly if iOS cuts
        // us off mid-pull (the pull runs async and may outlast our
        // budget on a slow network).
        task.expirationHandler = {
            // Don't cancel the pull — it's safe to let it finish in
            // the background; we just tell iOS we're done so our next
            // scheduling request doesn't get downgraded.
            task.setTaskCompleted(success: false)
        }

        guard let container = Self.shared else {
            task.setTaskCompleted(success: false)
            return
        }
        let before = container.lastPull?.inserted ?? 0
        await container.pullNow()
        let after = container.lastPull?.inserted ?? 0
        print("[cpdb] bgrefresh: fired, newData=\(after > before)")
        task.setTaskCompleted(success: true)
    }

    // MARK: - Sync

    /// Drain any outbound work (tombstones created by the user's
    /// swipe-delete action, future iOS-side captures) in a single
    /// loop. Runs before every `pullNow` so a pull-to-refresh /
    /// foreground poll also catches up the push queue — same
    /// contract the Mac's periodic loop has. Idempotent and cheap
    /// when the queue is empty.
    func pushNow() async {
        guard let syncer = syncer else { return }
        do {
            while true {
                let push = try await syncer.pushPendingChanges()
                if push.attempted > 0 {
                    print("[cpdb] push: attempted=\(push.attempted) saved=\(push.saved) failed=\(push.failed) remaining=\(push.remaining)")
                }
                // Drain multiple batches so a burst of deletes from
                // `cpdb dedupe`-equivalent flows (or quick successive
                // swipe-deletes) doesn't need multiple foreground
                // poll cycles to clear. Stop when nothing left OR
                // we're making no progress (failed > 0 && remaining
                // > 0 — avoid spinning on a permanent error).
                if push.remaining == 0 || push.attempted == 0 || push.failed > 0 {
                    break
                }
            }
        } catch {
            print("[cpdb] push failed: \(error)")
            lastError = "\(error)"
        }
    }

    /// Force a pull. Called on pull-to-refresh and from the toolbar.
    /// Runs a push first so local changes (tombstones from swipe-
    /// delete) drain to CloudKit before we poll for remote changes
    /// — keeps both directions flowing through one code path.
    func pullNow() async {
        await pushNow()
        guard let syncer = syncer else { return }
        isSyncing = true
        pullStartedAt = Date()
        pullProgress = CloudKitSyncer.PullReport(
            inserted: 0, updated: 0, tombstoned: 0, skipped: 0, moreComing: true
        )
        defer {
            isSyncing = false
            pullProgress = nil
            pullStartedAt = nil
        }
        do {
            let report = try await syncer.pullRemoteChanges { [weak self] page in
                // Called after every page of the pull. Hop back to the
                // main actor to update @Observable state — the progress
                // callback closure runs on the syncer's actor context.
                Task { @MainActor in
                    self?.pullProgress = page
                }
            }
            lastPull = report
            lastError = nil
            print("[cpdb] pull: inserted=\(report.inserted) updated=\(report.updated) tombstoned=\(report.tombstoned) skipped=\(report.skipped)")
        } catch {
            lastError = "\(error)"
            Self.logError("pull", error)
        }
    }

    /// Dump a full error description to stdout so the Xcode console
    /// shows it verbatim. CloudKit errors hide their actual cause
    /// behind layered userInfo dicts — we walk the
    /// `NSUnderlyingErrorKey` chain and print every domain/code/reason
    /// we can find. Output is plain `print()` (not `os_log`) so it's
    /// easy to select + copy from the Xcode console.
    private static func logError(_ context: String, _ error: any Error) {
        print("================ [cpdb] \(context) FAILED ================")
        print("error: \(error)")
        var current: NSError = error as NSError
        var depth = 0
        while true {
            print("--- level \(depth) ---")
            print("  domain: \(current.domain)")
            print("  code:   \(current.code)")
            print("  desc:   \(current.localizedDescription)")
            if let reason = current.localizedFailureReason {
                print("  reason: \(reason)")
            }
            if let suggestion = current.localizedRecoverySuggestion {
                print("  suggestion: \(suggestion)")
            }
            if !current.userInfo.isEmpty {
                print("  userInfo keys: \(Array(current.userInfo.keys).sorted())")
                for key in current.userInfo.keys.sorted() where key != NSUnderlyingErrorKey {
                    print("    \(key) = \(String(describing: current.userInfo[key]).prefix(500))")
                }
            }
            guard let under = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = under
            depth += 1
            if depth > 6 { break }
        }
        print("==========================================================")
    }

    // MARK: - Device identity

    /// iOS's equivalent of the Mac's IOPlatformUUID. Uses
    /// UIDevice.identifierForVendor when available — stable within a
    /// vendor's apps on the same device. Falls back to a
    /// UserDefaults-stored UUID if the vendor identifier isn't
    /// available (rare).
    private static func iosDeviceIdentifier() async -> String {
        #if canImport(UIKit)
        if let id = await MainActor.run(body: { UIDevice.current.identifierForVendor?.uuidString }) {
            return id
        }
        #endif
        let key = "cpdb.ios.deviceIdentifier"
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    /// Human-readable device name. Shown on the Mac in entry detail
    /// ("captured on Paul's iPhone"). iOS 16+ restricts
    /// `UIDevice.current.name` to the app name unless you have the
    /// appropriate entitlement, so the actual device name is only
    /// available via identifierForVendor or model descriptor.
    private static func iosDeviceName() async -> String {
        #if canImport(UIKit)
        return await MainActor.run { UIDevice.current.name }
        #else
        return "iOS device"
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif
#endif
