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
        let store = try Store.open()
        let syncer = try makeSyncer(store: store, batchSize: batch)
        let report = runBlocking { try await syncer.pushPendingChanges() }
        print("push: attempted=\(report.attempted) saved=\(report.saved) failed=\(report.failed) remaining=\(report.remaining)")
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
        if reset {
            try store.dbQueue.write { db in
                try PushQueue.State.delete(PushQueue.StateKey.zoneChangeToken, in: db)
            }
            print("cleared stored change token — next pull will fetch everything")
        }
        let syncer = try makeSyncer(store: store)
        let report = runBlocking { try await syncer.pullRemoteChanges() }
        print("pull: inserted=\(report.inserted) updated=\(report.updated) tombstoned=\(report.tombstoned) skipped=\(report.skipped)")
    }
}

// MARK: - helpers

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
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task {
        do {
            let v = try await block()
            result = .success(v)
        } catch {
            result = .failure(error)
        }
        sem.signal()
    }
    sem.wait()
    switch result! {
    case .success(let v): return v
    case .failure(let e):
        FileHandle.standardError.write("error: \(e)\n".data(using: .utf8)!)
        exit(1)
    }
}
#endif
