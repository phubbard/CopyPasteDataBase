import Foundation

/// Permanent, lightweight accounting for the popup-summon perf
/// instrumentation (see `PopupController.show()`). Card views
/// (`ImageCard`, `LinkCard`) bump this as they load thumbnails on the
/// main thread; `PopupController` reads-and-resets it around each summon
/// and folds the totals into the `popup-perf` / `popup-perf-session` log
/// lines.
///
/// `@MainActor` because all card rendering (and therefore every counter
/// bump) happens on the main thread — this is measurement-only
/// bookkeeping, not a general-purpose concurrency-safe counter.
@MainActor
final class PopupPerfCounters {
    static let shared = PopupPerfCounters()

    private(set) var thumbLoads: Int = 0
    private(set) var thumbNanos: UInt64 = 0
    private(set) var storeOpens: Int = 0

    private init() {}

    /// Zero everything out. Called at the top of `PopupController.show()`
    /// so each summon's `popup-perf` line reflects just that summon's
    /// card loads (loads that land after the first-frame marker, e.g.
    /// from scrolling, keep accumulating for the `hide()` session total).
    func reset() {
        thumbLoads = 0
        thumbNanos = 0
        storeOpens = 0
    }

    /// Record one thumbnail load (`ImageCard`/`LinkCard.loadThumbnail()`).
    func recordThumbLoad(nanos: UInt64) {
        thumbLoads += 1
        thumbNanos += nanos
    }

    /// Record one `Store.open()` call made while loading a thumbnail.
    func recordStoreOpen() {
        storeOpens += 1
    }
}
