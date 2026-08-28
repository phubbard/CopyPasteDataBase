import Foundation
import GRDB
import ImageIO

/// Glue between `ImageAnalyzer` (raw bytes → OCR + tags) and the store
/// (persist on the entry + reindex FTS). Called from three places:
///
/// 1. `Ingestor.ingest(...)` kicks off a detached Task after each image
///    entry is inserted — fresh captures get their OCR/tags filled in
///    asynchronously within a couple of seconds.
/// 2. `cpdb analyze-images` walks pre-existing image entries and
///    processes them through the same helper.
/// 3. `ImageAnalysisSweeper` (Mac app, periodic + capture-wake) catches
///    anything the first two missed — pull-synced images from other
///    devices, or a capture-time Task that got killed mid-analysis.
public enum ImageIndexer {

    /// Above this COMPRESSED byte count, an image is downscaled before
    /// Vision ever sees it — see `downscaledOrNil`. Named after the
    /// incident that motivated it: entry 10286 carried a 48 MB TIFF (+ a
    /// 17 MB PNG sibling flavor) that made `.accurate` OCR slow/heavy
    /// enough to look indistinguishable from permanently wedged, and it
    /// sat with `analyzed_at IS NULL` — unsearchable — until it was
    /// found by hand. 24 MB gives ordinary screenshots/photos (typically
    /// single-digit MB) generous headroom while still catching that
    /// shape of pathological capture.
    ///
    /// Byte count alone misses the more common pathological shape: a
    /// highly-compressed image with huge PIXEL dimensions (a multi-
    /// hundred-megapixel PNG/HEIC, or a 1400×60000 full-page screenshot)
    /// can sit well under this threshold while still decoding to a
    /// several-hundred-MB bitmap — the actual cost driver for Vision's
    /// memory/time footprint, not the compressed size. `analyzeAndStore`
    /// therefore also checks decoded pixel dimensions (cheap: reads the
    /// image header only, via `CGImageSourceCopyPropertiesAtIndex`, no
    /// full decode) against `downscaleMaxPixelDimension` and downscales
    /// on EITHER condition.
    public static let giantImageThresholdBytes = 24 * 1024 * 1024

    /// Max width/height (in pixels) a giant image is downscaled to
    /// before analysis, and also the pixel-dimension trigger threshold
    /// itself (see `giantImageThresholdBytes`'s doc comment) — an image
    /// already at or under this on both axes needs no downscale
    /// regardless of compressed byte size. 4096 keeps OCR legible on
    /// real-world screenshots/photos while bounding Vision's memory and
    /// time footprint on the pathological cases the threshold above
    /// exists for.
    public static let downscaleMaxPixelDimension = 4096

    /// Run the analysis and persist results. Safe to call concurrently
    /// with the daemon capture loop — GRDB serialises writes via
    /// `DatabaseQueue`. Logs failures and treats the Vision failure as
    /// a "tried and got nothing" outcome: the `analyzed_at` sentinel is
    /// still set so we don't retry forever.
    ///
    /// `giantImageThresholdBytes` / `maxPixelDimension` default to the
    /// constants above; overridable only so tests can exercise the
    /// downscale path without a real 48 MB fixture.
    public static func analyzeAndStore(
        entryId: Int64,
        imageData: Data,
        store: Store,
        prefs: AnalysisPrefs = .load(),
        giantImageThresholdBytes: Int = ImageIndexer.giantImageThresholdBytes,
        maxPixelDimension: Int = ImageIndexer.downscaleMaxPixelDimension
    ) {
        var dataForAnalysis = imageData
        let isGiant = imageData.count > giantImageThresholdBytes
            || exceedsPixelDimension(imageData, maxPixelDimension: maxPixelDimension)
        if isGiant {
            guard let downscaled = downscaledOrNil(imageData, maxPixelDimension: maxPixelDimension) else {
                // Couldn't even downscale it (corrupt data, an ImageIO
                // format Vision/ImageIO both choke on, etc). Same
                // "tried and got nothing" convention as a genuine Vision
                // failure below — a permanently unsearchable image is
                // worse than a blank result.
                Log.capture.error(
                    "giant image (\(imageData.count, privacy: .public) bytes) failed to downscale for entry \(entryId, privacy: .public); marking analyzed with empty results"
                )
                markAnalyzed(entryId: entryId, ocrText: "", tags: "", store: store)
                return
            }
            Log.capture.info(
                "downscaled giant image (\(imageData.count, privacy: .public) bytes) to \(downscaled.count, privacy: .public) bytes for entry \(entryId, privacy: .public) before analysis"
            )
            dataForAnalysis = downscaled
        }

        let analysis: ImageAnalysis
        do {
            analysis = try ImageAnalyzer.analyze(
                imageData: dataForAnalysis,
                recognitionLanguages: prefs.recognitionLanguages,
                tagConfidenceThreshold: prefs.tagConfidenceThreshold
            )
        } catch {
            Log.capture.error(
                "ImageAnalyzer failed for entry \(entryId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            // Record the attempt so we don't keep retrying every capture.
            markAnalyzed(entryId: entryId, ocrText: "", tags: "", store: store)
            return
        }

        let tagsCSV = analysis.tagsCSV
        markAnalyzed(entryId: entryId, ocrText: analysis.ocrText, tags: tagsCSV, store: store)

        Log.capture.info(
            "analyzed entry \(entryId, privacy: .public): ocr=\(analysis.ocrText.count, privacy: .public) chars, \(analysis.tags.count, privacy: .public) tags, \(analysis.barcodePayloads.count, privacy: .public) barcodes"
        )

        // QR/barcode chips. Separate from `markAnalyzed`'s transaction
        // (and its own `EntryRepository.setChips` call, per that
        // method's doc comment) — a read-modify-write against whatever
        // `chips_json` happens to hold right now (nil from a fresh
        // entry, or already-populated by a same-capture text-chip scan
        // on the caption/OCR text) rather than something `markAnalyzed`
        // would need to know about.
        if !analysis.barcodePayloads.isEmpty {
            mergeBarcodeChips(entryId: entryId, payloads: analysis.barcodePayloads, store: store)
        }
    }

    /// Maps decoded barcode/QR payloads to chips (`QRChipMapper`) and
    /// merges them into the entry's existing `chips_json`. Best-effort:
    /// a failure here doesn't affect the OCR/tags result already
    /// committed above, and the entry stays searchable either way.
    private static func mergeBarcodeChips(entryId: Int64, payloads: [String], store: Store) {
        let chips = QRChipMapper.chips(from: payloads)
        guard !chips.isEmpty else { return }
        let repo = EntryRepository(store: store)
        do {
            let existing = try repo.fetch(id: entryId)?.chipsJson
            let merged = Chip.merge(existingJson: existing, adding: chips)
            try repo.setChips(entryId: entryId, json: merged)
        } catch {
            Log.capture.error(
                "barcode chip merge failed for entry \(entryId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Downscale `data` to at most `maxPixelDimension` on its longest
    /// side via `CGImageSource` thumbnail generation, re-encoded as
    /// JPEG. Returns nil if the source can't be decoded at all (rather
    /// than throwing) so the caller can fall through to its "tried and
    /// got nothing" fallback instead of propagating an error type this
    /// function has no other use for.
    ///
    /// OCR quality on a downscaled screenshot is acceptably lower than
    /// full-resolution — legible text stays legible — and that's the
    /// trade this function exists to make: a searchable-but-imperfect
    /// result beats an image Vision (or our own memory budget) never
    /// finishes with.
    public static func downscaledOrNil(_ data: Data, maxPixelDimension: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// True if the image's decoded pixel width or height would exceed
    /// `maxPixelDimension`. Reads only the image header via
    /// `CGImageSourceCopyPropertiesAtIndex` — no full decode — so it's
    /// cheap to call before deciding whether a downscale is needed.
    /// This is what lets `analyzeAndStore` catch a highly-compressed,
    /// huge-DIMENSION image (a multi-hundred-megapixel PNG/HEIC, or a
    /// tall full-page screenshot) that sits under the compressed-BYTE
    /// threshold but would still decode to a several-hundred-MB bitmap.
    /// Returns false (i.e. "not giant" by this check) if the header
    /// can't be parsed — the byte-count check remains the fallback net
    /// for data this can't read.
    public static func exceedsPixelDimension(_ data: Data, maxPixelDimension: Int) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        return width > maxPixelDimension || height > maxPixelDimension
    }

    /// Write the analysis back and update the FTS row. Done in one
    /// transaction so search and entry stay consistent.
    ///
    /// The `UPDATE` is guarded with `analyzed_at IS NULL` and the
    /// caller's check-then-write (`isImageUnanalyzed` then Vision) is
    /// therefore made race-safe here rather than there: if a sibling's
    /// result (via CloudKit pull) — or, on the sweeper's path, this
    /// Mac's own capture-time analysis — lands on this row while Vision
    /// was running, `analyzed_at` is no longer NULL by the time this
    /// write runs, so it's a no-op and we don't clobber a possibly
    /// fresher/better result with a possibly-empty or -stale one, nor
    /// re-push it. Every legitimate caller (capture-time, the sweeper)
    /// only ever writes over a row it itself found `analyzed_at IS
    /// NULL` moments earlier, so this never regresses a real write; the
    /// CLI's `--force`/`--retry-failed` paths use their own
    /// `writeAnalysis` (`Stubs.swift`), not this function, so they're
    /// unaffected.
    private static func markAnalyzed(
        entryId: Int64,
        ocrText: String,
        tags: String,
        store: Store
    ) {
        let now = Date().timeIntervalSince1970
        do {
            try store.dbQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE entries
                        SET ocr_text = ?, image_tags = ?, analyzed_at = ?
                        WHERE id = ? AND analyzed_at IS NULL
                    """,
                    arguments: [ocrText, tags, now, entryId]
                )
                guard db.changesCount > 0 else {
                    Log.capture.info(
                        "markAnalyzed: entry \(entryId, privacy: .public) was already analyzed by the time this write ran; skipping (no clobber)"
                    )
                    return
                }

                // Re-index FTS. We need title + text + app_name + new
                // ocr/tags, so re-fetch the whole row.
                if let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT e.title, e.text_preview, a.name AS app_name
                        FROM entries e LEFT JOIN apps a ON a.id = e.source_app_id
                        WHERE e.id = ?
                    """,
                    arguments: [entryId]
                ) {
                    try FtsIndex.indexEntry(
                        db: db,
                        entryId: entryId,
                        title: row["title"],
                        text: row["text_preview"],
                        appName: row["app_name"],
                        ocrText: ocrText,
                        imageTags: tags
                    )
                }

                // Enqueue for CloudKit push in the SAME transaction as
                // the analysis write. Analysis routinely finishes after
                // the entry's own insert has already been pushed (the
                // capture-time Vision call takes hundreds of ms to
                // seconds; the sweep/CLI backfill run even later) — so
                // without an explicit re-enqueue here, freshly-produced
                // OCR/tags have no path to sibling devices at all.
                try PushQueue.enqueue(entryId: entryId, in: db, now: now)
            }
        } catch {
            Log.capture.error(
                "markAnalyzed failed for entry \(entryId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
