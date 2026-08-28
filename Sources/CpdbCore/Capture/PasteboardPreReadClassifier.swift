import Foundation
#if os(macOS)
import AppKit
import CpdbShared

/// Alert-free pre-read gate for the macOS 15.4+ pasteboard-privacy
/// preview. `NSPasteboard.detectedValues(for:)` inspects pasteboard
/// content "without notifying the person using the app" (Apple's own
/// doc comment on the API) — unlike decoding actual flavor bytes
/// (`PasteboardSnapshot.fromPasteboard`, the read that risks tripping
/// the iOS-style permission alert once enforcement ships). Running this
/// check first means content the watcher is going to discard anyway
/// never causes a full, alert-eligible read.
///
/// `TransientGuard`/`TransientFilter` remain the authority for
/// nspasteboard.org concealed/transient marker UTIs — that check is
/// synchronous, UTI-only (metadata, not content) and runs before this
/// one in `PasteboardWatcher.tick()`. This classifier is a second,
/// narrower gate layered in front of the full read, limited to what the
/// detection API can actually see: whether the pasteboard's text is a
/// probable web URL, and — the one secret-shaped case worth calling out
/// by name — whether that URL is an `otpauth://` URI, the de facto
/// format authenticator apps (Google Authenticator, Authy, 1Password)
/// use to hand off a TOTP/HOTP secret. That's a credential, not a link;
/// a clipboard manager shouldn't retain it any more than a password.
///
/// Below macOS 15.4 this always returns false (today's behavior:
/// capture proceeds straight to the full read, same as before this
/// stream). Fails open on any detection error for the same reason: this
/// is a narrow *additional* skip on top of TransientGuard, not a
/// replacement for it, so an inability to answer "is this secret-
/// shaped?" should never itself lose a legitimate capture.
public enum PasteboardPreReadClassifier {
    public static func looksSecretShaped(_ pb: NSPasteboard) async -> Bool {
        guard #available(macOS 15.4, *) else { return false }
        do {
            let values = try await pb.detectedValues(for: [\.probableWebURL])
            guard values.patterns.contains(\.probableWebURL) else { return false }
            return isSecretShapedURLString(values.probableWebURL)
        } catch {
            return false
        }
    }

    /// Pure string check, split out from `looksSecretShaped` so it's
    /// testable without a live `NSPasteboard`/macOS 15.4 availability.
    static func isSecretShapedURLString(_ urlString: String) -> Bool {
        urlString.lowercased().hasPrefix("otpauth://")
    }
}
#endif
