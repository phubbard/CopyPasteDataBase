import Foundation

/// Self-heals text/link entries missing an on-device semantic embedding.
/// Mirrors `ImageAnalysisSweeper`'s architecture and rationale — see that
/// type's doc comment for the two gaps this class of sweeper closes:
///
///   1. Pull-synced entries. A Mac that receives a text/link entry via
///      CloudKit pull never runs `EmbeddingService` on it locally unless
///      swept — only the originating device's capture-time hook does.
///   2. Killed capture-time Tasks. The `Task.detached` in `Ingestor` isn't
///      durable — an app quit mid-embed is gone with no retry outside
///      this sweep.
///
/// Driven the same way as the image sweep: a capture-wake observer for
/// snappy same-Mac recovery plus a periodic tick as the safety net, both
/// wired up in `AppDelegate`.
///
/// Mac-only, same reasoning as `ImageAnalysisSweeper`: generating
/// embeddings is a background CPU cost we don't want to impose on an
/// iPhone's battery/thermal budget for content a Mac will embed anyway
/// and sync down via CloudKit. iOS still reads embeddings via CloudKit
/// pull and may embed a search QUERY locally (`EmbeddingService.embed` has
/// no platform gate itself) — it just never runs this backlog sweep.
public struct EmbeddingSweeper {
    public let repository: EntryRepository

    public init(repository: EntryRepository) {
        self.repository = repository
    }

    /// Outcome of one sweep pass. Logged by the caller.
    public struct Report: Sendable, Equatable {
        public var candidates: Int = 0
        /// Actually embedded and stamped `entry_embeddings`.
        public var embedded: Int = 0
        /// The model itself isn't ready (no assets, unsupported OS). The
        /// whole pass no-ops in this case rather than churning through
        /// candidates one at a time only to fail identically on each.
        public var skippedUnavailable: Int = 0
        /// The entry had no text to embed (empty `text_preview`, or
        /// `EmbeddingService.embed` returned nil for it).
        public var skippedEmpty: Int = 0
        /// Threw while loading or writing this entry. Logged and
        /// skipped — retried next pass; one bad row can't wedge the rest
        /// of the batch.
        public var failed: Int = 0

        public init(
            candidates: Int = 0,
            embedded: Int = 0,
            skippedUnavailable: Int = 0,
            skippedEmpty: Int = 0,
            failed: Int = 0
        ) {
            self.candidates = candidates
            self.embedded = embedded
            self.skippedUnavailable = skippedUnavailable
            self.skippedEmpty = skippedEmpty
            self.failed = failed
        }

        public var summary: String {
            "candidates=\(candidates) embedded=\(embedded) skippedUnavailable=\(skippedUnavailable) skippedEmpty=\(skippedEmpty) failed=\(failed)"
        }
    }

    /// Run one batch, capped at `limit` entries. Newest-first (mirrors
    /// `entriesNeedingEmbedding`'s ordering), so a big pull-synced backlog
    /// makes visible progress on recent history every pass.
    @discardableResult
    public func runOnce(limit: Int = 15) async throws -> Report {
        guard await EmbeddingService.isAvailable() else {
            return Report(skippedUnavailable: 1)
        }
        let candidates = try repository.entriesNeedingEmbedding(
            modelId: EmbeddingService.modelId,
            revision: EmbeddingService.revision,
            limit: limit
        )
        guard !candidates.isEmpty else { return Report() }
        guard let dims = await EmbeddingService.currentDims() else {
            return Report(candidates: candidates.count, skippedUnavailable: candidates.count)
        }

        var report = Report(candidates: candidates.count)
        for entryId in candidates {
            do {
                guard let entry = try repository.fetch(id: entryId),
                      let text = entry.textPreview,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    report.skippedEmpty += 1
                    continue
                }
                guard let vector = await EmbeddingService.embed(text: text) else {
                    report.skippedEmpty += 1
                    continue
                }
                try await repository.store.dbQueue.write { db in
                    try EntryRepository.saveEmbedding(
                        entryId: entryId,
                        modelId: EmbeddingService.modelId,
                        revision: EmbeddingService.revision,
                        dims: dims,
                        vector: vector,
                        in: db
                    )
                    // saveEmbedding deliberately doesn't enqueue a push
                    // itself (see its doc comment) — without this, a
                    // vector this sweep generates for an entry whose
                    // capture push already went out (the common case:
                    // this sweep is the self-heal path, running well
                    // after capture) would never reach sibling devices.
                    try PushQueue.enqueue(entryId: entryId, in: db)
                }
                await EmbeddingIndex.shared.invalidate()
                report.embedded += 1
            } catch {
                report.failed += 1
                Log.capture.error(
                    "embedding sweep: entry \(entryId, privacy: .public) failed, skipping (will retry next pass): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return report
    }
}
