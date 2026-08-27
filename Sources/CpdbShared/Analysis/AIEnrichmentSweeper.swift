import Foundation

/// Self-heals text entries that never got an on-device AI title/summary.
/// Mirrors `ImageAnalysisSweeper`'s architecture exactly (see that type's
/// doc comment for the fuller rationale): a batched, repeatable pass over
/// `EntryRepository.entriesNeedingAIEnrichment`, driven by a periodic tick
/// and a capture-wake observer, both wired up in `AppDelegate`.
///
/// The gaps this closes are the same shape as the image sweep's:
///   1. Pull-synced text. A Mac that receives a text entry via CloudKit
///      pull never runs `AIService` on it locally — only the capturing
///      device's `Ingestor.ingest` does that, and only at the instant of
///      capture.
///   2. A killed capture-time Task. `Ingestor`'s `Task.detached` isn't
///      durable — if the app quits mid-generation, that one shot is gone.
///
/// Unlike the image sweep, this does no Vision/CPU-heavy decode work and
/// unlike the link backfill it does no networking (on-device generation
/// only) — but an LLM call still takes real wall-clock time (seconds),
/// hence the small `limit` default.
///
/// Batch size is capped small: `AIService.generateTitleAndSummary` is
/// comparatively expensive (real generation, not a cheap DB read), and
/// unlike Vision there's no fixed per-call budget to reason about, so a
/// small default keeps one sweep pass bounded even on a slow model load.
public struct AIEnrichmentSweeper {
    public let repository: EntryRepository

    /// Maximum consecutive failed enrichment attempts before a row falls
    /// out of `entriesNeedingAIEnrichment`'s candidate set — see that
    /// method's doc comment and the `v13_ai_enrichment_retry_cap`
    /// migration. Deliberately small: unlike the link backfill's
    /// transient-failure retries (rate limits, network blips that
    /// genuinely resolve on their own), an on-device generation failure
    /// for a given input is normally deterministic (a guardrail
    /// rejection, a context-window overflow) — a handful of attempts is
    /// plenty to also absorb a merely-flaky one (a momentary model
    /// asset eviction) without leaving a truly-stuck row occupying a
    /// candidate slot indefinitely.
    public static let maxRetries = 3

    public init(repository: EntryRepository) {
        self.repository = repository
    }

    /// Outcome of one sweep pass. Logged by the caller.
    public struct Report: Sendable, Equatable {
        public var candidates: Int = 0
        /// Actually generated and persisted a title/summary.
        public var enriched: Int = 0
        /// Skipped because a sibling — or this Mac's own capture-time
        /// path — already enriched the row since the candidate list was
        /// built. Not a failure; duplicate generation avoided.
        public var alreadyEnriched: Int = 0
        /// Generation ran but produced nothing usable (model
        /// unavailable, empty/refused result, or a persistence error).
        /// The entry stays `ai_title IS NULL`, `ai_retry_count` is
        /// bumped, and it's retried next pass — until it hits
        /// `maxRetries`, after which `entriesNeedingAIEnrichment` stops
        /// selecting it.
        public var failed: Int = 0

        public init(candidates: Int = 0, enriched: Int = 0, alreadyEnriched: Int = 0, failed: Int = 0) {
            self.candidates = candidates
            self.enriched = enriched
            self.alreadyEnriched = alreadyEnriched
            self.failed = failed
        }

        public var summary: String {
            "candidates=\(candidates) enriched=\(enriched) alreadyEnriched=\(alreadyEnriched) failed=\(failed)"
        }
    }

    /// Run one batch, capped at `limit` entries, newest-first. Hard-skips
    /// (returns an empty report without even querying candidates) when
    /// the AI enrichment preference is off or Foundation Models isn't
    /// available — cheap, since `AIService.availability` never touches
    /// the database.
    ///
    /// Per-entry failures are caught and logged rather than propagated,
    /// same convention as `ImageAnalysisSweeper.runOnce`: one bad entry
    /// must not wedge every older candidate behind it on every future
    /// pass. Each failure also bumps `ai_retry_count` (via
    /// `recordAIEnrichmentFailure`) so a row that keeps failing falls out
    /// of `entriesNeedingAIEnrichment`'s candidate set after
    /// `maxRetries` attempts instead of occupying a slot forever.
    @discardableResult
    public func runOnce(limit: Int = 5) async throws -> Report {
        guard AIEnrichmentPrefs.load().enabled else { return Report() }
        guard AIService.availability == .available else { return Report() }

        let candidates = try repository.entriesNeedingAIEnrichment(
            limit: limit,
            minLength: AIService.longTextThreshold
        )
        guard !candidates.isEmpty else { return Report() }

        var report = Report(candidates: candidates.count)
        for candidate in candidates {
            do {
                // Re-check immediately before the expensive generation
                // call — see `EntryRepository.isAIUnenriched`'s doc
                // comment for the race this closes.
                guard try repository.isAIUnenriched(entryId: candidate.entryId) else {
                    report.alreadyEnriched += 1
                    continue
                }
                let wrote = await AIService.enrichEntry(
                    entryId: candidate.entryId,
                    text: candidate.textPreview,
                    repository: repository
                )
                if wrote {
                    report.enriched += 1
                } else {
                    // AIService.enrichEntry already bumped ai_retry_count
                    // for this entry (see its doc comment) — nothing
                    // further to do here beyond tallying the report.
                    report.failed += 1
                }
            } catch {
                report.failed += 1
                Log.capture.error(
                    "ai-enrichment sweep: entry \(candidate.entryId, privacy: .public) failed, skipping (will retry next pass): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return report
    }
}
