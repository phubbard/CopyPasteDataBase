import Foundation

/// Self-heals images that never got OCR/tags. Before this existed, image
/// analysis ran EXACTLY ONCE — a detached Task fired by `Ingestor` right
/// after a fresh capture, on the capturing device only. Two gaps fell out
/// of that design:
///
///   1. Pull-synced images. A Mac that receives an image entry via
///      CloudKit pull never runs `ImageIndexer` on it locally — only the
///      device that originally captured it does. If that device is slow,
///      offline, or (as happened 2026-07-12) gets stuck on a giant image,
///      the entry sits with `analyzed_at IS NULL` forever, unsearchable.
///   2. Killed capture-time Tasks. The `Task.detached` in `Ingestor`
///      isn't durable — if the app quits mid-Vision-call, that one shot
///      is gone with no retry.
///
/// `ImageAnalysisSweeper` closes both gaps with a batched, repeatable
/// pass over `EntryRepository.imagesNeedingAnalysis`, mirroring
/// `LinkMetadataBackfiller`'s architecture (see that type's doc comment):
/// driven by a capture-wake observer for snappy same-Mac recovery and a
/// periodic tick as the real safety net, both wired up in `AppDelegate`.
///
/// Unlike the link backfill, this does no networking — Vision runs
/// on-device — so there's no `Reachability` gate here.
///
/// macOS only. iOS reads OCR/tags via CloudKit sync and never runs
/// Vision locally, by design (a phone shouldn't burn battery/thermal
/// budget re-deriving what a Mac already computed).
public struct ImageAnalysisSweeper {
    public let repository: EntryRepository
    public let blobs: BlobStore
    public var prefs: AnalysisPrefs

    public init(
        repository: EntryRepository,
        blobs: BlobStore = BlobStore(),
        prefs: AnalysisPrefs = .load()
    ) {
        self.repository = repository
        self.blobs = blobs
        self.prefs = prefs
    }

    /// Outcome of one sweep pass. Logged by the caller.
    public struct Report: Sendable, Equatable {
        public var candidates: Int = 0
        /// Actually ran Vision (or the giant-image fallback) and
        /// stamped `analyzed_at`.
        public var analyzed: Int = 0
        /// Skipped because a sibling — or this Mac's own capture-time
        /// path — already analyzed the row since the candidate list
        /// was built. Not a failure; duplicate analysis avoided.
        public var alreadyAnalyzed: Int = 0
        /// Skipped because the entry has no image flavor locally yet.
        /// This is the normal shape of a pull-synced entry whose flavor
        /// records haven't landed — `CloudKitSyncer` pushes entries and
        /// flavors in separate CloudKit operations by design, so a
        /// flavor-less entry row is an expected transient state, not an
        /// error (see `CloudKitSyncer`'s push doc comment). Left
        /// `analyzed_at IS NULL` so a later pass retries once the
        /// flavors arrive; mirrors the CLI's `noImageFlavor` bucket
        /// (`Stubs.swift`'s `analyze-images`), which skips-and-retries
        /// the same condition rather than stamping it analyzed-empty.
        public var skippedNoFlavor: Int = 0
        /// Threw while checking or loading this entry (e.g. a spilled
        /// blob file missing on disk). Logged and skipped — this entry
        /// stays `analyzed_at IS NULL` and is retried next pass, but
        /// the failure does NOT abort the rest of the batch, so one bad
        /// row can't wedge every older candidate behind it forever.
        public var failed: Int = 0

        public init(
            candidates: Int = 0,
            analyzed: Int = 0,
            alreadyAnalyzed: Int = 0,
            skippedNoFlavor: Int = 0,
            failed: Int = 0
        ) {
            self.candidates = candidates
            self.analyzed = analyzed
            self.alreadyAnalyzed = alreadyAnalyzed
            self.skippedNoFlavor = skippedNoFlavor
            self.failed = failed
        }

        public var summary: String {
            "candidates=\(candidates) analyzed=\(analyzed) alreadyAnalyzed=\(alreadyAnalyzed) skippedNoFlavor=\(skippedNoFlavor) failed=\(failed)"
        }
    }

    /// Run one batch, capped at `limit` entries. Newest-first (matches
    /// `imagesNeedingAnalysis`), so a fresh install or a big pull-synced
    /// backlog makes visible progress every pass rather than getting
    /// stuck re-checking the same old rows.
    ///
    /// Per-entry failures are caught and logged rather than propagated:
    /// a single throwing candidate (missing blob file, transient I/O
    /// error) must not abort the whole pass — that would leave every
    /// OLDER unanalyzed entry unreachable on every future pass, since
    /// `imagesNeedingAnalysis` always returns the same newest-first
    /// list until the poisoned row is resolved.
    @discardableResult
    public func runOnce(limit: Int = 15) throws -> Report {
        let candidates = try repository.imagesNeedingAnalysis(limit: limit)
        guard !candidates.isEmpty else { return Report() }

        var report = Report(candidates: candidates.count)
        for entryId in candidates {
            do {
                // Re-check immediately before doing the (expensive)
                // Vision work — see `EntryRepository.isImageUnanalyzed`'s
                // doc comment for why this can go stale between
                // candidate-list build and per-entry work.
                guard try repository.isImageUnanalyzed(entryId: entryId) else {
                    report.alreadyAnalyzed += 1
                    continue
                }
                // `loadImageFlavorData` returning nil means the entry
                // has no image flavor locally YET — most commonly a
                // pull-synced entry whose flavor records are still in
                // flight. Do NOT hand `analyzeAndStore` an empty
                // `Data()` here: that would stamp `analyzed_at` with an
                // empty OCR result and push it, and CloudKit's upsert
                // adopts entry-level `ocr_text`/`analyzed_at`
                // unconditionally on pull (no non-empty-beats-empty
                // comparison) — so this Mac's empty stamp would
                // permanently overwrite a sibling's real OCR fleet-wide
                // the moment it pulls. Skip instead and retry next pass.
                guard let imageData = try repository.loadImageFlavorData(entryId: entryId, blobs: blobs) else {
                    report.skippedNoFlavor += 1
                    continue
                }
                ImageIndexer.analyzeAndStore(
                    entryId: entryId,
                    imageData: imageData,
                    store: repository.store,
                    prefs: prefs
                )
                report.analyzed += 1
            } catch {
                report.failed += 1
                Log.capture.error(
                    "image-analysis sweep: entry \(entryId, privacy: .public) failed, skipping (will retry next pass): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return report
    }
}
