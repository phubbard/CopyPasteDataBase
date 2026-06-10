#if os(iOS)
import Foundation
import CpdbShared
#if canImport(UIKit)
import UIKit
#endif

/// iOS-side factory for `PasteboardSnapshot`. Parallel to the macOS
/// `PasteboardSnapshot.fromPasteboard(_:)` in
/// `CpdbCore/Capture/PasteboardSnapshot.swift`, but reads `UIPasteboard`
/// instead of `NSPasteboard`.
///
/// ## Scope (first pass)
/// Text and links only — no images/files yet (see the punch-list in the
/// PR). We deliberately emit the **same UTIs macOS uses** for the same
/// content so the shared `CanonicalHash` produces an identical
/// `content_hash`:
///
/// - plain text  → `public.utf8-plain-text` (UTF-8 bytes, no BOM)
/// - a URL       → `public.url` (the absolute string, UTF-8 bytes)
///
/// A Mac copying `https://example.com` as `public.url` and an iPhone
/// copying the same string therefore converge on one entry instead of
/// forking — which is the entire reason iOS is becoming a writer
/// (hash-v2 §5.5).
///
/// ## Banner safety (CRITICAL)
/// Reading `UIPasteboard.general.string` / `.url` / `.hasStrings` **emits
/// the system "<app> pasted from <source>" banner on iOS 16+.** This
/// factory reads those properties, so it MUST only be called *after* the
/// caller has gated on `detectPatterns` (which does NOT emit the banner)
/// and the user has expressed capture intent. `IOSClipboardCapture` owns
/// that gating; do not call `fromGeneralPasteboard()` from a poll loop.
public extension PasteboardSnapshot {
    #if canImport(UIKit)
    /// Build a snapshot from the current contents of `UIPasteboard.general`.
    ///
    /// Returns `nil` when the pasteboard holds no text/url content we
    /// capture in this pass. **Emits the paste banner** — see the type
    /// doc; only call when capture is enabled and gated.
    static func fromGeneralPasteboard(
        _ pb: UIPasteboard = .general,
        capturedAt: Date = Date()
    ) -> PasteboardSnapshot? {
        // Prefer an explicit URL: `pb.url` is set when the copied content
        // is a real URL (Safari "Copy Link", share-sheet → Copy). Mirror
        // macOS by emitting `public.url`. If the same text is *also*
        // present as a plain string and differs from the URL, include it
        // too so multi-flavor entries match the Mac's shape — but the
        // common case (URL only, or URL == string) collapses to one
        // flavor, matching a Mac `public.url` copy exactly.
        let urlString: String? = pb.hasURLs ? pb.url?.absoluteString : nil
        let text: String? = pb.hasStrings ? pb.string : nil

        return makeSnapshot(urlString: urlString, text: text, capturedAt: capturedAt)
    }
    #endif

    /// Pure mapping from already-fetched pasteboard values to a snapshot.
    /// Factored out of `fromGeneralPasteboard()` so the UTI/flavor shape
    /// can be unit-tested without a live `UIPasteboard` (which can't be
    /// constructed deterministically in CI) and without tripping the
    /// paste banner. Returns `nil` when there's nothing to capture.
    ///
    /// Flavor rules (must match macOS for hash convergence):
    /// - a non-empty `urlString` → one `public.url` flavor
    /// - a non-empty `text` that differs from `urlString` → one
    ///   `public.utf8-plain-text` flavor
    /// - both, when they differ → two flavors on a single item (matching a
    ///   Mac copy that carries both a URL and its text shadow)
    static func makeSnapshot(
        urlString: String?,
        text: String?,
        capturedAt: Date = Date()
    ) -> PasteboardSnapshot? {
        var flavors: [CanonicalHash.Flavor] = []

        if let url = urlString,
           !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            flavors.append(.init(uti: "public.url", data: Data(url.utf8)))
        }

        if let t = text,
           !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           t != urlString {
            flavors.append(.init(uti: "public.utf8-plain-text", data: Data(t.utf8)))
        }

        guard !flavors.isEmpty else { return nil }
        return PasteboardSnapshot(
            items: [Item(flavors: flavors)],
            capturedAt: capturedAt
        )
    }
}
#endif
