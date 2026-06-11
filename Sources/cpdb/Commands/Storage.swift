#if os(macOS)
import ArgumentParser
import CpdbCore
import CpdbShared
import Foundation

/// `cpdb storage` — print a tabular breakdown of what's eating disk
/// space in the local cpdb library. Three layers: metadata (always
/// kept), thumbnails (always kept), flavor bodies (evictable).
///
/// Useful for deciding whether to enable the time-window or
/// size-budget eviction policies in Preferences. Also surfaces the
/// number of pinned entries (which skip eviction).
///
/// `--verify-hashes` is the canonical-hash-v2 post-migration check
/// (docs/canonical-hash-v2.md §4.5): recompute semantic identity for a
/// random sample of live v2 rows and compare against the stored hash.
/// Run it on each device after its cutover completes.
struct Storage: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "storage",
        abstract: "Show disk usage broken down by tier (metadata / thumbnails / flavor bodies)."
    )

    @Flag(name: .long, help: "Recompute content identity for a sample of rows and compare against stored hashes (canonical-hash v2 §4.5 verification).")
    var verifyHashes = false

    @Option(name: .long, help: "Sample size for --verify-hashes (default 200).")
    var sample: Int = 200

    func run() throws {
        let store = try Store.open()
        if verifyHashes {
            if try IdentityCutover.isPending(store) {
                print("identity cutover has not completed on this database — nothing to verify yet")
                throw ExitCode(2)
            }
            let result = try IdentityCutover.verifyHashes(store: store, sample: sample)
            print("verified \(result.checked) sampled entries against recomputed identity")
            if !result.unreadable.isEmpty {
                print("  \(result.unreadable.count) skipped (blob unreadable): ids \(result.unreadable.map(String.init).joined(separator: ", "))")
            }
            if result.mismatched.isEmpty {
                print("  all hashes match ✓")
            } else {
                print("  MISMATCHES (\(result.mismatched.count)): ids \(result.mismatched.map(String.init).joined(separator: ", "))")
                print("  a mismatch means the stored hash was not produced from the stored flavors — investigate before trusting sync")
                throw ExitCode(1)
            }
            return
        }
        let report = try StorageInspector.report(store: store)
        print(report.formatted())
    }
}
#endif
