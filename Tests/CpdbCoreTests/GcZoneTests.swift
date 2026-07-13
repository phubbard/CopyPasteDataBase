import Testing
import Foundation
import CloudKit
@testable import CpdbShared

/// Unit tests for the `gc-zone` guard logic. Exercises `GcZone.run`
/// directly against `FakeCloudKitClient` — no ArgumentParser, no
/// network, no `LiveCloudKitClient`.
@Suite("gc-zone")
struct GcZoneTests {
    private static let legacyZoneID = CKRecordZone.ID(
        zoneName: CKSchema.legacyZoneName,
        ownerName: CKCurrentUserDefaultName
    )

    @Test
    func refusesActiveZone() async throws {
        let client = FakeCloudKitClient()
        await #expect(throws: GcZone.GcZoneError.refusedActiveZone(CKSchema.zoneName)) {
            _ = try await GcZone.run(
                zoneName: CKSchema.zoneName,
                force: false,
                containerID: "iCloud.test",
                client: client
            )
        }
        // The refusal must happen before any CloudKit call — pins the
        // guard order against a future refactor that moves the rail
        // after the fetch.
        #expect(await client.fetchAllZonesCallCount == 0)
        #expect(await client.deletedZones.isEmpty)
    }

    @Test
    func refusesActiveZoneEvenWithForce() async throws {
        let client = FakeCloudKitClient()
        await #expect(throws: GcZone.GcZoneError.refusedActiveZone(CKSchema.zoneName)) {
            _ = try await GcZone.run(
                zoneName: CKSchema.zoneName,
                force: true,
                containerID: "iCloud.test",
                client: client
            )
        }
        #expect(await client.fetchAllZonesCallCount == 0)
        #expect(await client.deletedZones.isEmpty)
    }

    @Test
    func refusesNonLegacyZoneName() async throws {
        let client = FakeCloudKitClient()
        await #expect(throws: GcZone.GcZoneError.refusedUnknownZone(
            requested: "some-other-zone",
            onlyLegal: CKSchema.legacyZoneName
        )) {
            _ = try await GcZone.run(
                zoneName: "some-other-zone",
                force: false,
                containerID: "iCloud.test",
                client: client
            )
        }
        #expect(await client.fetchAllZonesCallCount == 0)
        #expect(await client.deletedZones.isEmpty)
    }

    @Test
    func missingZoneIsIdempotent() async throws {
        let client = FakeCloudKitClient()
        // existingZones left empty — legacy zone not present server-side.
        let outcome = try await GcZone.run(
            zoneName: CKSchema.legacyZoneName,
            force: false,
            containerID: "iCloud.test",
            client: client
        )
        #expect(outcome == .alreadyGone)
        let deleted = await client.deletedZones
        #expect(deleted.isEmpty)
    }

    @Test
    func dryRunDoesNotDelete() async throws {
        let client = FakeCloudKitClient()
        await client.setExistingZones([Self.legacyZoneID])
        let outcome = try await GcZone.run(
            zoneName: CKSchema.legacyZoneName,
            force: false,
            containerID: "iCloud.test",
            client: client
        )
        #expect(outcome == .dryRun(containerID: "iCloud.test"))
        let deleted = await client.deletedZones
        #expect(deleted.isEmpty)
        let stillThere = await client.existingZones
        #expect(stillThere.contains(Self.legacyZoneID))
    }

    @Test
    func forceDeletesAndVerifies() async throws {
        let client = FakeCloudKitClient()
        await client.setExistingZones([Self.legacyZoneID])
        let outcome = try await GcZone.run(
            zoneName: CKSchema.legacyZoneName,
            force: true,
            containerID: "iCloud.test",
            client: client
        )
        #expect(outcome == .deleted)
        let deleted = await client.deletedZones
        #expect(deleted == [Self.legacyZoneID])
        let stillThere = await client.existingZones
        #expect(!stillThere.contains(Self.legacyZoneID))
    }

    @Test
    func forceRaisesIfDeletionDidNotTake() async throws {
        let client = FakeCloudKitClient()
        await client.setExistingZones([Self.legacyZoneID])
        await client.setInjected(.init(zoneDeleteIsNoOp: true))
        await #expect(throws: GcZone.GcZoneError.verificationFailed(CKSchema.legacyZoneName)) {
            _ = try await GcZone.run(
                zoneName: CKSchema.legacyZoneName,
                force: true,
                containerID: "iCloud.test",
                client: client
            )
        }
    }
}
