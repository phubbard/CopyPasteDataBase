import Foundation

/// Backfills `chips_json` for pre-existing text/link entries that predate
/// this feature — imported via `Paste.db`, or captured before
/// `TextChipDetector` shipped. `Ingestor` only runs chip detection on
/// freshly `.inserted` captures, so anything already sitting in the store
/// needs this catch-up pass, mirroring `LinkMetadataBackfiller`'s role
/// for link titles.
///
/// Deliberately its OWN tiny backfiller rather than folded into
/// `ImageAnalysisSweeper`: that sweeper's candidate query, gate, and doc
/// comment are scoped to `kind = 'image'` Vision work (and its giant-
/// image handling has no analogue here). This pass costs nothing by
/// comparison — no Vision, no network, just `NSDataDetector` over a
/// capped text preview — so bolting a second, unrelated
/// `kind IN ('text','link')` query onto the image sweeper would be a
/// scope mismatch for work this cheap. QR/barcode chips need no
/// equivalent backfiller: they piggyback for free on
/// `ImageAnalysisSweeper`, which already calls `ImageIndexer.analyzeAndStore`
/// per candidate image, and that function now runs barcode detection as
/// part of the same Vision pass (see `ImageAnalyzer`).
public struct TextChipBackfiller {
    public let repository: EntryRepository

    public init(repository: EntryRepository) {
        self.repository = repository
    }

    /// Outcome of one backfill pass. Logged by the caller.
    public struct Report: Sendable, Equatable {
        public var candidates: Int = 0
        public var scanned: Int = 0
        /// Threw while scanning or writing back this entry. Logged and
        /// skipped — the row stays `chips_json IS NULL` and is retried
        /// next pass; one bad row can't wedge every older candidate
        /// behind it (mirrors `ImageAnalysisSweeper.Report.failed`).
        public var failed: Int = 0

        public init(candidates: Int = 0, scanned: Int = 0, failed: Int = 0) {
            self.candidates = candidates
            self.scanned = scanned
            self.failed = failed
        }

        public var summary: String {
            "candidates=\(candidates) scanned=\(scanned) failed=\(failed)"
        }
    }

    /// Run one batch, capped at `limit` entries (default 50 — cheap
    /// enough to run every periodic tick without needing a jittered
    /// schedule the way the Vision-based image sweep does).
    @discardableResult
    public func runOnce(limit: Int = 50) async throws -> Report {
        let candidates = try repository.entriesNeedingChips(limit: limit)
        guard !candidates.isEmpty else { return Report() }

        var report = Report(candidates: candidates.count)
        for row in candidates {
            do {
                let chips = await TextChipDetector.detect(in: row.textPreview ?? "")
                // Candidates are exactly the rows with chips_json IS
                // NULL, so there's nothing existing to merge against —
                // this write is what turns NULL into (at minimum) "[]",
                // marking the row scanned either way. `setChipsIfUnset`
                // guards against clobbering `Ingestor`'s own (fuller —
                // `plainText` vs. this pass's truncated `text_preview`)
                // scan if it raced us and already won for this row.
                //
                // `pushToCloud: false`: chips are re-derivable from the
                // entry's own already-synced text, so this catch-up
                // pass over what can be the entire pre-existing
                // text/link corpus (a Paste.db import: thousands of
                // rows) has nothing to gain from re-enqueuing every one
                // of them for a full CloudKit push (entry + thumbnails
                // + every flavor as a fresh CKAsset) — every device
                // converges on the same chips by running this same
                // backfill locally. Skipping the enqueue keeps this
                // pass from flooding `cloudkit_push_queue` and starving
                // real pending edits behind a corpus-wide re-upload.
                let json = Chip.merge(existingJson: nil, adding: chips)
                try repository.setChipsIfUnset(entryId: row.entryId, json: json, pushToCloud: false)
                report.scanned += 1
            } catch {
                report.failed += 1
                Log.capture.error(
                    "chip backfill: entry \(row.entryId, privacy: .public) failed, skipping (will retry next pass): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return report
    }
}
