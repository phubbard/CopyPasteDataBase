import Foundation

/// Source-app blocklist for capture. Any entry whose source-app bundle ID
/// appears here is dropped before it hits the store.
///
/// This complements `TransientFilter`, which operates on pasteboard UTIs
/// (the `org.nspasteboard.*` convention). Apple's Passwords app doesn't
/// publish those markers — it just puts `public.utf8-plain-text` on the
/// pasteboard like any other app. Blocklisting by bundle ID catches
/// that case.
///
/// The macOS-side extension in
/// `CpdbCore/Capture/IgnoredApps+FrontmostHistory.swift` adds a
/// `firstIgnoredRecentBundle(currentBundleId:)` helper that queries
/// `FrontmostAppMonitor` — used to catch the Passwords-app race where
/// the app is frontmost for only ~50 ms during a copy.
public enum IgnoredApps {
    /// Apps we always ignore, no matter what the user's prefs say. These
    /// are the "unambiguously contains secrets" bucket — if we captured
    /// from them we'd be leaking credentials into plain-text history and
    /// the FTS5 index.
    public static let defaultBundleIds: Set<String> = [
        "com.apple.Passwords",      // Apple's standalone Passwords app (macOS 15+)
        "com.apple.keychainaccess", // Keychain Access
    ]

    public static let userDefaultsKey = "cpdb.capture.ignoredBundleIds"

    /// Combine defaults with anything the user has added via Preferences.
    public static func load(defaults: UserDefaults = .standard) -> Set<String> {
        let extra = (defaults.array(forKey: userDefaultsKey) as? [String]) ?? []
        return defaultBundleIds.union(extra)
    }

    /// Returns true if a frontmost-app bundle ID should cause capture to
    /// be skipped.
    public static func shouldIgnore(bundleId: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let id = bundleId, !id.isEmpty else { return false }
        return load(defaults: defaults).contains(id)
    }
}
