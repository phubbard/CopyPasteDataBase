import Foundation

/// User-facing settings for the image-analysis pipeline, persisted to
/// `UserDefaults`. Read at the start of every analysis so Preferences
/// changes take effect immediately for new captures (no restart required).
public struct AnalysisPrefs: Sendable, Equatable {
    public var recognitionLanguages: [String]
    public var tagConfidenceThreshold: Float

    public init(
        recognitionLanguages: [String] = ["en-US"],
        tagConfidenceThreshold: Float = 0.15
    ) {
        self.recognitionLanguages = recognitionLanguages
        self.tagConfidenceThreshold = tagConfidenceThreshold
    }

    // MARK: - UserDefaults keys

    public static let languagesKey = "cpdb.analysis.languages"
    public static let thresholdKey = "cpdb.analysis.tagConfidenceThreshold"

    /// Load the current settings. Falls back to defaults for any missing
    /// keys so first-run captures work without the app ever having opened
    /// Preferences.
    public static func load(defaults: UserDefaults = .standard) -> AnalysisPrefs {
        var prefs = AnalysisPrefs()
        if
            let data = defaults.data(forKey: languagesKey),
            let langs = try? JSONDecoder().decode([String].self, from: data),
            !langs.isEmpty
        {
            prefs.recognitionLanguages = langs
        }
        let threshold = defaults.double(forKey: thresholdKey)
        if threshold > 0 {
            prefs.tagConfidenceThreshold = Float(threshold)
        }
        return prefs
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(recognitionLanguages) {
            defaults.set(data, forKey: Self.languagesKey)
        }
        defaults.set(Double(tagConfidenceThreshold), forKey: Self.thresholdKey)
    }
}
