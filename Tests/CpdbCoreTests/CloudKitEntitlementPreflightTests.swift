import Testing
import Foundation
@testable import CpdbShared

/// Tests for `CloudKitEntitlementPreflight`, the guard that keeps a CLI
/// process from constructing `LiveCloudKitClient` (and hitting its
/// uncatchable `CKContainer` trap) when it lacks the iCloud entitlement.
/// `verify(check:)` takes an injected closure so these run without a
/// real, differently-signed test binary.
@Suite("CloudKit entitlement preflight")
struct CloudKitEntitlementPreflightTests {

    @Test("verify() passes silently when the injected check reports entitled")
    func passesWhenEntitled() throws {
        try CloudKitEntitlementPreflight.verify(check: { true })
    }

    @Test("verify() throws missingEntitlement when the injected check reports not entitled")
    func throwsWhenNotEntitled() {
        #expect(throws: CloudKitEntitlementPreflight.PreflightError.missingEntitlement) {
            try CloudKitEntitlementPreflight.verify(check: { false })
        }
    }

    @Test("PreflightError's description mentions the entitlement and the app's Sync Now")
    func descriptionIsActionable() {
        let message = CloudKitEntitlementPreflight.PreflightError.missingEntitlement.description
        #expect(message.contains(CloudKitEntitlementPreflight.requiredEntitlement))
        #expect(message.contains("Sync Now"))
    }
}
