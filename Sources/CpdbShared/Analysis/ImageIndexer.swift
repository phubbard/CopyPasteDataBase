import Foundation
import GRDB

/// Glue between `ImageAnalyzer` (raw bytes → OCR + tags) and the store
/// (persist on the entry + reindex FTS). Called from two places:
///
/// 1. `Ingestor.ingest(...)` kicks off a detached Task after each image
///    entry is inserted — fresh captures get their OCR/tags filled in
///    asynchronously within a couple of seconds.
/// 2. `cpdb analyze-images` walks pre-existing image entries and
///    processes them through the same helper.
public enum ImageIndexer {

    /// Run the analysis and persist results. Safe to call concurrently
    /// with the daemon capture loop — GRDB serialises writes via
    /// `DatabaseQueue`. Logs failures and treats the Vision failure as
    /// a "tried and got nothing" outcome: the `analyzed_at` sentinel is
    /// still set so we don't retry forever.
    public static func analyzeAndStore(
        entryId: Int64,
        imageData: Data,
        store: Store,
        prefs: AnalysisPrefs = .load()
    ) {
        let analysis: ImageAnalysis
        do {
            analysis = try ImageAnalyzer.analyze(
                imageData: imageData,
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
            "analyzed entry \(entryId, privacy: .public): ocr=\(analysis.ocrText.count, privacy: .public) chars, \(analysis.tags.count, privacy: .public) tags"
        )
    }

    /// Write the analysis back and update the FTS row. Done in one
    /// transaction so search and entry stay consistent.
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
                        WHERE id = ?
                    """,
                    arguments: [ocrText, tags, now, entryId]
                )

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
            }
        } catch {
            Log.capture.error(
                "markAnalyzed failed for entry \(entryId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
