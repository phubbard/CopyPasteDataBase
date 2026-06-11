#if os(macOS)
import ArgumentParser
import CpdbCore
import CpdbShared
import Foundation

/// `cpdb migrate-identity` — run the canonical-hash v2 identity cutover
/// (docs/canonical-hash-v2.md §4) explicitly, with progress on stdout, then
/// verify. This is how the maintainer drives the first device's cutover
/// with full observability instead of leaving it to a silent app-launch
/// run. The app also runs the cutover on launch (for unattended devices);
/// the cross-process lock makes the two mutually exclusive.
///
/// Safe to re-run: returns immediately if the cutover already completed.
struct MigrateIdentity: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate-identity",
        abstract: "Run the canonical-hash v2 identity cutover (rehash + merge + reseed), then verify."
    )

    @Flag(name: .long, help: "Report what would happen without running the cutover.")
    var status = false

    @Option(name: .long, help: "Sample size for the post-cutover hash verification (default 300).")
    var verifySample: Int = 300

    func run() throws {
        // The store must NOT be opened by the running app concurrently in a
        // way that fights the cutover — the cross-process cutover lock
        // guards run(), but capture writes during the rehash are avoided by
        // the caller quitting the app first (documented in the runbook).
        let store = try Store.open()

        if status {
            let pending = try IdentityCutover.isPending(store)
            print("identity cutover pending: \(pending)")
            if !pending {
                let v = try IdentityCutover.verifyHashes(store: store, sample: verifySample)
                print("verify: \(v.checked) checked, \(v.mismatched.count) mismatched, \(v.unreadable.count) unreadable")
            }
            return
        }

        guard try IdentityCutover.isPending(store) else {
            print("identity cutover already complete — nothing to do")
            return
        }

        let snapshotURL = IdentityCutover.defaultSnapshotURL(forDatabaseAt: Paths.databaseURL.path)
        print("running identity cutover (snapshot → \(snapshotURL.lastPathComponent))…")

        let outcome = try runAsync {
            try await IdentityCutover.run(
                store: store,
                snapshotURL: snapshotURL,
                // Primary device has an empty push queue (verified before
                // install); a non-empty queue blocks safely rather than
                // proceeding. The gate-bypassing legacy-zone drain is a
                // follow-up for secondary devices.
                drainPushQueue: nil,
                progress: { print("  • \($0)") }
            )
        }

        switch outcome {
        case .notNeeded:
            print("nothing to migrate")
        case .alreadyRunning:
            print("another process is running the cutover — try again once it finishes")
            throw ExitCode(2)
        case .blockedOnPushQueue(let n):
            print("BLOCKED: \(n) pending push(es) to the old zone must drain first.")
            print("  Launch the previous build, let it finish syncing (queue → 0), then retry.")
            throw ExitCode(3)
        case .completed(let report):
            print("""
                cutover complete:
                  rehashed:            \(report.rehashed)
                  kept v1 (evicted):   \(report.keptV1Evicted)
                  kept v1 (no flavor): \(report.keptV1ZeroFlavor)
                  kept v1 (no blob):   \(report.keptV1MissingBlob)
                  clusters merged:     \(report.clustersMerged)
                  losers tombstoned:   \(report.losersTombstoned)
                  zombies swept:       \(report.zombiesSwept)
                  reseeded for push:   \(report.reseeded)
                """)
            let v = try IdentityCutover.verifyHashes(store: store, sample: verifySample)
            print("verify: \(v.checked) checked, \(v.mismatched.count) mismatched, \(v.unreadable.count) unreadable")
            if !v.mismatched.isEmpty {
                print("MISMATCHES: \(v.mismatched.map(String.init).joined(separator: ", "))")
                throw ExitCode(1)
            }
            print("✓ verification clean — sync will re-enable after the next pull")
        }
    }

    /// Bridge the async cutover into ArgumentParser's sync `run()`.
    private func runAsync<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task {
            do { box.value = .success(try await body()) }
            catch { box.value = .failure(error) }
            sem.signal()
        }
        sem.wait()
        switch box.value {
        case .success(let v)?: return v
        case .failure(let e)?: throw e
        case nil: throw ExitCode(70)
        }
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }
}
#endif
