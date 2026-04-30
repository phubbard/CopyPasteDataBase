import Foundation

/// Drives a batched link-metadata fetch. Pulls candidate rows from
/// `EntryRepository.linksNeedingMetadata`, fans out fetches with a
/// concurrency cap, persists the results back through the
/// repository.
///
/// Two callers today:
///   - The Mac daemon's hourly backfill task (small batches, cheap).
///   - The `cpdb fetch-link-titles` CLI (larger batches, with
///     progress).
///
/// The fetcher is tolerant: a network failure on one URL doesn't
/// stop the others, and the failed entry gets `link_fetched_at`
/// stamped anyway so it's not retried until the user explicitly
/// resets via the Preferences "Refetch" button or
/// `cpdb fetch-link-titles --force`.
public struct LinkMetadataBackfiller {
    public let repository: EntryRepository
    public let fetcher: LinkMetadataFetcher
    /// Max simultaneous in-flight fetches. 4 is gentle on the host
    /// network and on the user's bandwidth without being slow.
    public var concurrency: Int = 4

    public init(
        repository: EntryRepository,
        fetcher: LinkMetadataFetcher = LinkMetadataFetcher()
    ) {
        self.repository = repository
        self.fetcher = fetcher
    }

    /// Outcome of one backfill run. Logged by both callers; the
    /// CLI also prints per-row progress so the user sees something
    /// happening on a 1k-row backfill.
    public struct Report: Sendable {
        public var attempted: Int
        public var successes: Int
        public var emptyResults: Int   // page returned, no title found
        public var failures: Int

        public init(
            attempted: Int = 0,
            successes: Int = 0,
            emptyResults: Int = 0,
            failures: Int = 0
        ) {
            self.attempted = attempted
            self.successes = successes
            self.emptyResults = emptyResults
            self.failures = failures
        }

        public var summary: String {
            "attempted=\(attempted) ok=\(successes) empty=\(emptyResults) fail=\(failures)"
        }
    }

    /// Run a single batch. Caller decides batch size + force flag.
    /// Returns the report after every fetch has settled.
    @discardableResult
    public func runOnce(
        limit: Int = 200,
        force: Bool = false,
        progress: (@Sendable (Int, Int, EntryRepository.LinkBackfillRow, LinkMetadataFetcher.Result?, Error?) -> Void)? = nil
    ) async throws -> Report {
        let candidates = try repository.linksNeedingMetadata(limit: limit, force: force)
        guard !candidates.isEmpty else { return Report() }

        // Bounded-concurrency task group. Each task fetches one URL
        // and persists immediately so the DB sees progress as we go
        // (resilient to mid-batch crashes — work isn't lost).
        let total = candidates.count
        let repository = self.repository
        let fetcher = self.fetcher
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            var index = 0
            var inflight = 0
            var report = Report(attempted: total)
            while index < candidates.count || inflight > 0 {
                while inflight < self.concurrency, index < candidates.count {
                    let row = candidates[index]
                    let position = index + 1
                    group.addTask {
                        do {
                            let result = try await fetcher.fetch(urlString: row.url)
                            try repository.setLinkMetadata(entryId: row.entryId, title: result.title)
                            // Phase 2: opportunistically download the
                            // thumbnail bytes (og:image / oEmbed
                            // thumbnail_url), generate small + large
                            // JPEGs, and write to the `previews`
                            // table so LinkCard can render them.
                            // Best-effort — failures are silent:
                            // there's no separate sentinel, the
                            // user can hit "Refetch all" to retry.
                            if let thumbURL = result.thumbnailURL {
                                if let bytes = await fetcher.fetchThumbnailBytes(url: thumbURL) {
                                    let thumbs = Thumbnailer.generate(from: bytes)
                                    if thumbs.small != nil || thumbs.large != nil {
                                        try? repository.setLinkPreviewThumbnails(
                                            entryId: row.entryId,
                                            small: thumbs.small,
                                            large: thumbs.large
                                        )
                                    }
                                }
                            }
                            return Outcome(row: row, result: result, error: nil, position: position)
                        } catch {
                            // Stamp the failure so we don't retry
                            // this URL on every cycle. Reset via
                            // resetLinkFetchedAt() lets the user
                            // retry deliberately.
                            try? repository.setLinkMetadata(entryId: row.entryId, title: nil)
                            return Outcome(row: row, result: nil, error: error, position: position)
                        }
                    }
                    index += 1
                    inflight += 1
                }
                if let outcome = try await group.next() {
                    inflight -= 1
                    progress?(outcome.position, total, outcome.row, outcome.result, outcome.error)
                    if let result = outcome.result {
                        if result.title?.isEmpty == false {
                            report.successes += 1
                        } else {
                            report.emptyResults += 1
                        }
                    } else {
                        report.failures += 1
                    }
                }
            }
            return report
        }
    }

    private struct Outcome: Sendable {
        let row: EntryRepository.LinkBackfillRow
        let result: LinkMetadataFetcher.Result?
        let error: (any Error)?
        let position: Int
    }
}
