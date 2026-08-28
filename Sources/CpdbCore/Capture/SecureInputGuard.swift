#if os(macOS)
import Carbon
import CpdbShared
import os

/// Wraps Carbon's `IsSecureEventInputEnabled()`. That flag is system-wide
/// and true whenever *any* process has turned on secure keyboard input —
/// in practice, almost always because a password field (an
/// `NSSecureTextField`, Terminal's `sudo` prompt, a browser's password
/// manager fill sheet) is currently focused somewhere. It says nothing
/// about what's actually *on* the pasteboard, but a clipboard change that
/// lands while secure input is on is disproportionately likely to be
/// password-adjacent (a manager's "copy password" button, a 1Password
/// autofill that also populates the clipboard) — cheap enough, and safe
/// enough, to skip outright rather than risk it.
///
/// Distinct from `PasteboardAccessMonitor` (whole-pasteboard OS-level
/// permission) and `TransientGuard` (per-item UTI markers): this is a
/// keyboard-focus signal, checked before either of those, and before any
/// pasteboard content is touched at all.
public enum SecureInputGuard {
    /// Live probe against Carbon. A free function (not a closure literal)
    /// so call sites and tests can both refer to it by name.
    public static func liveProbe() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// Captures skipped this launch because secure input was active.
    /// In-process only — not persisted, and not wired into the About
    /// window's stats block, which is entirely DB-derived; this is
    /// ephemeral runtime state with no natural home there yet. A debug
    /// log line is the record of it for now.
    ///
    /// Written from the watcher's utility-QoS queue (`shouldSkip`, on
    /// every capture tick) and read from the main thread (Preferences'
    /// 5 s poller) — genuinely concurrent access, so the backing count
    /// is behind an unfair lock rather than a bare `static var`.
    private static let skipCountLock = OSAllocatedUnfairLock(initialState: 0)

    public static var skipCount: Int {
        skipCountLock.withLock { $0 }
    }

    /// Check-and-count. Returns true (and bumps `skipCount`) when `probe`
    /// reports secure input is active. `probe` defaults to the real
    /// Carbon call; tests inject a fixed value instead.
    @discardableResult
    public static func shouldSkip(probe: () -> Bool = liveProbe) -> Bool {
        guard probe() else { return false }
        let newCount = skipCountLock.withLock { count -> Int in
            count += 1
            return count
        }
        Log.capture.debug("skipped capture: secure event input active (count=\(newCount, privacy: .public))")
        return true
    }
}
#endif
