#if os(macOS)
import Foundation
import AppKit
import CpdbShared
import os

/// Polls `NSPasteboard.general.changeCount` and hands new snapshots to an
/// `Ingestor`.
///
/// macOS has no clipboard-change notification API, so polling is the
/// standard approach. 150 ms is fast enough to feel instant to the user and
/// cheap enough to ignore on any modern Mac (a changeCount read is a few
/// hundred nanoseconds).
public final class PasteboardWatcher {
    public let pollInterval: TimeInterval
    public let ingestor: Ingestor
    public let deviceId: Int64

    private let queue = DispatchQueue(label: "\(Paths.bundleId).watcher", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int = -1
    /// Per-tick capture `Task`s currently in flight (classifying and/or
    /// reading pasteboard content), keyed by a per-spawn id. `stop()`
    /// cancels and clears every entry so a tick that fired just before a
    /// privacy pause can't finish a full, alert-eligible read and land an
    /// ingest afterward — see `stop()` and `tick()`'s `Task.isCancelled`
    /// checks. A lock rather than confinement to `queue`, since `stop()`/
    /// `start()` are typically called from `DaemonLifecycle` on the main
    /// actor while `tick()` runs on `queue`.
    private let inFlightTasks = OSAllocatedUnfairLock(initialState: [UUID: Task<Void, Never>]())

    public init(ingestor: Ingestor, deviceId: Int64, pollInterval: TimeInterval = 0.15) {
        self.ingestor = ingestor
        self.deviceId = deviceId
        self.pollInterval = pollInterval
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        self.timer = t
        Log.daemon.info("watcher started (interval \(self.pollInterval, privacy: .public)s)")
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        // Quiesce in-flight capture work too — cancelling the timer
        // alone leaves any Task a just-fired tick already spawned free
        // to keep running: it would still perform the full alert-
        // eligible pasteboard read (and ingest the result) after this
        // pause has been logged/shown, which is exactly what the pause
        // exists to prevent. `tick()` checks `Task.isCancelled` at each
        // cooperative checkpoint and bails out.
        let tasks = inFlightTasks.withLock { state -> [Task<Void, Never>] in
            let values = Array(state.values)
            state.removeAll()
            return values
        }
        for task in tasks { task.cancel() }
        Log.daemon.info("watcher stopped")
    }

    private func tick() {
        let pb = NSPasteboard.general
        let change = pb.changeCount
        if change == lastChangeCount { return }
        lastChangeCount = change
        // Stamped here, synchronously on the watcher's serial queue —
        // i.e. in copy order — rather than left to `fromPasteboard`'s
        // `Date()` default, which would otherwise run inside the
        // unstructured `Task` below and stamp captures in completion
        // order instead. A big screenshot's byte read can take far
        // longer than a quick text capture from a later tick, so without
        // this the slower capture could appear to have happened after
        // the faster, later one.
        let detectedAt = Date()

        // Cheapest possible gate: a password field is focused somewhere
        // on the system (Carbon's secure-input flag). Skip before
        // touching pasteboard content — or even its types — at all.
        if SecureInputGuard.shouldSkip() { return }

        // Transient filter first — don't even copy the bytes if it's a skip.
        if let items = pb.pasteboardItems, TransientFilter.shouldSkip(items) {
            Log.capture.info("skipped transient/concealed item (changeCount=\(change, privacy: .public))")
            return
        }

        // Deliberately not `Task { @MainActor in ... }`: neither
        // `detectedValues(for:)` nor `fromPasteboard` needs the main
        // actor, and the flavor-bytes read below can be tens of MB
        // (a screenshot's PNG+TIFF) — running that on the main actor
        // would stall UI on every large copy. Only the two calls that
        // actually require it (`FrontmostApp.current()`, `self.handle`)
        // hop to `@MainActor`, each for as long as it takes.
        let taskId = UUID()
        let task = Task {
            defer { self.inFlightTasks.withLock { _ = $0.removeValue(forKey: taskId) } }

            // Pre-read classification (macOS 15.4+ only; see
            // PasteboardPreReadClassifier's doc comment). Alert-free, so
            // this runs before the full flavor read below rather than
            // after it.
            if await PasteboardPreReadClassifier.looksSecretShaped(pb) {
                Log.capture.info("skipped secret-shaped content (pre-read, changeCount=\(change, privacy: .public))")
                return
            }

            // `stop()` may have cancelled this task while the await
            // above was in flight — bail before the (potentially large,
            // alert-eligible) content read rather than perform it after
            // a pause has already been logged/shown.
            if Task.isCancelled { return }

            // TOCTOU guard: the SecureInputGuard/TransientFilter checks
            // above ran against the pasteboard as of `change`, but the
            // await above yields the thread — another app can publish
            // new content (e.g. a concealed item) before we get here.
            // If the pasteboard has moved on, bail rather than read
            // content that never passed its own gates: `lastChangeCount`
            // is already stale for it, so the very next tick will see
            // the new changeCount, and run every gate against the
            // content that's actually there now.
            //
            // Trade-off, not a bug to "fix" away: this does mean that
            // if a second copy lands while the classifier await above
            // is in flight, THIS tick's content (already superseded on
            // the live pasteboard) is dropped rather than captured —
            // there is no way to safely read it after the fact, since
            // `looksSecretShaped` classified whatever is live on `pb`
            // at the time it returned, which may no longer be what
            // `change` referred to. Logged (unlike the classifier/
            // transient skips above, this one is rare enough — needs a
            // second copy inside the classifier's await window — that
            // a bare silent `return` would make it very hard to
            // diagnose if it ever matters in practice).
            guard pb.changeCount == change else {
                Log.capture.info("dropped stale capture: pasteboard changed during classification (changeCount=\(change, privacy: .public) now=\(pb.changeCount, privacy: .public))")
                return
            }

            guard let snapshot = PasteboardSnapshot.fromPasteboard(pb, capturedAt: detectedAt) else { return }
            if Task.isCancelled { return }
            let appInfo = await FrontmostApp.current()
            if Task.isCancelled { return }
            await self.handle(snapshot: snapshot, appInfo: appInfo)
        }
        inFlightTasks.withLock { $0[taskId] = task }
    }

    @MainActor
    private func handle(snapshot: PasteboardSnapshot, appInfo: FrontmostAppInfo?) async {
        // Source-app blocklist — applies in addition to the UTI-based
        // TransientFilter so apps that don't self-flag (Apple's Passwords,
        // Keychain Access) still get skipped. We check both the current
        // frontmost app AND the last 5 s of activations, because Apple's
        // Passwords is frontmost for <100 ms during a copy and typically
        // already dismissed by the time our 150 ms poll looks.
        if let ignored = IgnoredApps.firstIgnoredRecentBundle(currentBundleId: appInfo?.bundleId) {
            Log.capture.info("skipped ignored-source-app entry (matched \(ignored, privacy: .public))")
            return
        }

        // Safety net: Apple's Strong Password format (6-6-6 alphanumeric,
        // hyphen-separated, exactly 20 chars) is proprietary enough that
        // we refuse to store anything matching it, regardless of source
        // app. Catches Passwords-app copies that slip past the frontmost-
        // app history when the monitor misses the activation notification.
        if snapshot.looksLikeApplePassword {
            Log.capture.info("skipped Apple Strong Password shape")
            return
        }
        do {
            let outcome = try ingestor.ingest(snapshot, sourceApp: appInfo, deviceId: deviceId)
            switch outcome {
            case .inserted(let id):
                Log.capture.info("inserted entry \(id, privacy: .public) kind=\(snapshot.kind.rawValue, privacy: .public) size=\(snapshot.totalSize)")
            case .bumped(let id):
                Log.capture.info("bumped existing entry \(id, privacy: .public)")
            case .skipped(let reason):
                Log.capture.info("skipped: \(reason, privacy: .public)")
            }
        } catch {
            Log.capture.error("ingest failed: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
