import Foundation
import CloudKit

/// Core logic for `cpdb sync gc-zone` — whole-zone deletion of the
/// abandoned `cpdb-v2` zone, factored out of the ArgumentParser command
/// so it's testable against `CloudKitClient` fakes without a network or
/// an entitled binary.
///
/// Deliberately narrow: this command exists to delete exactly one known
/// zone (`CKSchema.legacyZoneName`), not to be a general-purpose zone
/// eraser. See CKSchema.legacyZoneName's doc comment for why targeted
/// per-record deletes are never an option here — only a whole-zone
/// delete is safe once the fleet has cut over.
public enum GcZone {
    /// What happened, for the command layer to print and turn into an
    /// exit code. No case here is itself an error — refusals are
    /// reported via `GcZoneError` instead so the two failure classes
    /// (programmer/usage errors vs. "ran fine, found X") stay distinct.
    public enum Outcome: Sendable, Equatable {
        /// The zone wasn't present server-side. Idempotent success.
        case alreadyGone
        /// Dry run: the zone exists. Carries the container id so the
        /// command can print it.
        case dryRun(containerID: String)
        /// `--force`: the zone was deleted and its absence verified.
        case deleted
    }

    public enum GcZoneError: Error, Equatable, CustomStringConvertible {
        /// Refusal (a): the caller asked to delete the live zone.
        case refusedActiveZone(String)
        /// Refusal (b): the caller asked to delete something other than
        /// the one known legacy zone.
        case refusedUnknownZone(requested: String, onlyLegal: String)
        /// `--force` deleted the zone but a re-fetch still shows it.
        case verificationFailed(String)

        public var description: String {
            switch self {
            case .refusedActiveZone(let name):
                return "refusing to delete \"\(name)\" — that's the live sync zone, not the legacy one"
            case .refusedUnknownZone(let requested, let onlyLegal):
                return "refusing to delete \"\(requested)\" — this command only ever deletes the known legacy zone \"\(onlyLegal)\""
            case .verificationFailed(let name):
                return "deleted \"\(name)\" but it still appears in the zone list — deletion did not take"
            }
        }
    }

    /// Rails (a) and (b) only — pure string compares against
    /// `CKSchema`, no CloudKit client involved. Exists so the command
    /// layer can refuse a bad zone name (including the important case
    /// of the active zone) *before* constructing `LiveCloudKitClient`,
    /// which inits a `CKContainer` and traps with no output on a
    /// binary lacking iCloud entitlements — as the CLI does. `run`
    /// below calls this too, so the rails stay enforced there as well
    /// (defense in depth against a future caller that skips precheck).
    public static func precheck(zoneName: String) throws {
        // Rail (a): never the active zone, no flag overrides this.
        guard zoneName != CKSchema.zoneName else {
            throw GcZoneError.refusedActiveZone(zoneName)
        }
        // Rail (b): only the one known legacy zone is in scope.
        guard zoneName == CKSchema.legacyZoneName else {
            throw GcZoneError.refusedUnknownZone(requested: zoneName, onlyLegal: CKSchema.legacyZoneName)
        }
    }

    /// Run the guarded gc-zone flow.
    ///
    /// - Parameters:
    ///   - zoneName: the zone the caller wants deleted (positional arg).
    ///   - force: skip the dry run and actually delete.
    ///   - containerID: reported in the dry-run message; not used to
    ///     construct anything (the client is already bound to a
    ///     container by the caller).
    ///   - client: the CloudKit client — real or fake.
    public static func run(
        zoneName: String,
        force: Bool,
        containerID: String,
        client: CloudKitClient
    ) async throws -> Outcome {
        // Rails (a)/(b) — see `precheck`. Re-checked here even though
        // the command layer already calls `precheck` before this, so
        // any other caller gets the same safety net.
        try precheck(zoneName: zoneName)

        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let existingBefore = try await client.fetchAllZones()
        guard existingBefore.contains(zoneID) else {
            // Rail (c): idempotent — nothing to do.
            return .alreadyGone
        }

        guard force else {
            // Rail (d): dry run is the default.
            return .dryRun(containerID: containerID)
        }

        // Rail (e): actually delete, then verify.
        try await client.deleteZone(zoneID)
        let existingAfter = try await client.fetchAllZones()
        guard !existingAfter.contains(zoneID) else {
            throw GcZoneError.verificationFailed(zoneName)
        }
        return .deleted
    }
}
