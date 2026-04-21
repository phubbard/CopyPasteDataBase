import Foundation

/// Canonical version string for cpdb. Bump here for every release.
///
/// Keep in sync with `Sources/CpdbApp/Resources/Info.plist` — both
/// `CFBundleShortVersionString` and `CFBundleVersion`. The `Makefile`'s
/// `verify-version` target checks this at build time so drift fails loudly.
public enum CpdbVersion {
    public static let current = "1.3.2"
}
