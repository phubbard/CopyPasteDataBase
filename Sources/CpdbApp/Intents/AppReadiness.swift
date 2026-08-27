#if os(macOS)
import Foundation
import CpdbShared

/// Signals when the app's `Store` is open and `PopupController` is
/// configured, so App Intents (which can run in-process at any time —
/// Siri/Shortcuts can fire one moments after login, before
/// `applicationDidFinishLaunching` finishes) have something to poll
/// instead of crashing or silently no-oping against a nil store.
///
/// `AppDelegate` calls `markReady(store:)` once, right after
/// `PopupController.shared.configure(store:...)`. Everything else here
/// just polls that single property — deliberately simple over a
/// continuation-based wakeup, since intents are latency-insensitive
/// (a Shortcut run already tolerates a beat of "app launching…").
@MainActor
final class AppReadiness {
    static let shared = AppReadiness()
    private init() {}

    private(set) var store: Store?

    func markReady(store: Store) {
        self.store = store
    }

    /// Poll for the store, giving up after `timeout` seconds. 5s is
    /// generous for a cold launch (daemon lock + migration checks) but
    /// short enough that an intent fired against a wedged launch fails
    /// fast instead of hanging whatever UI is waiting on it (Shortcuts,
    /// Siri, the Spotlight click-through handler).
    func waitForStore(timeout: TimeInterval = 5, pollInterval: TimeInterval = 0.05) async -> Store? {
        if let store { return store }
        let deadline = Date().addingTimeInterval(timeout)
        while store == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return store
    }
}
#endif
