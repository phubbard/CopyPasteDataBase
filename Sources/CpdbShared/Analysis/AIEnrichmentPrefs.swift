import Foundation

/// User-facing setting for the AI title/summary pipeline, persisted to
/// `UserDefaults`. Mirrors `AnalysisPrefs`'s shape. Cross-platform (no
/// `#if os(macOS)`) even though the pipeline it gates is macOS-only — the
/// Preferences window and `AIService.enrichAtCaptureIfEligible` both read
/// it directly without needing their own platform guard.
public struct AIEnrichmentPrefs: Sendable, Equatable {
    /// Defaults to on wherever the feature is available at all;
    /// `PreferencesView` only shows the toggle when
    /// `AIService.availability == .available` (see stream brief), so a
    /// user who can't use the feature never sees — and never needs to
    /// flip — this switch in the first place.
    public var enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    public static let enabledKey = "cpdb.ai.enrichmentEnabled"

    public static func load(defaults: UserDefaults = .standard) -> AIEnrichmentPrefs {
        // No stored value yet → default on, same convention as
        // `AnalysisPrefs.load`'s "missing key falls back to the struct's
        // default" behavior.
        guard defaults.object(forKey: enabledKey) != nil else {
            return AIEnrichmentPrefs()
        }
        return AIEnrichmentPrefs(enabled: defaults.bool(forKey: enabledKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}
