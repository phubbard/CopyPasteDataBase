import AppKit
import CloudKit
import CpdbCore
import CpdbShared
import KeyboardShortcuts

/// Central coordinator for the menu-bar app. Owns the status item, the
/// popup, the in-process capture watcher, and their lifetimes.
///
/// Kept intentionally small — each responsibility lives in its own type and
/// is strung together here.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private let lifecycle = DaemonLifecycle()
    private(set) var store: Store?
    private var syncer: CloudKitSyncer?
    private var periodicSyncTask: Task<Void, Never>?
    /// NotificationCenter token for `.cpdbLocalEntryIngested`. We
    /// subscribe once the syncer is ready; handler triggers an
    /// immediate push so a new capture lands in CloudKit within
    /// seconds instead of waiting for the 5-minute timer.
    private var ingestedObserver: NSObjectProtocol?
    /// NotificationCenter token for the image-analysis sweep's capture-
    /// wake observer (also `.cpdbLocalEntryIngested`, filtered to image
    /// kinds). See `ingestedObserver`'s registration site for why this
    /// is a separate observer rather than folded into that one.
    private var imageSweepIngestedObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.cli.info("cpdb.app starting (pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public))")

        // Single-instance guard. The status item is sticky — every
        // running copy of cpdb.app installs its own menu-bar icon, and
        // a botched relaunch (deploy.sh's `open -a` on top of a still-
        // running 19:52 copy, or repeated Xcode runs) leaves multiple
        // glyphs in the bar with no obvious way to tell them apart.
        // Belt-and-braces with the DaemonLock (which only protects the
        // capture writer, not the GUI shell): if any other process
        // shares our bundle id, terminate it (graceful first, force
        // after a beat) before we proceed. The lock then arbitrates
        // who owns the writer role as usual.
        terminateOtherInstances()

        // Subscribe to frontmost-app activations BEFORE we start the
        // PasteboardWatcher, so the 5 s sliding window is already
        // populated when the first clipboard event fires.
        FrontmostAppMonitor.warmUp()

        var captureMode: PopupState.CaptureMode = .capturing
        do {
            self.store = try lifecycle.start()
            switch lifecycle.mode {
            case .capturing:
                Log.cli.info("capture mode: writer")
                captureMode = .capturing
            case .readOnly(let pid, let owner):
                Log.cli.warning("capture mode: read-only (held by \(owner, privacy: .public) pid \(pid, privacy: .public))")
                captureMode = .readOnly(holder: "\(owner) pid \(pid)")
            case .notStarted:
                Log.cli.error("daemon lifecycle did not start")
            }
        } catch {
            Log.cli.error("daemon lifecycle failed to start: \(String(describing: error), privacy: .public)")
        }

        if let store = store {
            PopupController.shared.configure(store: store, captureMode: captureMode)
            AboutWindowController.shared.configure(store: store)
            PreferencesWindowController.shared.configure(store: store)
            // canonical-hash v2: run the identity cutover (if this DB still
            // needs it) off the main actor, then heal any skew rows. Sync
            // stays gated until it completes (CloudKitSyncer checks
            // cutover_pending). Capturing-mode only — in read-only mode
            // another process owns DB writes and will run it.
            runIdentityCutoverIfNeeded(store: store)
        }

        statusItem = StatusItemController()

        // Arm Sparkle. Constructing `.shared` starts the daily
        // background check timer; `start()` just logs the intent.
        // No-op when launched from a non-bundle context (SPM run),
        // which the headless CLI never does anyway.
        UpdaterController.shared.start()

        // Register the global hotkey handler. KeyboardShortcuts handles the
        // actual key registration via Carbon / AppKit — we just hand it a
        // closure to run whenever the user's chosen combo fires.
        KeyboardShortcuts.onKeyDown(for: .summonPopup) { [weak self] in
            self?.handleSummonPopup()
        }

        // Reflect initial "no hotkey set" state on the status item.
        refreshFirstRunBadge()
        // Re-check whenever the user changes the binding in Preferences.
        NotificationCenter.default.addObserver(
            forName: .init("KeyboardShortcuts_shortcutByNameDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFirstRunBadge() }
        }
        // If a paste attempt discovers missing Accessibility permission,
        // steer the user to Preferences immediately.
        NotificationCenter.default.addObserver(
            forName: .cpdbNeedsAccessibility,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in PreferencesWindowController.shared.show() }
        }

        // First-launch nudge: no hotkey set at all means they've never
        // opened Preferences. Surface the window once on first launch so
        // they know where to go.
        if KeyboardShortcuts.getShortcut(for: .summonPopup) == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                PreferencesWindowController.shared.show()
            }
        }

        // Kick off CloudKit sync. Only runs if the user has an iCloud
        // account; no-op in capturing-mode daemons that happen not to be
        // signed in. Pull path (step 5) isn't wired yet — this just
        // drains the push queue on launch and every 5 minutes.
        if let store = store, lifecycle.mode == .capturing {
            startCloudKitSync(store: store)
        }
        // After sync init, so this can't race the identity-cutover
        // sequence above.
        runGcZoneRequestIfArmed()

        // "Sync Now" menu item → pull-then-push.
        NotificationCenter.default.addObserver(
            forName: .cpdbSyncNow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let syncer = self?.syncer else {
                    Log.cli.info("sync now: syncer not running (no iCloud account or read-only mode)")
                    return
                }
                do {
                    let pull = try await syncer.pullRemoteChanges()
                    Log.cli.info(
                        "sync now pull: inserted=\(pull.inserted) updated=\(pull.updated) tombstoned=\(pull.tombstoned) skipped=\(pull.skipped) gated=\(pull.gated, privacy: .public)"
                    )
                    let push = try await syncer.pushPendingChanges()
                    Log.cli.info(
                        "sync now push: attempted=\(push.attempted) saved=\(push.saved) failed=\(push.failed) remaining=\(push.remaining) gated=\(push.gated, privacy: .public)"
                    )
                } catch {
                    Log.cli.error("sync now failed: \(String(describing: error), privacy: .public)")
                }
            }
        }

        // "Pull from iCloud" → pull path only.
        NotificationCenter.default.addObserver(
            forName: .cpdbPullNow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let syncer = self?.syncer else { return }
                do {
                    let pull = try await syncer.pullRemoteChanges()
                    Log.cli.info(
                        "pull now: inserted=\(pull.inserted) updated=\(pull.updated) tombstoned=\(pull.tombstoned) skipped=\(pull.skipped) gated=\(pull.gated, privacy: .public)"
                    )
                } catch {
                    Log.cli.error("pull now failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Run the canonical-hash v2 identity cutover off the main actor at
    /// launch, if this database still needs it, then heal any binary-skew
    /// rows. Sync is gated on `cutover_pending`, so it stays silent until
    /// this finishes; we post `.cpdbSyncNow` afterward to re-enable
    /// promptly instead of waiting for the periodic poll. The cross-process
    /// `cutover.lock` makes this mutually exclusive with a `cpdb
    /// migrate-identity` CLI run (whichever fires first wins; the other
    /// no-ops).
    private func runIdentityCutoverIfNeeded(store: Store) {
        guard lifecycle.mode == .capturing else { return }
        let snapshotURL = IdentityCutover.defaultSnapshotURL(forDatabaseAt: Paths.databaseURL.path)
        Task.detached(priority: .utility) {
            do {
                if try IdentityCutover.isPending(store) {
                    Log.cli.info("identity cutover pending — running at launch")
                    let outcome = try await IdentityCutover.run(
                        store: store,
                        snapshotURL: snapshotURL,
                        // Primary device's queue is drained before upgrade;
                        // a non-empty queue blocks safely. The gate-bypassing
                        // legacy-zone drain for secondary devices is a
                        // follow-up.
                        drainPushQueue: nil,
                        progress: { Log.cli.info("cutover: \($0, privacy: .public)") }
                    )
                    Log.cli.info("identity cutover outcome: \(String(describing: outcome), privacy: .public)")
                }
                // Heal skew-era v1 rows (no-op in the normal case).
                _ = try IdentityCutover.reconcileSweep(store: store)
                // Re-enable sync now that the cutover (if any) is done.
                await MainActor.run {
                    NotificationCenter.default.post(name: .cpdbSyncNow, object: nil)
                }
            } catch {
                Log.cli.error("identity cutover failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// One-shot `gc-zone` execution hook. Exists because the CLI
    /// process can't hold iCloud entitlements — `CKContainer` traps
    /// there — so an operator arms this via `defaults write
    /// net.phfactor.cpdb gcZoneRequest cpdb-v2 [-bool gcZoneForce
    /// true]` and relaunches the (entitled) app to actually run it.
    private func runGcZoneRequestIfArmed() {
        let defaults = UserDefaults.standard
        guard let zoneName = defaults.string(forKey: "gcZoneRequest") else { return }
        let force = defaults.bool(forKey: "gcZoneForce")
        let containerID = "iCloud.\(Paths.bundleId)"
        let client = LiveCloudKitClient(containerIdentifier: containerID)
        Task.detached(priority: .utility) {
            do {
                let outcome = try await GcZone.run(
                    zoneName: zoneName, force: force, containerID: containerID, client: client
                )
                Log.cli.info("gc-zone: \(String(describing: outcome), privacy: .public)")
            } catch {
                Log.cli.error("gc-zone: failed: \(String(describing: error), privacy: .public)")
            }
            // One-shot: clear both keys regardless of outcome so a
            // failed attempt doesn't silently re-run on every launch —
            // the operator re-arms deliberately.
            defaults.removeObject(forKey: "gcZoneRequest")
            defaults.removeObject(forKey: "gcZoneForce")
        }
    }

    private func startCloudKitSync(store: Store) {
        let containerID = "iCloud.\(Paths.bundleId)"
        let client = LiveCloudKitClient(containerIdentifier: containerID)
        let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let deviceID = DeviceIdentity.hardwareUUID() ?? ProcessInfo.processInfo.hostName
        // `onPasteAction`: the iOS companion writes an ActionRequest
        // CKRecord targeting this Mac; the syncer consumes it during
        // the next pull and invokes this closure with the local
        // Entry. Writing to NSPasteboard lives in Restorer so this
        // closure is a thin adapter. Note the escape hatch: Restorer
        // is macOS-only so we can't move it into CpdbShared, which is
        // why the syncer accepts a closure rather than calling
        // Restorer directly.
        let pasteHandler: @Sendable (Entry) async -> Void = { entry in
            guard let id = entry.id else { return }
            let restorer = Restorer(store: store)
            do {
                try restorer.restoreToPasteboard(entryId: id)
                Log.cli.info(
                    "remote paste: wrote entry \(id, privacy: .public) to NSPasteboard"
                )
            } catch {
                Log.cli.error(
                    "remote paste failed for entry \(id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        let syncer = CloudKitSyncer(
            store: store,
            client: client,
            device: .init(identifier: deviceID, name: deviceName),
            onPasteAction: pasteHandler
        )
        self.syncer = syncer

        // Wake the push loop immediately on every local capture.
        // Ingestor posts `.cpdbLocalEntryIngested` inside its write
        // transaction; we run `pushPendingChanges` right after so the
        // entry reaches CloudKit in seconds, not up to 5 minutes
        // (the periodic safety-net loop below). The syncer's
        // internal `pushing` guard coalesces simultaneous wakes, so
        // a burst of rapid captures only triggers one network trip.
        ingestedObserver = NotificationCenter.default.addObserver(
            forName: .cpdbLocalEntryIngested,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task {
                do {
                    let push = try await syncer.pushPendingChanges()
                    if push.attempted > 0 {
                        Log.cli.info(
                            "cloudkit push (wake): attempted=\(push.attempted) saved=\(push.saved) failed=\(push.failed) remaining=\(push.remaining)"
                        )
                    }
                } catch {
                    Log.cli.error("cloudkit push (wake) failed: \(String(describing: error), privacy: .public)")
                }
            }
            // Immediate small-batch link backfill — only when the
            // ingested entry was actually a link. Non-link captures
            // (text/image/file/color) used to pointlessly fire a
            // batch that re-tried the same stuck-at-the-top URLs
            // every time, hammering rate-limited hosts. The kind
            // arrives in the notification's userInfo from the
            // Ingestor's post site.
            guard let self, let store = self.store else { return }
            let kindRaw = note.userInfo?["kind"] as? String
            guard kindRaw == EntryKind.link.rawValue else { return }
            Task.detached { await Self.runLinkTitleBackfillImmediate(store: store) }
        }

        // Immediate small-batch image-analysis sweep — only when the
        // ingested entry was an image landing via `.bumped` (a repeat
        // capture of existing content, re-touched to the top of the
        // list). `.inserted` images are deliberately excluded here:
        // `Ingestor` already fires its own capture-time analysis Task
        // for every `.inserted` image, at essentially the same instant
        // this observer would fire, so sweeping on `.inserted` too just
        // races that Task and runs Vision twice on the same bytes. A
        // `.bumped` entry gets no such Task, so this is the only
        // same-Mac path that recovers it if its original capture's
        // analysis never finished (app quit mid-Vision-call, etc). The
        // other gap this sweep exists for — the app quitting mid-Vision
        // — can't be caught by THIS observer either way (the process
        // that would receive the notification is the one dying); the
        // periodic sweep's `nextDueAt = .distantPast` catches it at
        // next launch instead. A separate observer rather than folding
        // into the one above, since that one early-returns for non-link
        // kinds.
        imageSweepIngestedObserver = NotificationCenter.default.addObserver(
            forName: .cpdbLocalEntryIngested,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let store = self.store else { return }
            let kindRaw = note.userInfo?["kind"] as? String
            guard kindRaw == EntryKind.image.rawValue else { return }
            let outcomeRaw = note.userInfo?["outcome"] as? String
            guard outcomeRaw == "bumped" else { return }
            Task.detached(priority: .utility) { await Self.runImageAnalysisSweepImmediate(store: store) }
        }

        // Touch the Reachability singleton so NWPathMonitor starts
        // monitoring before the first periodic cycle fires.
        _ = Reachability.shared
        // When the OS reports we're back online (Wi-Fi reconnect,
        // VPN handshake completed, captive portal cleared), fire a
        // catch-up backfill batch immediately. Lets the queue drain
        // without waiting for the next 15-min periodic tick.
        NotificationCenter.default.addObserver(
            forName: .cpdbReachabilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let online = (note.userInfo?["isOnline"] as? Bool) ?? false
            guard online, let store = self?.store else { return }
            Log.cli.info("link-title backfill: reachability online edge, firing catch-up")
            Task.detached { await Self.runLinkTitleBackfillImmediate(store: store) }
        }

        // Register for silent push + install the zone subscription so
        // the server wakes us when another device writes. APNs is
        // granted by our `com.apple.developer.aps-environment`
        // entitlement; no user prompt.
        NSApp.registerForRemoteNotifications()
        Task.detached {
            do {
                try await syncer.ensureSubscription()
                Log.cli.info("cloudkit zone subscription installed")
            } catch {
                Log.cli.error("cloudkit subscription failed: \(String(describing: error), privacy: .public)")
            }
        }

        // Periodic loop: pull first (other devices' changes), then push
        // (our local changes). Aggressive while there's push work to
        // drain, otherwise idles for 5 minutes. APNs-delivered silent
        // pushes (handled below) trigger a pull outside this loop, so
        // this timer is just a safety net against missed notifications.
        periodicSyncTask = Task.detached { [weak self] in
            var tick: UInt64 = 0
            while !Task.isCancelled {
                tick &+= 1
                Log.cli.info("periodic tick \(tick, privacy: .public) start")
                // Backoff for the END of this tick. Default: idle the full
                // safety-net interval (nothing to do). Overridden below to
                // drain promptly while there's push work.
                var backoffSeconds = CloudKitSyncer.safetyNetIntervalSeconds
                do {
                    Log.cli.info("periodic tick \(tick, privacy: .public): pull begin")
                    let pull = try await syncer.pullRemoteChanges()
                    Log.cli.info("periodic tick \(tick, privacy: .public): pull end (inserted=\(pull.inserted) updated=\(pull.updated))")
                    if pull.inserted + pull.updated + pull.tombstoned > 0 {
                        Log.cli.info(
                            "cloudkit pull: inserted=\(pull.inserted) updated=\(pull.updated) tombstoned=\(pull.tombstoned) skipped=\(pull.skipped)"
                        )
                    }
                } catch {
                    Log.cli.error("cloudkit pull failed: \(String(describing: error), privacy: .public)")
                }
                do {
                    Log.cli.info("periodic tick \(tick, privacy: .public): push begin")
                    let push = try await syncer.pushPendingChanges()
                    Log.cli.info("periodic tick \(tick, privacy: .public): push end (attempted=\(push.attempted))")
                    if push.attempted > 0 {
                        Log.cli.info(
                            "cloudkit push: attempted=\(push.attempted) saved=\(push.saved) failed=\(push.failed) remaining=\(push.remaining)"
                        )
                    }
                    // Keep draining while work remains. A batch failure is
                    // almost always a transient CloudKit 429 (rate limit) —
                    // common during a bulk push like the canonical-hash v2
                    // reseed (thousands of records). Backing off the FULL
                    // safety-net interval (5–15 min) on every 429 would
                    // stretch a one-time reseed into hours. Instead: loop
                    // immediately when clean, back off briefly (respecting
                    // the server's CKRetryAfter, ~1s, with headroom) when
                    // throttled — never the full idle interval while there's
                    // work to push.
                    if push.remaining > 0 {
                        backoffSeconds = push.failed > 0 ? 8 : 0
                    }
                } catch {
                    Log.cli.error("cloudkit push failed: \(String(describing: error), privacy: .public)")
                    // A thrown (whole-batch) failure is also typically a
                    // transient 429 — short backoff, don't idle the full
                    // interval if there might be work left.
                    backoffSeconds = min(backoffSeconds, 8)
                }
                // Time-window eviction tick. The check is cheap (a
                // single UserDefaults read + a date compare) so we
                // run it every loop iteration, but the eviction
                // itself only fires once per 24h via the
                // `timeWindowLastRunAt` gate inside the helper.
                Log.cli.info("periodic tick \(tick, privacy: .public): evict-if-due begin")
                Self.runTimeWindowEvictionIfDue(store: store)
                Log.cli.info("periodic tick \(tick, privacy: .public): evict-if-due end")
                // Link-title backfill tick. Capped at 50 entries
                // per cycle so a fresh install with a thousand
                // links spreads the work across many ticks rather
                // than hammering the network for an hour. Each
                // cycle refreshes the FTS index for any rows that
                // got titles, so search picks them up almost
                // immediately.
                // Fire-and-forget. The backfiller can hang on a
                // single network call (macOS parking URLSession
                // requests pending Local Network permission) and
                // structured-cancellation can't always free it. We
                // *cannot* let that wedge the periodic loop, which
                // also drives CloudKit pull/push. The reentry guard
                // inside `runLinkTitleBackfillIfDue` keeps multiple
                // detached batches from piling up.
                Log.cli.info("periodic tick \(tick, privacy: .public): spawning detached backfill")
                Task.detached { await Self.runLinkTitleBackfillIfDue(store: store) }
                // Image-analysis sweep tick. Unlike the link backfill
                // above, this isn't gated on every single tick — Vision
                // has no network cost to amortize, but this account can
                // have up to three Macs all running this same periodic
                // loop, and without spacing they'd all wake on the
                // exact same cadence and duplicate Vision work on the
                // same freshly-pull-synced rows. `imageSweepScheduler`
                // enforces its own (jittered) interval independent of
                // the CloudKit safety-net cadence above.
                if await Self.imageSweepScheduler.dueNow(
                    base: Self.imageSweepBaseIntervalSeconds,
                    jitter: Self.imageSweepJitterSeconds
                ) {
                    Log.cli.info("periodic tick \(tick, privacy: .public): spawning detached image-analysis sweep")
                    Task.detached(priority: .utility) { await Self.runImageAnalysisSweepIfDue(store: store) }
                }
                Log.cli.info("periodic tick \(tick, privacy: .public): tick complete (backoff=\(backoffSeconds, privacy: .public)s)")
                if backoffSeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                }
                _ = self
            }
        }
    }

    /// Run the time-window eviction policy if (a) the user has
    /// enabled it, AND (b) at least 24h have passed since the last
    /// successful run. Called from the periodic-sync loop; cheap
    /// no-op when either gate fails.
    ///
    /// Errors are logged and swallowed — eviction is opportunistic;
    /// failure here shouldn't surface to the user beyond Console.
    ///
    /// `nonisolated` so the periodic-sync detached Task can call it
    /// without an actor hop. The eviction internals are thread-safe
    /// (GRDB serialises via dbQueue + UserDefaults is its own
    /// thread-safe API).
    /// Background fetch a small batch of link titles. Cheap when
    /// nothing's pending. Runs every periodic-loop cycle so a
    /// fresh-installed Mac with thousands of links progresses on
    /// the timer rather than blasting the network all at once.
    ///
    /// `nonisolated` for the same reason as `runTimeWindowEvictionIfDue`
    /// — the periodic-sync detached Task isn't on MainActor.
    /// Reentry guard for the detached backfill task. URLSession in
    /// Local Network limbo can hang forever ignoring cancellation, so
    /// the periodic loop fires the backfill detached. This actor
    /// stops a new batch from starting if the previous one is still
    /// in flight (which, in the wedge case, means stuck).
    private actor BackfillGate {
        private var running = false
        func tryAcquire() -> Bool {
            if running { return false }
            running = true
            return true
        }
        func release() { running = false }
    }
    private static let backfillGate = BackfillGate()

    nonisolated private static func runLinkTitleBackfillIfDue(store: Store) async {
        Log.cli.info("link-title backfill: enter (acquiring gate)")
        guard await backfillGate.tryAcquire() else {
            // Previous batch still running — most likely wedged on a
            // network call. Skip this tick rather than piling up.
            Log.cli.info("link-title backfill: previous batch still in flight, skipping")
            return
        }
        Log.cli.info("link-title backfill: gate acquired")
        defer { Task { await backfillGate.release() } }
        let repo = EntryRepository(store: store)
        // No probe — just run the batch. runOnce returns an empty
        // Report when there are no candidates. The probe used to be
        // an optimization but had a subtle bug: probing with limit=1
        // could return a single mailto: or otherwise non-http URL
        // (post-filtered out in compactMap), so we'd see "no
        // candidates" and bail even when 3000 valid http URLs sat
        // behind it in the queue.
        Log.cli.info("link-title backfill: starting batch (limit=50)")
        let backfiller = LinkMetadataBackfiller(repository: repo)
        do {
            let report = try await backfiller.runOnce(limit: 50)
            Log.cli.info(
                "link-title backfill: \(report.summary, privacy: .public)"
            )
        } catch {
            Log.cli.error(
                "link-title backfill failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Tiny-batch link backfill fired right after a capture, so a
    /// freshly-copied URL has its title (and thumbnail) materialise
    /// in the popup within seconds instead of waiting up to 15
    /// minutes for the periodic loop. Limit=5 keeps the network hit
    /// modest and biased toward "the row I just captured" since the
    /// backfill SQL is ORDER BY created_at DESC.
    ///
    /// Shares the BackfillGate with the periodic path so a capture
    /// during an in-flight periodic batch is a no-op (the periodic
    /// run will pick the new row up since it's now top-of-queue).
    nonisolated private static func runLinkTitleBackfillImmediate(store: Store) async {
        guard await backfillGate.tryAcquire() else { return }
        defer { Task { await backfillGate.release() } }
        let repo = EntryRepository(store: store)
        let backfiller = LinkMetadataBackfiller(repository: repo)
        do {
            let report = try await backfiller.runOnce(limit: 5)
            if report.attempted > 0 {
                Log.cli.info(
                    "link-title backfill (capture-wake): \(report.summary, privacy: .public)"
                )
            }
        } catch {
            Log.cli.error(
                "link-title backfill (capture-wake) failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Image-analysis sweep

    /// Reentry guard for the detached image-analysis sweep, same shape
    /// as `BackfillGate`. Vision work is CPU-bound rather than
    /// network-bound, so it's less likely to wedge than a hung
    /// URLSession call, but a slow batch on a big backlog (fresh
    /// install, first pull after being offline for a week) could still
    /// overlap the next scheduled sweep without this.
    private actor ImageSweepGate {
        private var running = false
        func tryAcquire() -> Bool {
            if running { return false }
            running = true
            return true
        }
        func release() { running = false }
    }
    private static let imageSweepGate = ImageSweepGate()

    /// Base interval between periodic image-analysis sweep passes.
    private static let imageSweepBaseIntervalSeconds: TimeInterval = 10 * 60
    /// Random extra delay (0...jitter) layered on top of the base
    /// interval, re-rolled every pass. Exists so three Macs signed into
    /// the same iCloud account — which all run this identical periodic
    /// loop — don't wake for a sweep in lockstep and duplicate Vision
    /// work on the same freshly-pull-synced rows every time. Duplicate
    /// analysis between Macs is harmless (whichever writes ITS RESULT
    /// first wins — `ImageIndexer.markAnalyzed`'s `UPDATE` is guarded
    /// with `analyzed_at IS NULL`, so a later write to an
    /// already-analyzed row is a no-op instead of clobbering it; see
    /// `EntryRepository.isImageUnanalyzed`'s doc comment for the
    /// check-then-write race this closes); the jitter is purely to make
    /// duplicate work the exception rather than the rule.
    private static let imageSweepJitterSeconds: TimeInterval = 5 * 60

    /// Tracks when the next periodic sweep pass is due. An actor
    /// because it's mutated from the periodic-sync detached Task, which
    /// isn't on MainActor.
    private actor ImageSweepScheduler {
        private var nextDueAt = Date.distantPast   // sweep soon after launch
        func dueNow(base: TimeInterval, jitter: TimeInterval) -> Bool {
            let now = Date()
            guard now >= nextDueAt else { return false }
            nextDueAt = now.addingTimeInterval(base + Double.random(in: 0...max(jitter, 0.001)))
            return true
        }
    }
    private static let imageSweepScheduler = ImageSweepScheduler()

    /// Periodic image-analysis sweep, gated by `imageSweepScheduler`'s
    /// jittered interval (checked by the caller before spawning this).
    /// Self-heals pull-synced images from other devices and any local
    /// capture whose capture-time analysis Task never finished — see
    /// `ImageAnalysisSweeper`'s doc comment for the full rationale.
    nonisolated private static func runImageAnalysisSweepIfDue(store: Store) async {
        guard await imageSweepGate.tryAcquire() else {
            Log.cli.info("image-analysis sweep: previous batch still in flight, skipping")
            return
        }
        defer { Task { await imageSweepGate.release() } }
        let sweeper = ImageAnalysisSweeper(repository: EntryRepository(store: store))
        do {
            let report = try sweeper.runOnce(limit: 15)
            if report.candidates > 0 {
                Log.cli.info("image-analysis sweep: \(report.summary, privacy: .public)")
            }
        } catch {
            Log.cli.error(
                "image-analysis sweep failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Tiny-batch image-analysis sweep fired right after a local image
    /// capture. Shares `imageSweepGate` with the periodic path so a
    /// capture during an in-flight periodic pass is a no-op — the
    /// periodic pass already covers it since it's now top-of-queue
    /// (`imagesNeedingAnalysis` orders newest-first).
    nonisolated private static func runImageAnalysisSweepImmediate(store: Store) async {
        guard await imageSweepGate.tryAcquire() else { return }
        defer { Task { await imageSweepGate.release() } }
        let sweeper = ImageAnalysisSweeper(repository: EntryRepository(store: store))
        do {
            let report = try sweeper.runOnce(limit: 3)
            if report.analyzed > 0 {
                Log.cli.info("image-analysis sweep (capture-wake): \(report.summary, privacy: .public)")
            }
        } catch {
            Log.cli.error(
                "image-analysis sweep (capture-wake) failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    nonisolated private static func runTimeWindowEvictionIfDue(store: Store) {
        guard EvictionPrefs.timeWindowEnabled else { return }
        let dayInSeconds: TimeInterval = 24 * 3600
        if let last = EvictionPrefs.timeWindowLastRunAt,
           Date().timeIntervalSince(last) < dayInSeconds
        {
            return
        }
        do {
            let evictor = EntryEvictor(store: store)
            let report = try evictor.evictOlderThan(days: EvictionPrefs.timeWindowDays)
            EvictionPrefs.timeWindowLastRunAt = Date()
            if report.entryCount > 0 {
                Log.cli.info(
                    "eviction (time-window \(EvictionPrefs.timeWindowDays, privacy: .public)d): freed \(report.entryCount, privacy: .public) entries, \(report.totalBytesFreed, privacy: .public) bytes"
                )
            }
        } catch {
            Log.cli.error(
                "eviction failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - APNs silent push handling

    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        // Any silent push that mentions our container → the zone changed.
        // We don't bother parsing the CKNotification payload; just run a
        // pull (and immediately follow with a push so late outbound work
        // doesn't wait the 5-minute idle timer).
        guard let syncer = syncer else { return }
        Task {
            do {
                let pull = try await syncer.pullRemoteChanges()
                Log.cli.info(
                    "apns pull: inserted=\(pull.inserted) updated=\(pull.updated) tombstoned=\(pull.tombstoned) skipped=\(pull.skipped)"
                )
                _ = try await syncer.pushPendingChanges()
            } catch {
                Log.cli.error("apns pull failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Log.cli.info("registered for remote notifications (\(deviceToken.count, privacy: .public) byte token)")
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        Log.cli.error("remote-notification registration failed: \(String(describing: error), privacy: .public)")
    }

    /// Called when the user launches the app while it's already
    /// running (double-click from Finder, `open -a cpdb`, etc.).
    /// cpdb is a menu-bar app (`LSUIElement = true`) so it has no
    /// Dock icon to bounce, and silently no-op'ing a re-launch feels
    /// broken — the user's asking for *something* to happen. Show
    /// the popup so they can search/paste. Returning `false` tells
    /// AppKit we've handled the reopen ourselves.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        Log.cli.info("reopen received (hasVisibleWindows=\(flag, privacy: .public)); showing popup")
        PopupController.shared.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.cli.info("cpdb.app terminating")
        periodicSyncTask?.cancel()
        lifecycle.stop()
    }

    // MARK: - Actions

    private func handleSummonPopup() {
        PopupController.shared.toggle()
    }

    /// Show an orange dot on the status item if the user hasn't picked a
    /// hotkey yet. Clicking the status item still works — the "Show cpdb"
    /// menu item remains wired. The dot is just a nudge toward Preferences.
    private func refreshFirstRunBadge() {
        let hasHotkey = KeyboardShortcuts.getShortcut(for: .summonPopup) != nil
        statusItem?.setNeedsAttention(!hasHotkey)
    }

    /// Kill any other running cpdb.app processes before we install our
    /// status item. Each running copy puts its own glyph in the menu
    /// bar, so a botched relaunch (deploy.sh's `open -a` over a still-
    /// alive instance, or repeated Xcode launches) accumulates icons
    /// quickly. We try a polite SIGTERM first, then escalate.
    ///
    /// Skips processes that share our PID (us) and any with a
    /// different bundle id. If nothing else is running, returns
    /// instantly.
    private func terminateOtherInstances() {
        let myPid = ProcessInfo.processInfo.processIdentifier
        guard let myBundle = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: myBundle)
            .filter { $0.processIdentifier != myPid }
        guard !others.isEmpty else { return }
        Log.cli.info(
            "terminating \(others.count, privacy: .public) older cpdb instance(s) before installing status item"
        )
        for app in others {
            // Polite quit first — applicationWillTerminate runs, the
            // syncer flushes, the daemon lock drops cleanly.
            _ = app.terminate()
        }
        // Block briefly so the menu-bar icons are gone before we
        // install ours. 0.6 s is generous; AppKit terminations
        // usually finish in <100 ms.
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            let stillAlive = NSRunningApplication
                .runningApplications(withBundleIdentifier: myBundle)
                .contains { $0.processIdentifier != myPid }
            if !stillAlive { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        // Anything still hanging gets the hammer.
        let stragglers = NSRunningApplication.runningApplications(withBundleIdentifier: myBundle)
            .filter { $0.processIdentifier != myPid }
        for app in stragglers {
            _ = app.forceTerminate()
        }
    }
}
