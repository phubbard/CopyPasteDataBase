#if os(iOS)
import Foundation
import Observation
import GRDB
import BackgroundTasks
import CpdbShared
import CpdbCore
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

    /// Undo/redo for delete + pin (shared logic in CpdbShared). Created
    /// once the store opens; SearchView drives it and shows the undo
    /// snackbar. nil until `bootstrap` runs.
    private(set) var undo: UndoCoordinator?
    private var syncer: CloudKitSyncer?

    /// iOS clipboard capture controller. Built during `bootstrap()` once
    /// the store + local device row exist. Nil until then (and capture
    /// no-ops). Routes through the shared `Ingestor` — see
    /// `IOSClipboardCapture`.
    private var capture: IOSClipboardCapture?

    /// UserDefaults key for the capture-on-this-device toggle. Default
    /// OFF. The Settings UI reads/writes this via `@AppStorage`; the
    /// container reads it directly to gate ALL capture (both the manual
    /// "Save clipboard now" action and the optional capture-on-foreground
    /// path honor it). Manual save is allowed only when the toggle is on,
    /// matching the "capture is opt-in per device" model.
    static let captureEnabledKey = "cpdb.ios.captureEnabled"

    /// Whether clipboard capture is enabled on this device. Reads the same
    /// UserDefaults key the Settings toggle writes.
    var isCaptureEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.captureEnabledKey)
    }

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
    /// True when the last pull/push came back `gated` (an identity
    /// cutover is pending or mid-run) rather than genuinely idle. The
    /// UI must not read this as "up to date" — see `pullNow`.
    private(set) var syncGated: Bool = false

    /// canonical-hash v2 identity cutover state, published so SearchView
    /// / AboutSheet can show progress instead of pretending sync is
    /// healthy while it's silently gated. iOS never ran the cutover
    /// before this fix (only Mac AppDelegate / the CLI did), so a phone
    /// with `cutover_pending` set by the schema migration would spin
    /// forever with sync gated and no explanation — see `runIdentityCutoverIfNeeded`.
    enum MigrationState: Equatable {
        case idle
        case running(String)
        case failed(String)
    }
    private(set) var migrationState: MigrationState = .idle
    /// Guards against stacking multiple cutover attempts if scenePhase
    /// flips .active several times in a row (e.g. backgrounded mid-run,
    /// foregrounded again quickly). Cleared when the in-flight attempt
    /// finishes, so the NEXT foreground can retry if it failed or was
    /// interrupted — the cutover is resumable (chunked rehash cursor
    /// persists), so re-attempting is safe and bounded by "one attempt
    /// per foreground transition", not a hot loop.
    private var cutoverTask: Task<Void, Never>?

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
            self.undo = UndoCoordinator(repo: EntryRepository(store: store))
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
            // Build the clipboard-capture controller. Upserts the local
            // iOS `devices` row (kind="ios") so captured entries carry a
            // real `source_device_id`, then wires the shared `Ingestor`.
            // Capture still no-ops unless the user enabled the toggle —
            // this just makes the machinery ready.
            do {
                let localDeviceId = try Self.ensureLocalIOSDevice(
                    in: store, identifier: deviceID, name: deviceName
                )
                let ingestor = Ingestor(store: store)
                self.capture = IOSClipboardCapture(
                    ingestor: ingestor, deviceId: localDeviceId
                )
                print("[cpdb] bootstrap: capture controller ready (deviceRow=\(localDeviceId))")
            } catch {
                // Non-fatal: read-only sync still works without capture.
                print("[cpdb] bootstrap: capture setup failed: \(error)")
            }
            // Kick the 30 s foreground poll once the DB + syncer are
            // ready. scenePhase may have already moved to .active
            // before bootstrap completed (its guard on `store != nil`
            // would have skipped); catch that case here.
            startForegroundPolling()
            // Re-schedule BGAppRefreshTask every launch — iOS forgets
            // on reboot and after failed runs.
            scheduleBackgroundRefresh()
            // Fire-and-forget: if this DB still needs the canonical-hash
            // v2 cutover, run it now. Non-blocking — the pull below will
            // simply come back `gated` until it finishes, and SearchView
            // shows `migrationState` in the meantime.
            runIdentityCutoverIfNeeded()
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

    // MARK: - Identity cutover (canonical-hash v2)

    /// Run the canonical-hash v2 identity cutover if this database still
    /// needs it. Bug context: the schema migration seeds
    /// `cutover_pending` on any DB with existing rows, but historically
    /// only `AppDelegate` (Mac) and the `cpdb migrate-identity` CLI ever
    /// called `IdentityCutover.run` — the iOS app never did, so
    /// `CloudKitSyncer` silently gated push/pull forever on the phone
    /// with no error and no UI signal.
    ///
    /// No-ops if a run is already in flight (`cutoverTask != nil`) or the
    /// store/syncer aren't ready yet. Safe to call repeatedly — cheap
    /// once the cutover is done (`isPending` short-circuits to `false`).
    func runIdentityCutoverIfNeeded() {
        guard let store = store else { return }
        guard cutoverTask == nil else { return }
        cutoverTask = Task { [weak self] in
            defer { self?.cutoverTask = nil }
            guard let self else { return }
            // `AppContainer` is @MainActor, so this `Task` inherits that
            // isolation — `IdentityCutover.isPending(store)` performs a
            // synchronous `dbQueue.read`, which would otherwise block the
            // main thread behind any in-flight write transaction (e.g. a
            // pull applying a page of CKAsset flavor bytes) on every
            // foreground activation, forever, even long after the cutover
            // is done. Hop off the main actor for the read itself.
            let pending: Bool
            do {
                pending = try await store.dbQueue.read { try IdentityCutover.isPending($0) }
            } catch {
                pending = false
            }
            guard pending else { return }

            // Wrap the run in a background task so getting backgrounded
            // mid-cutover buys extra time instead of getting frozen
            // immediately. The cutover persists its rehash cursor after
            // every ~200-row chunk, so if iOS still kills us before we
            // finish, resuming on the next foreground is safe — we just
            // lose the extra time, not correctness.
            #if canImport(UIKit)
            var bgTaskId: UIBackgroundTaskIdentifier = .invalid
            bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "cpdb-identity-cutover") {
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
            defer {
                if bgTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskId)
                }
            }
            #endif

            self.migrationState = .running("starting")
            let snapshotURL = IdentityCutover.defaultSnapshotURL(forDatabaseAt: Paths.databaseURL.path)
            do {
                let outcome = try await IdentityCutover.run(
                    store: store,
                    // iOS is a pure CloudKit replica — the cloud is its
                    // recovery path, so a low-storage phone must not be
                    // bricked (stuck cutover_pending forever) by a
                    // VACUUM INTO that can't find room for a second copy
                    // of the database.
                    snapshotURL: snapshotURL,
                    snapshotPolicy: .bestEffort,
                    // Nothing to drain: iOS never pushes to the old
                    // cpdb-v2 zone (there's no legacy push path here),
                    // and the reseed in step 5 subsumes any local edits
                    // anyway. Mirrors the Mac's `drainPushQueue: nil`.
                    drainPushQueue: nil,
                    progress: { text in
                        Task { @MainActor [weak self] in self?.migrationState = .running(text) }
                    }
                )
                print("[cpdb] identity cutover outcome: \(outcome)")
                switch outcome {
                case .completed:
                    self.migrationState = .idle
                    // A full pull clears the pull-before-push latch the
                    // cutover set and stamps lastSuccessAt — do it now
                    // rather than waiting for the next poll tick.
                    await self.pullNow()
                case .notNeeded, .blockedOnPushQueue, .alreadyRunning:
                    self.migrationState = .idle
                }
            } catch {
                Self.logError("identity cutover", error)
                self.migrationState = .failed("\(error)")
                self.lastError = "Library upgrade failed — will retry"
            }
        }
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
                if push.gated {
                    // Don't clear syncGated here — a paired pullNow()
                    // call (the common case; pushNow is usually invoked
                    // FROM pullNow) will set the user-visible state.
                    syncGated = true
                    break
                }
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
            let report = try await syncer.pullRemoteChanges { page in
                // Called after every page of the pull. Hop back to the
                // main actor to update @Observable state — the progress
                // callback closure runs on the syncer's actor context.
                Task { @MainActor [weak self] in
                    self?.pullProgress = page
                }
            }
            lastPull = report
            if report.gated {
                // A gated report means sync did NOTHING — an identity
                // cutover is pending or mid-run. Must not be read as "up
                // to date": surface it distinctly so the UI tells the
                // truth instead of showing a stale "Last sync" as fresh.
                syncGated = true
                lastError = "Library upgrade pending — sync paused"
            } else {
                syncGated = false
                lastError = nil
            }
            print("[cpdb] pull: inserted=\(report.inserted) updated=\(report.updated) tombstoned=\(report.tombstoned) skipped=\(report.skipped) gated=\(report.gated)")
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

    // MARK: - Capture

    /// Manual "Save clipboard now" action, invoked from the UI. Honors the
    /// capture toggle (no-op when disabled) and pushes the result so the
    /// new entry syncs to the user's other devices immediately.
    ///
    /// Banner note: this reads the pasteboard (after a `detectPatterns`
    /// gate), which shows the system paste banner — expected and
    /// acceptable because the user explicitly tapped "Save".
    @MainActor
    func saveClipboardNow() async {
        guard isCaptureEnabled else {
            print("[cpdb] capture: save requested but capture disabled")
            return
        }
        await runCapture(trigger: "manual")
    }

    /// Optional capture-on-foreground. Called from the scene-activation
    /// handler ONLY when the toggle is on. Same gated path as the manual
    /// save; the `detectPatterns` gate means a foreground activation with
    /// nothing new on the clipboard reads nothing and shows no banner.
    @MainActor
    func captureOnForegroundIfEnabled() async {
        guard isCaptureEnabled else { return }
        await runCapture(trigger: "foreground")
    }

    @MainActor
    private func runCapture(trigger: String) async {
        guard let capture = capture else {
            print("[cpdb] capture: controller not ready")
            return
        }
        let result = await capture.captureCurrentClipboard()
        switch result {
        case .inserted(let id):
            print("[cpdb] capture(\(trigger)): inserted \(id)")
        case .bumped(let id):
            print("[cpdb] capture(\(trigger)): bumped \(id)")
        case .skipped(let reason):
            print("[cpdb] capture(\(trigger)): skipped — \(reason)")
        }
        // Push so the capture reaches the user's other devices now rather
        // than waiting for the next periodic tick.
        if IOSClipboardCapture.isPushable(result) {
            await pushNow()
        }
    }

    /// Upsert the local iOS device row and return its row id. Mirrors the
    /// Mac's `DeviceIdentity.ensureLocalDevice` but with `kind: "ios"` and
    /// the UIDevice-derived identifier/name already resolved by the
    /// caller. iOS has no IOKit, so this lives here rather than in the
    /// shared `DeviceIdentity` enum (which is macOS-only).
    private static func ensureLocalIOSDevice(
        in store: Store, identifier: String, name: String
    ) throws -> Int64 {
        try store.dbQueue.write { db in
            if let existing = try Device
                .filter(Column("identifier") == identifier)
                .fetchOne(db) {
                return existing.id!
            }
            var row = Device(identifier: identifier, name: name, kind: "ios")
            try row.insert(db)
            return row.id!
        }
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
