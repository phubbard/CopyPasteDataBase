import AppKit
import ApplicationServices

/// Thin wrapper around `AXIsProcessTrustedWithOptions`.
///
/// Posting a CGEvent from an app (to synthesise ⌘V) requires the process
/// to be listed in **System Settings → Privacy & Security → Accessibility**.
/// Without it, `CGEvent.post` silently drops the event and Console logs
/// `"Sender is prohibited from synthesizing events"`.
enum Accessibility {
    /// Non-prompting check. Safe to call on every paste attempt.
    static func isTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Prompts once per launch. macOS opens System Settings if the user
    /// agrees. First prompt attaches the TCC decision to the binary's
    /// code signature, so it persists across launches as long as the
    /// binary doesn't change.
    @discardableResult
    static func requestTrustWithPrompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Deep link to the Accessibility pane of System Settings. Useful to
    /// offer in the onboarding sheet because the prompt only appears once
    /// per TCC lifetime.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
