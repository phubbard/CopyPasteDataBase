#if os(macOS)
import ArgumentParser
import CpdbCore
import CpdbShared
import Foundation

/// `cpdb fetch-link-titles` — background-fetch human-readable
/// titles for kind=link entries. YouTube URLs hit the public
/// oEmbed endpoint; everything else gets an HTML scrape for
/// og:title / <title>. Results land in `entries.link_title` and the
/// FTS5 index, so future searches can find a clipped link by the
/// page's name.
///
/// The Mac daemon runs this automatically (small batches, hourly).
/// This command exists for manual cleanup, scripted bulk runs, and
/// the post-offline retry path (combined with `--force`).
struct FetchLinkTitles: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch-link-titles",
        abstract: "Background-fetch page / video titles for captured URLs."
    )

    @Option(name: .long, help: "Maximum entries to process this run.")
    var limit: Int = 200

    @Flag(name: .long, help: "Refetch entries that already have a fetched_at sentinel.")
    var force: Bool = false

    @Flag(name: .long, help: "Show what would be fetched without doing the work.")
    var dryRun: Bool = false

    func run() throws {
        let store = try Store.open()
        let repo = EntryRepository(store: store)
        let candidates = try repo.linksNeedingMetadata(limit: limit, force: force)
        print("\(candidates.count) link entries to process (force=\(force), limit=\(limit))")
        if dryRun || candidates.isEmpty {
            for c in candidates.prefix(10) {
                print("  id=\(c.entryId)  \(c.url.prefix(70))")
            }
            if candidates.count > 10 {
                print("  … and \(candidates.count - 10) more")
            }
            return
        }

        // Run the backfill. Async work — bridge through
        // DispatchSemaphore so ParsableCommand's sync `run()` can
        // wait. ArgumentParser doesn't support async run() yet.
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var collectedReport: LinkMetadataBackfiller.Report?
        nonisolated(unsafe) var collectedError: Error?
        Task {
            do {
                let backfiller = LinkMetadataBackfiller(repository: repo)
                let report = try await backfiller.runOnce(limit: limit, force: force) { idx, total, row, result, error in
                    let title = result?.title?.prefix(60) ?? "(failed)"
                    let host = URL(string: row.url)?.host ?? "?"
                    if let error = error {
                        print("  [\(idx)/\(total)] \(host) — error: \(error)")
                    } else {
                        print("  [\(idx)/\(total)] \(host) — \(title)")
                    }
                }
                collectedReport = report
            } catch {
                collectedError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = collectedError {
            print("error: \(error)")
            throw ExitCode.failure
        }
        if let report = collectedReport {
            print("done: \(report.summary)")
        }
    }
}
#endif
