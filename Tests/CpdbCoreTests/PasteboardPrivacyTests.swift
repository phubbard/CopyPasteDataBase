import Testing
import Foundation
@testable import CpdbCore

/// Gate-logic tests for the pasteboard-privacy preparedness stream:
/// `PasteboardAccessClassifier` (raw behavior → status → pause decision),
/// `SecureInputGuard` (injectable Carbon wrapper), and
/// `PasteboardPreReadClassifier`'s pure string-matching half. All of this
/// is platform-neutral logic deliberately kept free of `NSPasteboard`/
/// `AppKit`, so it runs on every host `swift test` builds for — no live
/// pasteboard, no macOS 15.4 required.
// .serialized: SecureInputGuard.skipCount is process-global mutable
// state (see its doc comment) — the two tests that assert on its exact
// delta would be flaky if Swift Testing ran them concurrently with each
// other or with a future test that also touches the counter.
@Suite("Pasteboard privacy — gate logic", .serialized)
struct PasteboardPrivacyTests {

    // MARK: - PasteboardAccessClassifier

    @Test("nil raw behavior (API unavailable) classifies as preEnforcement")
    func nilRawIsPreEnforcement() {
        let status = PasteboardAccessClassifier.classify(nil)
        guard case .preEnforcement = status else {
            Issue.record("expected .preEnforcement, got \(status)")
            return
        }
    }

    @Test("alwaysAllow classifies as alwaysAllowed")
    func alwaysAllowMapsToAlwaysAllowed() {
        #expect(PasteboardAccessClassifier.classify(.alwaysAllow) == .alwaysAllowed)
    }

    @Test("ask classifies as willPrompt")
    func askMapsToWillPrompt() {
        #expect(PasteboardAccessClassifier.classify(.ask) == .willPrompt)
    }

    @Test("defaultBehavior classifies as willPrompt (same as ask)")
    func defaultBehaviorMapsToWillPrompt() {
        #expect(PasteboardAccessClassifier.classify(.defaultBehavior) == .willPrompt)
    }

    @Test("alwaysDeny classifies as denied")
    func alwaysDenyMapsToDenied() {
        #expect(PasteboardAccessClassifier.classify(.alwaysDeny) == .denied)
    }

    @Test("only denied pauses capture")
    func shouldPauseCaptureOnlyForDenied() {
        let cases: [(PasteboardAccessStatus, Bool)] = [
            (.alwaysAllowed, false),
            (.willPrompt, false),
            (.denied, true),
            (.preEnforcement(reason: "requires macOS 15.4"), false),
        ]
        for (status, expectedPause) in cases {
            #expect(PasteboardAccessClassifier.shouldPauseCapture(for: status) == expectedPause)
        }
    }

    @Test("displayLabel is non-empty and distinct per status")
    func displayLabelsAreDistinct() {
        let statuses: [PasteboardAccessStatus] = [
            .alwaysAllowed, .willPrompt, .denied, .preEnforcement(reason: "x"),
        ]
        let labels = Set(statuses.map(\.displayLabel))
        #expect(labels.count == statuses.count)
        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    // MARK: - PasteboardAccessMonitor (injectable probe)

    #if os(macOS)
    @Test("monitor.refresh() only fires onStatusChange when the probe result actually changes")
    @MainActor
    func monitorFiresOnlyOnChange() {
        var current = PasteboardAccessStatus.willPrompt
        let monitor = PasteboardAccessMonitor(probe: { current })
        var changeCount = 0
        monitor.onStatusChange = { _ in changeCount += 1 }

        monitor.refresh()  // same value as init — no change
        #expect(changeCount == 0)
        #expect(monitor.status == .willPrompt)

        current = .denied
        monitor.refresh()
        #expect(changeCount == 1)
        #expect(monitor.status == .denied)

        monitor.refresh()  // still denied — no repeat notification
        #expect(changeCount == 1)
    }
    #endif

    // MARK: - SecureInputGuard

    #if os(macOS)
    @Test("shouldSkip returns false and doesn't count when probe reports inactive")
    func secureInputInactiveDoesNotSkip() {
        let before = SecureInputGuard.skipCount
        let skipped = SecureInputGuard.shouldSkip(probe: { false })
        #expect(skipped == false)
        #expect(SecureInputGuard.skipCount == before)
    }

    @Test("shouldSkip returns true and bumps the counter when probe reports active")
    func secureInputActiveSkipsAndCounts() {
        let before = SecureInputGuard.skipCount
        let skipped = SecureInputGuard.shouldSkip(probe: { true })
        #expect(skipped == true)
        #expect(SecureInputGuard.skipCount == before + 1)
    }
    #endif

    // MARK: - PasteboardPreReadClassifier (pure string half)

    #if os(macOS)
    @Test("otpauth:// URIs are classified as secret-shaped")
    func otpauthURIsAreSecretShaped() {
        let cases = [
            "otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP",
            "OTPAUTH://hotp/Example:bob?secret=ABC",
        ]
        for urlString in cases {
            #expect(PasteboardPreReadClassifier.isSecretShapedURLString(urlString))
        }
    }

    @Test("ordinary URLs are not classified as secret-shaped")
    func ordinaryURLsAreNotSecretShaped() {
        let cases = [
            "https://example.com",
            "http://example.com/otpauth-lookalike",
            "",
            "mailto:alice@example.com",
        ]
        for urlString in cases {
            #expect(!PasteboardPreReadClassifier.isSecretShapedURLString(urlString))
        }
    }
    #endif
}
