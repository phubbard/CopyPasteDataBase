#if os(macOS)
import ArgumentParser
import CpdbCore
import CpdbShared
import Foundation

/// `cpdb evict` — manually run the time-window eviction policy.
/// Discards flavor body bytes (entry_flavors rows + on-disk blobs)
/// for entries older than `--before-days`. Pinned and tombstoned
/// rows are skipped. Metadata + thumbnails are preserved.
///
/// `--dry-run` lists the candidates without touching anything.
///
/// The daemon runs this automatically once a day when the
/// time-window policy is enabled in Preferences. The CLI is for
/// manual cleanup, debugging, or scripting.
struct Evict: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "evict",
        abstract: "Discard flavor bytes for entries older than --before-days."
    )

    @Option(name: .long, help: "Discard bodies for entries created more than N days ago.")
    var beforeDays: Int = EvictionPrefs.timeWindowDaysDefault

    @Flag(name: .long, help: "Show what would be evicted without writing.")
    var dryRun: Bool = false

    func run() throws {
        let store = try Store.open()
        let evictor = EntryEvictor(store: store)
        let candidates = try evictor.candidatesOlderThan(days: beforeDays)
        print("found \(candidates.count) entries older than \(beforeDays) days with bodies present")

        guard !dryRun, !candidates.isEmpty else {
            if dryRun { print("dry run — no changes written") }
            return
        }

        let report = try evictor.evict(entryIds: candidates)
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        print("evicted \(report.entryCount) entries")
        print("  inline bytes freed: \(fmt.string(fromByteCount: report.inlineFlavorBytesFreed))")
        print("  blob bytes freed:   \(fmt.string(fromByteCount: report.blobBytesFreed))  (\(report.blobsRemoved) blobs)")
        print("  total:              \(fmt.string(fromByteCount: report.totalBytesFreed))")
    }
}
#endif
