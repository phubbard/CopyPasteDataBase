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
struct Storage: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "storage",
        abstract: "Show disk usage broken down by tier (metadata / thumbnails / flavor bodies)."
    )

    func run() throws {
        let store = try Store.open()
        let report = try StorageInspector.report(store: store)
        print(report.formatted())
    }
}
#endif
