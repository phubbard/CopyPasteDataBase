import Foundation
import CpdbShared
#if canImport(Observation)
import Observation
#endif
#if os(macOS)
import AppKit
#endif

/// Mirrors `NSPasteboard.AccessBehavior`'s raw values (`AppKit/NSPasteboard.h`:
/// `default=0, ask=1, alwaysAllow=2, alwaysDeny=3`) without requiring macOS
/// 15.4 availability at the call site. `NSPasteboard.AccessBehavior` itself
/// is `API_AVAILABLE(macos(15.4))`, so referencing it anywhere in source
/// needs an `#available`/`@available` guard — this plain `Int`-backed twin
/// lets `PasteboardAccessClassifier.classify(_:)` (and its tests) run
/// unguarded on any OS/deployment target, including the iOS build of this
/// target, which never sees a real `NSPasteboard.AccessBehavior` at all.
public enum RawPasteboardAccessBehavior: Int, Sendable, Equatable {
    case defaultBehavior = 0
    case ask = 1
    case alwaysAllow = 2
    case alwaysDeny = 3
}

/// Coarse, whole-pasteboard privacy status. Distinct from `TransientGuard`,
/// which stays the per-item content authority (a concealed/transient
/// marker rejects one capture); this reflects what the OS says about
/// *this app's* standing access to the general pasteboard.
public enum PasteboardAccessStatus: Equatable, Sendable {
    /// System Settings has this app set to "Always Allow" (or the alert
    /// hasn't shipped and behavior is effectively unrestricted).
    case alwaysAllowed
    /// Programmatic reads will (or would, once enforcement ships) surface
    /// the iOS-style permission alert.
    case willPrompt
    /// The user has denied this app pasteboard access. Capture must stop.
    case denied
    /// Below macOS 15.4, or the OS reported a behavior value this build
    /// doesn't recognize. `reason` is a short, human-readable explanation
    /// for logs and the Preferences row.
    case preEnforcement(reason: String)
}

public extension PasteboardAccessStatus {
    /// Short, user-facing description shared by the Preferences "Privacy"
    /// row and the popup's pause banner, so the two surfaces never drift
    /// out of sync on wording.
    var displayLabel: String {
        switch self {
        case .alwaysAllowed:
            return "Always Allow"
        case .willPrompt:
            return "Ask (default) — unenforced today, capture is unaffected"
        case .denied:
            return "Denied"
        case .preEnforcement(let reason):
            return "Not applicable (\(reason))"
        }
    }
}

/// Pure classification logic for the previewed (macOS 15.4+, unenforced as
/// of this writing — see Preferences' "Privacy" section for the developer-
/// preview testing hint) pasteboard access alert. Kept free of any
/// `NSPasteboard`/`AppKit` dependency so it's trivially unit-testable and
/// compiles on every platform this package targets.
public enum PasteboardAccessClassifier {
    /// `raw` is `nil` for "the real API is unavailable" (< macOS 15.4, or
    /// the property couldn't be read) — always maps to `.preEnforcement`.
    public static func classify(_ raw: RawPasteboardAccessBehavior?) -> PasteboardAccessStatus {
        guard let raw else {
            return .preEnforcement(reason: "requires macOS 15.4")
        }
        switch raw {
        case .alwaysAllow:
            return .alwaysAllowed
        case .ask, .defaultBehavior:
            // The header's own doc comment: "The default behavior for the
            // General pasteboard is to ask upon programmatic access."
            return .willPrompt
        case .alwaysDeny:
            return .denied
        }
    }

    /// Whether the capture loop should pause entirely for this status.
    /// Only `.denied` pauses — `.willPrompt` means captures still work
    /// today (nothing is actually enforced yet outside the developer
    /// preview) and pausing on it would needlessly break every Mac that
    /// hasn't customized the setting.
    public static func shouldPauseCapture(for status: PasteboardAccessStatus) -> Bool {
        status == .denied
    }
}

#if os(macOS)
/// Polls `NSPasteboard.general.accessBehavior` at start-up and on a slow
/// timer, exposing the classified `status` the capture loop and the
/// Preferences "Privacy" section both read. `@Observable` so SwiftUI
/// re-renders the Preferences row without any manual plumbing.
@available(macOS 14, *)
@MainActor
@Observable
public final class PasteboardAccessMonitor {
    public private(set) var status: PasteboardAccessStatus

    /// Fired whenever `refresh()` observes a change. `DaemonLifecycle`
    /// uses this to re-derive `PasteboardWatcher.isPrivacyPaused` without
    /// polling `status` itself.
    public var onStatusChange: ((PasteboardAccessStatus) -> Void)?

    private var timer: DispatchSourceTimer?
    private let pollInterval: TimeInterval
    private let probe: () -> PasteboardAccessStatus

    /// `probe` is injectable so callers (and tests that do construct this
    /// class) aren't tied to the real `NSPasteboard`. Defaults to the live
    /// system probe.
    public init(
        pollInterval: TimeInterval = 5 * 60,
        probe: @escaping () -> PasteboardAccessStatus = PasteboardAccessMonitor.liveProbe
    ) {
        self.pollInterval = pollInterval
        self.probe = probe
        self.status = probe()
    }

    public func start() {
        refresh()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func refresh() {
        let new = probe()
        if new != status {
            Log.capture.info("pasteboard access status: \(String(describing: new), privacy: .public)")
            status = new
            onStatusChange?(new)
        }
    }

    /// Live probe against `NSPasteboard.general.accessBehavior`. A free
    /// static function (rather than inline in the `init` default) so
    /// tests can pass a fixed `probe:` closure instead.
    public static func liveProbe() -> PasteboardAccessStatus {
        guard #available(macOS 15.4, *) else {
            return .preEnforcement(reason: "requires macOS 15.4")
        }
        let raw = RawPasteboardAccessBehavior(rawValue: NSPasteboard.general.accessBehavior.rawValue)
        return PasteboardAccessClassifier.classify(raw)
    }

    /// Deep link to the pasteboard-access row of System Settings →
    /// Privacy & Security → "Paste from Other Apps". `Privacy_Pasteboard`
    /// is the anchor macOS 15.4 actually ships under (confirmed against
    /// public writeups of the preview — e.g. Michael Tsai's May 2025
    /// roundup of the pasteboard privacy changes — since this anchor
    /// predates any macOS this repo's build machine runs). If a future
    /// OS ever renames or drops it, `x-apple.systempreferences:` still
    /// opens System Settings itself, just without landing on the right
    /// pane — a straightforward fallback to research again later rather
    /// than a hard failure.
    public static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!
        NSWorkspace.shared.open(url)
    }
}
#endif
