#if os(macOS)
import ArgumentParser
import CpdbCore
import CpdbShared
import CloudKit
import Foundation
import GRDB

/// `cpdb sync` — ad-hoc drivers for the CloudKit syncer.
///
/// These run the same push/pull paths the Mac app runs in its
/// background loop, but as one-shot commands. Useful for debugging a
/// stuck sync without having to quit/relaunch the app, and for the
/// second-Mac install flow where you want to see the initial pull
/// land before wiring auto-launch.
struct Sync: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Drive the CloudKit syncer manually.",
        subcommands: [
            SyncStatus.self,
            SyncPushOnce.self,
            SyncPullOnce.self,
            SyncGcZone.self,
        ]
    )
}

// MARK: - status

struct SyncStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show queue depth, last-sync timestamp, and recent errors."
    )

    func run() throws {
        let store = try Store.open()
        let (queued, withErrors, oldestErr) = try store.dbQueue.read { db -> (Int, Int, String?) in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloudkit_push_queue") ?? 0
            let errs  = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloudkit_push_queue WHERE last_error IS NOT NULL") ?? 0
            let firstErr = try String.fetchOne(
                db,
                sql: "SELECT last_error FROM cloudkit_push_queue WHERE last_error IS NOT NULL ORDER BY attempt_count DESC LIMIT 1"
            )
            return (total, errs, firstErr)
        }
        print("Push queue: \(queued) pending (\(withErrors) with errors)")
        if let err = oldestErr {
            print("Most-retried error: \(err)")
        }
        let last = UserDefaults.standard.double(forKey: CloudKitSyncer.lastSyncSuccessKey)
        if last > 0 {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            print("Last successful pull: \(formatter.string(from: Date(timeIntervalSince1970: last)))")
        } else {
            print("Last successful pull: never")
        }
    }
}

// MARK: - push-once

struct SyncPushOnce: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push-once",
        abstract: "Drain one batch from the push queue to CloudKit."
    )

    @Option(name: .long, help: "Max records per batch (default 200).")
    var batch: Int = 200

    func run() throws {
        try requireCloudKitEntitlement()
        let store = try Store.open()
        let syncer = try makeSyncer(store: store, batchSize: batch)
        let report = runBlocking { try await syncer.pushPendingChanges() }
        let gatedSuffix = report.gated ? " [GATED — sync paused for identity cutover, not idle]" : ""
        print("push: attempted=\(report.attempted) saved=\(report.saved) failed=\(report.failed) remaining=\(report.remaining)\(gatedSuffix)")
    }
}

// MARK: - pull-once

struct SyncPullOnce: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull-once",
        abstract: "Pull all remote changes from CloudKit into the local store."
    )

    @Flag(name: .long, help: "Discard the stored change token and start from scratch.")
    var reset: Bool = false

    func run() throws {
        let store = try Store.open()
        // --reset is a local-only rail (just clears the stored change
        // token) — it must run BEFORE the entitlement gate, same
        // reasoning as `gc-zone`'s string-only rails: it doesn't touch
        // CloudKit at all, and gating it behind an entitlement check
        // that the shipped CLI can never pass would make `--reset`
        // permanently unreachable from this command.
        if reset {
            try store.dbQueue.write { db in
                try PushQueue.State.delete(PushQueue.StateKey.zoneChangeToken, in: db)
            }
            print("cleared stored change token — next pull will fetch everything")
        }
        try requireCloudKitEntitlement()
        let syncer = try makeSyncer(store: store)
        let report = runBlocking { try await syncer.pullRemoteChanges() }
        let gatedSuffix = report.gated ? " [GATED — sync paused for identity cutover, not idle]" : ""
        print("pull: inserted=\(report.inserted) updated=\(report.updated) tombstoned=\(report.tombstoned) skipped=\(report.skipped)\(gatedSuffix)")
    }
}

// MARK: - gc-zone

struct SyncGcZone: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc-zone",
        abstract: "Delete the abandoned legacy CloudKit zone (whole-zone only).",
        discussion: """
            Refuses anything except the one known legacy zone (\(CKSchema.legacyZoneName)) — \
            never the live zone, never an arbitrary name. Without --force this is a dry \
            run: it reports whether the zone exists and does not delete it.
            """
    )

    @Argument(help: "Zone name to delete — must be the legacy zone.")
    var zoneName: String

    @Flag(name: .long, help: "Actually delete the zone (default is a dry run).")
    var force: Bool = false

    func run() throws {
        // Deliberately does not open the local store: gc-zone only
        // touches the CloudKit zone list, never local data.
        //
        // Rails (a)/(b) MUST run before `LiveCloudKitClient` is
        // constructed: that init calls `CKContainer(identifier:)`,
        // which traps (SIGTRAP, no output) on a binary without iCloud
        // entitlements — which includes this shipped CLI. Without this,
        // even `gc-zone cpdb-v3` (which must cleanly refuse with exit
        // 2) would crash instead.
        do {
            try GcZone.precheck(zoneName: zoneName)
        } catch let error as GcZone.GcZoneError {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            throw ExitCode(2)
        }
        // Same entitlement gate as push-once/pull-once, run right after
        // the string-only rails above (which must stay first — they
        // don't need CloudKit at all and should refuse a bad zone name
        // even on an unentitled binary).
        try requireCloudKitEntitlement()

        let containerID = "iCloud.\(Paths.bundleId)"
        let client = LiveCloudKitClient(containerIdentifier: containerID)
        do {
            let outcome = try runBlockingThrowing {
                try await GcZone.run(zoneName: zoneName, force: force, containerID: containerID, client: client)
            }
            switch outcome {
            case .alreadyGone:
                print("already gone")
            case .dryRun(let containerID):
                print("""
                    DRY RUN — zone \"\(zoneName)\" exists in container \(containerID).
                    Deleting it removes every record inside permanently and cannot be undone.
                    Re-run with --force to delete it.
                    """)
            case .deleted:
                print("deleted \"\(zoneName)\" — confirmed gone from the zone list")
            }
        } catch let error as GcZone.GcZoneError {
            // Refusals (a)/(b) are usage errors — exit 2, distinct from
            // the generic failure exit `runBlocking` uses elsewhere.
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            switch error {
            case .refusedActiveZone, .refusedUnknownZone:
                throw ExitCode(2)
            case .verificationFailed:
                throw ExitCode(1)
            }
        }
    }
}

// MARK: - helpers

/// Exits 2 with a clear message instead of letting `LiveCloudKitClient`'s
/// init trap (SIGTRAP, no output) on a process that lacks the iCloud
/// entitlement — which the shipped CLI binary always is. Call before
/// constructing any `LiveCloudKitClient`. See
/// `CloudKitEntitlementPreflight`'s doc comment for the full story.
private func requireCloudKitEntitlement() throws {
    do {
        try CloudKitEntitlementPreflight.verify()
    } catch let error as CloudKitEntitlementPreflight.PreflightError {
        FileHandle.standardError.write("\(error.description)\n".data(using: .utf8)!)
        throw ExitCode(2)
    }
}

private func makeSyncer(store: Store, batchSize: Int = 200) throws -> CloudKitSyncer {
    let containerID = "iCloud.\(Paths.bundleId)"
    let client = LiveCloudKitClient(containerIdentifier: containerID)
    let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    let deviceID = DeviceIdentity.hardwareUUID() ?? ProcessInfo.processInfo.hostName
    return CloudKitSyncer(
        store: store,
        client: client,
        device: .init(identifier: deviceID, name: deviceName),
        batchSize: batchSize
    )
}

/// Bridge an async call into a synchronous ParsableCommand.run(). We
/// need this because ArgumentParser's `run()` is sync-only on 5.9 and
/// our syncer is an actor. A semaphore is the simplest safe bridge for
/// CLI startup code.
private func runBlocking<T: Sendable>(_ block: @Sendable @escaping () async throws -> T) -> T {
    do {
        return try runBlockingThrowing(block)
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

/// Same bridge as `runBlocking`, but rethrows instead of exiting directly
/// — gc-zone needs to inspect the error to pick an exit code (2 for a
/// safety-rail refusal vs. 1 for anything else).
private func runBlockingThrowing<T: Sendable>(_ block: @Sendable @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task {
        do {
            result = .success(try await block())
        } catch {
            result = .failure(error)
        }
        sem.signal()
    }
    sem.wait()
    return try result.get()
}
#endif
