import Foundation
import AppKit

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

    private let queue = DispatchQueue(label: "local.cpdb.watcher", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int = -1

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
        Log.daemon.info("watcher stopped")
    }

    private func tick() {
        let pb = NSPasteboard.general
        let change = pb.changeCount
        if change == lastChangeCount { return }
        lastChangeCount = change

        // Transient filter first — don't even copy the bytes if it's a skip.
        if let items = pb.pasteboardItems, TransientFilter.shouldSkip(items) {
            Log.capture.info("skipped transient/concealed item (changeCount=\(change, privacy: .public))")
            return
        }

        guard let snapshot = PasteboardSnapshot.fromPasteboard(pb) else { return }

        // Grab the frontmost app on the main actor before we leave the watcher queue.
        Task { @MainActor in
            let appInfo = FrontmostApp.current()
            await self.handle(snapshot: snapshot, appInfo: appInfo)
        }
    }

    private func handle(snapshot: PasteboardSnapshot, appInfo: FrontmostAppInfo?) async {
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
