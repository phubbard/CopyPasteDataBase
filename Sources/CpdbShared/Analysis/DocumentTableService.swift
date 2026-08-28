import Foundation
#if os(macOS)
import Vision
#endif

/// Extracts tables out of an image via Vision's document-aware
/// `RecognizeDocumentsRequest` (macOS 26+) and emits them as RFC-4180 CSV
/// and GitHub-flavored Markdown for the popup's "Copy as Table…" action.
///
/// `RecognizeDocumentsRequest` (unlike the plain `VNRecognizeTextRequest`
/// `ImageAnalyzer` uses for OCR) understands document structure — it groups
/// recognized text into paragraphs, lists, and *tables* with row/column
/// geometry, which is what lets this service reconstruct a grid instead of
/// just a bag of text lines.
///
/// The whole service is gated behind `isAvailable` rather than the type
/// itself carrying `@available(macOS 26.0, *)`: `CpdbShared` is linked by
/// the iOS target too, and callers (the popup's context menu, eventually
/// the CLI) want one boolean check rather than an `#available` at every
/// call site.
public enum DocumentTableService {

    /// CSV + Markdown renderings of every table found in an image,
    /// concatenated with a blank line between tables when there's more
    /// than one.
    public struct TableResult: Sendable, Equatable {
        public var csv: String
        public var markdown: String
        public init(csv: String, markdown: String) {
            self.csv = csv
            self.markdown = markdown
        }
    }

    public enum ServiceError: Error, Equatable, Sendable, CustomStringConvertible {
        /// Not macOS, or macOS older than 26 — `RecognizeDocumentsRequest`
        /// doesn't exist here.
        case unavailable
        case timedOut
        case recognitionFailed(String)

        public var description: String {
            switch self {
            case .unavailable:
                return "Table recognition requires macOS 26 or later."
            case .timedOut:
                return "Table recognition timed out."
            case .recognitionFailed(let message):
                return "Table recognition failed: \(message)"
            }
        }
    }

    /// True when `RecognizeDocumentsRequest` exists on this build/OS.
    /// Always false on non-macOS targets (currently just iOS, which links
    /// this same `CpdbShared` target) and on macOS < 26.
    public static var isAvailable: Bool {
        #if os(macOS)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    /// Vision's document recognizer has no built-in deadline; a
    /// pathologically dense or huge image could in principle run long.
    /// This bounds the wait so the preview window never looks permanently
    /// stuck — mirrors `ImageIndexer`'s size guards, which exist for the
    /// same class of problem.
    public static let recognitionTimeout: Duration = .seconds(10)

    /// Recognize tables in `imageData` and render them as CSV + Markdown.
    /// Returns `nil` when the image decodes fine but genuinely contains no
    /// table — a legitimate result, not a failure. Downscales first via
    /// `ImageIndexer`'s existing thresholds when the image is oversized,
    /// same rationale as image analysis: OCR/table geometry on a
    /// downscaled screenshot stays legible, and Vision's memory/time
    /// footprint on a pathological capture stays bounded.
    ///
    /// `isAvailableOverride` exists only so tests can exercise the
    /// below-macOS-26 gating path deterministically on a machine that IS
    /// macOS 26 (this repo's CI/dev box) without OS mocking. Real callers
    /// never pass it.
    public static func extractTables(
        from imageData: Data,
        timeout: Duration = recognitionTimeout,
        giantImageThresholdBytes: Int = ImageIndexer.giantImageThresholdBytes,
        maxPixelDimension: Int = ImageIndexer.downscaleMaxPixelDimension,
        isAvailableOverride: Bool? = nil
    ) async throws -> TableResult? {
        guard isAvailableOverride ?? isAvailable else {
            throw ServiceError.unavailable
        }
        #if os(macOS)
        if #available(macOS 26.0, *) {
            return try await extractTablesOnSupportedOS(
                from: imageData,
                timeout: timeout,
                giantImageThresholdBytes: giantImageThresholdBytes,
                maxPixelDimension: maxPixelDimension
            )
        }
        #endif
        throw ServiceError.unavailable
    }

    #if os(macOS)
    @available(macOS 26.0, *)
    private static func extractTablesOnSupportedOS(
        from imageData: Data,
        timeout: Duration,
        giantImageThresholdBytes: Int,
        maxPixelDimension: Int
    ) async throws -> TableResult? {
        var dataForRecognition = imageData
        let isGiant = imageData.count > giantImageThresholdBytes
            || ImageIndexer.exceedsPixelDimension(imageData, maxPixelDimension: maxPixelDimension)
        if isGiant, let downscaled = ImageIndexer.downscaledOrNil(imageData, maxPixelDimension: maxPixelDimension) {
            dataForRecognition = downscaled
        }

        let observations = try await withThrowingTaskGroup(of: [DocumentObservation].self) { group -> [DocumentObservation] in
            group.addTask {
                let request = RecognizeDocumentsRequest()
                do {
                    return try await request.perform(on: dataForRecognition)
                } catch {
                    throw ServiceError.recognitionFailed(String(describing: error))
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ServiceError.timedOut
            }
            defer { group.cancelAll() }
            // First task to finish wins — either a result or one of the
            // two error paths above. `group.next()` on a
            // `withThrowingTaskGroup` never returns nil before at least
            // one child has completed.
            return try await group.next()!
        }

        let tableGrids: [[[String]]] = observations.flatMap { observation in
            observation.document.tables.map { table in
                table.rows.map { row in
                    row.map { cell in cell.content.text.transcript }
                }
            }
        }
        guard !tableGrids.isEmpty else { return nil }

        return TableResult(
            csv: csv(forTables: tableGrids),
            markdown: markdown(forTables: tableGrids)
        )
    }
    #endif

    // MARK: - Emitters
    //
    // Pure string transforms, independent of Vision/availability, so
    // they're directly unit-testable on synthetic `[[String]]` grids
    // (rows of cell strings) without needing a real recognition pass.

    /// Multiple tables' CSV, blank-line separated.
    public static func csv(forTables tables: [[[String]]]) -> String {
        tables.map(csv(forTable:)).joined(separator: "\n\n")
    }

    /// Multiple tables' Markdown, blank-line separated.
    public static func markdown(forTables tables: [[[String]]]) -> String {
        tables.map(markdown(forTable:)).joined(separator: "\n\n")
    }

    /// RFC-4180 CSV for one table given as rows of cell strings. Matches
    /// `HistoryExporter.renderCSV`'s quoting convention (LF row
    /// separator, quote on comma/quote/newline, doubled embedded quotes)
    /// so the two CSV emitters in this codebase agree.
    public static func csv(forTable rows: [[String]]) -> String {
        rows.map { row in row.map(csvField).joined(separator: ",") }.joined(separator: "\n")
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// GitHub-flavored Markdown table for one table given as rows of cell
    /// strings. The first row is treated as the header; a divider row is
    /// synthesized underneath it (GitHub's table syntax requires one).
    /// Ragged rows (fewer cells than the widest row) are padded with
    /// empty cells rather than dropped, so a partially-recognized table
    /// still renders as a valid grid.
    public static func markdown(forTable rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return "" }

        func line(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: columnCount - cells.count)
            return "| " + padded.map(markdownField).joined(separator: " | ") + " |"
        }

        var lines = [line(rows[0])]
        lines.append("| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |")
        lines.append(contentsOf: rows.dropFirst().map(line))
        return lines.joined(separator: "\n")
    }

    /// Escape the three things that would otherwise break a Markdown
    /// table cell: literal backslashes (so our own escapes below don't
    /// get misread), pipes (the column delimiter), and embedded
    /// newlines (Markdown table cells are single-line — `<br>` is the
    /// conventional GFM line break inside one).
    private static func markdownField(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
