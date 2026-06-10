#if os(iOS)
import Foundation
import CpdbShared
#if canImport(UIKit)
import UIKit
#endif

/// iOS clipboard capture controller. The iOS analogue of the macOS
/// `PasteboardWatcher` → `Ingestor` path, but built around iOS's hard
/// constraints (see the design notes below).
///
/// ## Why this exists / the capture model
/// 1. **No background pasteboard access.** iOS gives no reliable way to
///    poll the clipboard in the background, so capture only happens while
///    the app is foreground/active.
/// 2. **Reading the pasteboard trips the system banner.** On iOS 16+ any
///    read of `UIPasteboard.general` (`.string`, `.url`, `.hasStrings`…)
///    shows "<app> pasted from <source>". Polling would spam the user and
///    is a privacy red flag. So we **gate every read on
///    `detectPatterns(for:)`**, which inspects the pasteboard *without*
///    emitting the banner and tells us whether text/URLs are present. We
///    only read the real bytes when (a) capture is enabled and (b) a
///    pattern we care about is present.
/// 3. Because of (1) and (2), silent auto-capture is the wrong model. The
///    app exposes an **explicit** "Save clipboard now" action plus an
///    **optional, OFF-by-default** capture-on-foreground toggle. This
///    controller is the shared mechanism behind both; the enable/disable
///    decision and persistence live in the app layer (`AppContainer`).
///
/// ## Identity & safety parity
/// Captures go through the **same `Ingestor`** the Mac uses, so content
/// hashing, the 30s secondary text-dedup window, kind reclassification,
/// the shared `TransientGuard` concealed-marker rejection, and push-queue
/// enqueue are all identical to a Mac capture. iOS captures are attributed
/// to `FrontmostAppInfo.iosClipboard`.
public final class IOSClipboardCapture {
    private let ingestor: Ingestor
    private let deviceId: Int64

    public init(ingestor: Ingestor, deviceId: Int64) {
        self.ingestor = ingestor
        self.deviceId = deviceId
    }

    public enum Result: Sendable, Equatable {
        /// A new entry was inserted (caller should push).
        case inserted(Int64)
        /// An existing entry was bumped (caller should push).
        case bumped(Int64)
        /// Nothing captured. `reason` is for logging only.
        case skipped(reason: String)
    }

    /// Whether the result represents a write that should be pushed to
    /// CloudKit. Lets the caller fire a push only when there's something
    /// to sync.
    public static func isPushable(_ r: Result) -> Bool {
        switch r {
        case .inserted, .bumped: return true
        case .skipped: return false
        }
    }

    #if canImport(UIKit)
    /// Patterns we capture in this pass: text and URLs. `detectPatterns`
    /// also supports numbers/dates/etc.; we treat plain text as the
    /// catch-all (`probableWebSearch`/`number` content still arrives as a
    /// string flavor). `.probableWebURL` lets us prefer the URL shape.
    private static let interestingPatterns: Set<UIPasteboard.DetectionPattern> = [
        .probableWebURL,
        .probableWebSearch,
        .number,
    ]

    /// Capture the current general-pasteboard contents IF something
    /// text/URL-shaped is present. Banner-safe gating: we call
    /// `detectPatterns` (no banner) first and only read the bytes when a
    /// pattern is found.
    ///
    /// `MainActor` because `UIPasteboard` reads should happen on the main
    /// thread and the ingest write is cheap. Returns the outcome; the
    /// caller is responsible for kicking a CloudKit push when
    /// `isPushable` is true.
    @MainActor
    public func captureCurrentClipboard(
        pasteboard pb: UIPasteboard = .general
    ) async -> Result {
        // Fast no-banner gate. If iOS reports no interesting pattern, do
        // NOT read the bytes (which would show the banner for nothing).
        let patterns = await detectInterestingPatterns(pb)
        guard !patterns.isEmpty else {
            return .skipped(reason: "no text/url pattern (detectPatterns)")
        }

        // Now it's worth reading the actual content (this emits the
        // banner — acceptable because the user enabled capture and there
        // is real content to save).
        guard let snapshot = PasteboardSnapshot.fromGeneralPasteboard(pb) else {
            return .skipped(reason: "pattern present but no readable text/url")
        }

        // Safety net mirrored from the macOS watcher: never store anything
        // matching Apple's Strong Password shape, regardless of source.
        if snapshot.looksLikeApplePassword {
            return .skipped(reason: "looks like Apple Strong Password")
        }

        return ingest(snapshot)
    }

    /// Run `detectPatterns` and return the subset we care about. Does not
    /// emit the paste banner. Returns an empty set on error (fail-closed:
    /// no capture rather than a spurious read).
    @MainActor
    private func detectInterestingPatterns(
        _ pb: UIPasteboard
    ) async -> Set<UIPasteboard.DetectionPattern> {
        await withCheckedContinuation { continuation in
            pb.detectPatterns(for: Self.interestingPatterns) { result in
                switch result {
                case .success(let found):
                    continuation.resume(returning: found.intersection(Self.interestingPatterns))
                case .failure:
                    continuation.resume(returning: [])
                }
            }
        }
    }
    #endif

    /// Route a pre-built snapshot through the shared `Ingestor`. Exposed
    /// (and platform-neutral) so tests can drive ingest without a live
    /// `UIPasteboard`, and so a future share-extension capture path can
    /// reuse it. Attributes the entry to `iosClipboard`.
    public func ingest(_ snapshot: PasteboardSnapshot) -> Result {
        do {
            let outcome = try ingestor.ingest(
                snapshot,
                sourceApp: .iosClipboard,
                deviceId: deviceId
            )
            switch outcome {
            case .inserted(let id): return .inserted(id)
            case .bumped(let id):   return .bumped(id)
            case .skipped(let r):   return .skipped(reason: r)
            }
        } catch {
            return .skipped(reason: "ingest error: \(error)")
        }
    }
}
#endif
