#if os(macOS)
import Foundation
import CpdbShared

/// macOS-side extension to the cross-platform `IgnoredApps` enum in
/// `CpdbShared`. Adds a helper that queries `FrontmostAppMonitor`'s
/// 5-second history of recent frontmost apps so we catch the
/// Passwords-app race: the app is frontmost for only ~50 ms during a
/// copy, so by the time our 150 ms poll samples
/// `NSWorkspace.frontmostApplication` it's gone.
public extension IgnoredApps {
    /// Returns the first ignored bundle ID found in the current-frontmost +
    /// recent-frontmost-history set, or nil if none matched. Used by
    /// `PasteboardWatcher`.
    @MainActor
    static func firstIgnoredRecentBundle(
        currentBundleId: String?,
        defaults: UserDefaults = .standard
    ) -> String? {
        let ignored = load(defaults: defaults)
        if let id = currentBundleId, ignored.contains(id) { return id }
        let recent = FrontmostAppMonitor.shared.recentBundleIds(window: 5)
        for bid in recent where ignored.contains(bid) {
            return bid
        }
        return nil
    }
}
#endif
