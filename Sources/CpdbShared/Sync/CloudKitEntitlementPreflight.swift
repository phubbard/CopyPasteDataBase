import Foundation
import Security

/// Guards against the uncatchable crash a plain CLI process hits when it
/// tries to use CloudKit without holding the iCloud entitlement.
///
/// `LiveCloudKitClient`'s init calls `CKContainer(identifier:)`, which
/// raises an Objective-C exception (SIGTRAP, exit 133, zero stdout/stderr)
/// on a binary that lacks `com.apple.developer.icloud-services` — which
/// the shipped `cpdb` CLI executable always does; bare command-line
/// binaries can't carry iCloud entitlements on macOS, only an app bundle
/// can. That exception can't be caught by Swift's `do/catch`, so the only
/// way to fail cleanly is to check for the entitlement *before*
/// constructing the client at all.
///
/// Call `verify()` (or `verify(check:)` with an injected fake for tests)
/// at the top of any CLI command path that's about to construct a
/// `LiveCloudKitClient`.
public enum CloudKitEntitlementPreflight {
    /// The entitlement CloudKit requires. Presence is checked; the
    /// specific value (environment string) doesn't matter for our
    /// purposes — we only need to know CloudKit is usable at all.
    public static let requiredEntitlement = "com.apple.developer.icloud-services"

    public enum PreflightError: Error, CustomStringConvertible, Equatable {
        case missingEntitlement

        public var description: String {
            """
            This process cannot use CloudKit: it does not hold the \
            \(CloudKitEntitlementPreflight.requiredEntitlement) entitlement. Bare \
            command-line executables can't carry iCloud entitlements on macOS — \
            only an app bundle can — so `CKContainer` would crash instead of \
            failing cleanly here. Sync runs inside the cpdb app instead: leave the \
            app running (it syncs automatically in the background) or use its menu \
            bar icon's "Sync Now".
            """
        }
    }

    /// Real check: inspects the running process's own code-signing
    /// entitlements via `SecTaskCreateFromSelf` +
    /// `SecTaskCopyValueForEntitlement`. A missing task (shouldn't
    /// happen for a live process, but `SecTaskCreateFromSelf` is
    /// documented as failable) or a missing entitlement value both mean
    /// "not entitled".
    ///
    /// `SecTaskCreateFromSelf`/`SecTaskCopyValueForEntitlement` aren't
    /// in the iOS SDK — but this whole preflight only guards the
    /// macOS-only `cpdb` CLI's sync commands (there is no cpdb CLI on
    /// iOS), so the non-macOS branch is dead code in practice. It
    /// reports "not entitled" rather than failing to compile, so any
    /// future non-macOS caller fails safe instead of silently
    /// proceeding.
    public static func defaultCheck() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, requiredEntitlement as CFString, nil)
        return value != nil
        #else
        return false
        #endif
    }

    /// Throws `PreflightError.missingEntitlement` unless the current
    /// process holds the iCloud entitlement. `check` is injectable so
    /// tests can simulate an entitled/unentitled process without two
    /// differently-signed test binaries — defaults to the real
    /// `SecTask`-based check.
    public static func verify(check: () -> Bool = defaultCheck) throws {
        guard check() else {
            throw PreflightError.missingEntitlement
        }
    }
}
