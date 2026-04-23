import Foundation

/// Canonical version strings for cpdb.
///
/// `marketing` is the hand-edited marketing version — bump here for
/// each real release (1.3.2 → 2.0.0 → 2.0.1 → …). Must match
/// `CFBundleShortVersionString` in `Sources/CpdbApp/Resources/Info.plist`.
///
/// `current` is what appears in the About window and CLI `--version`
/// output. It appends a git short-sha when the Makefile regenerates
/// `BuildStamp.swift` before building, so you can always tell which
/// exact commit produced the binary running on axiom vs. thor vs. air-15.
///
/// Running `swift build` or `swift test` directly (bypassing the
/// Makefile) leaves `BuildStamp.stamp` at its committed default and
/// `current` reads as just the marketing version. Good enough for
/// unit tests.
public enum CpdbVersion {
    /// Marketing version. Human-editable source of truth.
    public static let marketing = "2.0.0-dev"

    /// Marketing + git short-sha when the Makefile stamped the build,
    /// otherwise just `marketing`.
    public static var current: String {
        BuildStamp.stamp.isEmpty ? marketing : "\(marketing)+\(BuildStamp.stamp)"
    }
}
