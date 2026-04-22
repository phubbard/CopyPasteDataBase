import Foundation
import AppKit
import CpdbShared

/// Tracks frontmost-app activations in a short sliding window.
///
/// Motivates: Apple's Passwords app is frontmost for only ~50 ms between
/// "user clicks Copy" and "window dismisses itself". Our `PasteboardWatcher`
/// polls every 150 ms, so by the time we ask `NSWorkspace.frontmostApplication`
/// which app "source" to attribute, Passwords is already gone — typically
/// replaced by `loginwindow`, `Safari`, or whatever app regained focus.
/// The UTI-based `TransientFilter` doesn't fire because Apple's Passwords
/// publishes cleartext without the `org.nspasteboard.ConcealedType` marker,
/// and the bundle-id `IgnoredApps` check misses because of the timing race.
///
/// This monitor subscribes to `NSWorkspace.didActivateApplicationNotification`
/// and keeps the last ~10 seconds of activations. `IgnoredApps` uses it to
/// look *backwards* from a clipboard event: if any ignored bundle was
/// frontmost in the last 5 s, skip capture.
@MainActor
public final class FrontmostAppMonitor {
    public static let shared = FrontmostAppMonitor()

    /// How long we keep history around. 10 s is overkill for the 150 ms
    /// poll race; pick it anyway so callers can ask for any window ≤ 10 s.
    public static let retentionSeconds: TimeInterval = 10

    private struct Event {
        let bundleId: String
        let at: Date
    }
    private var events: [Event] = []

    private init() {
        // Seed with the current frontmost so a summon that fires before any
        // activation notification still has something to compare against.
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            events.append(Event(bundleId: bid, at: Date()))
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func didActivate(_ note: Notification) {
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let bid = app.bundleIdentifier
        else { return }
        events.append(Event(bundleId: bid, at: Date()))
        trim()
    }

    private func trim() {
        let cutoff = Date().addingTimeInterval(-Self.retentionSeconds)
        events.removeAll { $0.at < cutoff }
    }

    /// Bundle ids that were frontmost at any point in the last `window`
    /// seconds. The current frontmost app is always included.
    public func recentBundleIds(window: TimeInterval = 5) -> Set<String> {
        let cutoff = Date().addingTimeInterval(-window)
        var seen = Set(events.filter { $0.at >= cutoff }.map(\.bundleId))
        if let now = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            seen.insert(now)
        }
        return seen
    }

    /// Explicitly kick the monitor at app launch so observer registration
    /// happens before the first pasteboard event.
    public static func warmUp() {
        _ = shared
    }
}
