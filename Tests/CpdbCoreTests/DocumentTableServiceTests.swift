import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import CpdbShared

/// Tests for `DocumentTableService`: the pure CSV/Markdown emitters (run
/// unconditionally — they're plain string transforms, independent of
/// Vision or OS version), the below-macOS-26 gating path, and one
/// end-to-end recognition pass against a synthetically rendered table
/// image (Vision-model-dependent, so gated to macOS 26 and kept
/// tolerant of imperfect recognition).
@Suite("Document table service")
struct DocumentTableServiceTests {

    // MARK: - CSV emitter

    @Test("CSV: plain cells join with commas, rows with newlines")
    func csvPlainCells() {
        let rows = [["Name", "Qty"], ["Apples", "3"]]
        #expect(DocumentTableService.csv(forTable: rows) == "Name,Qty\nApples,3")
    }

    @Test("CSV: a cell containing a comma is quoted")
    func csvQuotesComma() {
        let rows = [["City, State", "Total"]]
        #expect(DocumentTableService.csv(forTable: rows) == "\"City, State\",Total")
    }

    @Test("CSV: an embedded quote is doubled and the field quoted")
    func csvDoublesEmbeddedQuote() {
        let rows = [["He said \"hi\"", "ok"]]
        #expect(DocumentTableService.csv(forTable: rows) == "\"He said \"\"hi\"\"\",ok")
    }

    @Test("CSV: an embedded newline forces quoting")
    func csvQuotesNewline() {
        let rows = [["line1\nline2", "x"]]
        #expect(DocumentTableService.csv(forTable: rows) == "\"line1\nline2\",x")
    }

    @Test("CSV: unicode passes through unescaped")
    func csvUnicodePassesThrough() {
        let rows = [["café ☕️", "日本語"]]
        #expect(DocumentTableService.csv(forTable: rows) == "café ☕️,日本語")
    }

    @Test("CSV: multiple tables are blank-line separated")
    func csvMultipleTablesSeparated() {
        let tables = [[["A", "B"]], [["C", "D"]]]
        #expect(DocumentTableService.csv(forTables: tables) == "A,B\n\nC,D")
    }

    // MARK: - Markdown emitter

    @Test("Markdown: header row gets a divider synthesized underneath")
    func markdownHeaderAndDivider() {
        let rows = [["Name", "Qty"], ["Apples", "3"]]
        let expected = "| Name | Qty |\n| --- | --- |\n| Apples | 3 |"
        #expect(DocumentTableService.markdown(forTable: rows) == expected)
    }

    @Test("Markdown: a pipe in a cell is escaped so it doesn't split columns")
    func markdownEscapesPipe() {
        let rows = [["A | B", "x"]]
        let markdown = DocumentTableService.markdown(forTable: rows)
        #expect(markdown.contains("A \\| B"))
        // Escaped pipe plus the two real column delimiters plus the
        // leading/trailing bars = 4 total '|' characters on the row line.
        let rowLine = markdown.split(separator: "\n")[0]
        #expect(rowLine.filter { $0 == "|" }.count == 4)
    }

    @Test("Markdown: a backslash is escaped before pipe-escaping runs")
    func markdownEscapesBackslash() {
        let rows = [["a\\b", "x"]]
        #expect(DocumentTableService.markdown(forTable: rows).contains("a\\\\b"))
    }

    @Test("Markdown: an embedded newline becomes <br>")
    func markdownNewlineBecomesBr() {
        let rows = [["line1\nline2", "x"]]
        #expect(DocumentTableService.markdown(forTable: rows).contains("line1<br>line2"))
    }

    @Test("Markdown: unicode passes through unescaped")
    func markdownUnicodePassesThrough() {
        let rows = [["café ☕️", "日本語"]]
        #expect(DocumentTableService.markdown(forTable: rows).contains("café ☕️"))
        #expect(DocumentTableService.markdown(forTable: rows).contains("日本語"))
    }

    @Test("Markdown: a ragged row is padded to the widest row's column count")
    func markdownPadsRaggedRows() {
        let rows = [["A", "B", "C"], ["x"]]
        let markdown = DocumentTableService.markdown(forTable: rows)
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[2] == "| x |  |  |")
    }

    @Test("Markdown: multiple tables are blank-line separated")
    func markdownMultipleTablesSeparated() {
        let tables = [[["A"]], [["B"]]]
        let markdown = DocumentTableService.markdown(forTables: tables)
        #expect(markdown.contains("| A |\n| --- |\n\n| B |\n| --- |"))
    }

    @Test("Markdown: empty input produces empty output")
    func markdownEmptyInput() {
        #expect(DocumentTableService.markdown(forTable: []) == "")
    }

    // MARK: - Availability gating

    @Test("isAvailable is true on this test machine (macOS 26+)")
    func isAvailableOnTestMachine() {
        // This repo's baseline dev/CI box runs macOS 26 — see the shared
        // task context. If this ever runs somewhere older the failure
        // here is the right signal that the below-26 test below is the
        // one actually exercising reality, not this one.
        #expect(DocumentTableService.isAvailable)
    }

    @Test("extractTables throws .unavailable when overridden to simulate below-macOS-26")
    func extractTablesReportsUnavailableWhenOverridden() async throws {
        await #expect(throws: DocumentTableService.ServiceError.unavailable) {
            _ = try await DocumentTableService.extractTables(from: Data(), isAvailableOverride: false)
        }
    }

    // MARK: - End-to-end recognition (Vision-model-dependent)

    /// Render a small 3×3 grid — ruled borders plus one line of text per
    /// cell — so Vision's document recognizer has real table geometry to
    /// find, not just floating text lines.
    private func renderTableImage() throws -> Data {
        let cellWidth = 180
        let cellHeight = 70
        let cols = 3
        let rows = 3
        let width = cellWidth * cols
        let height = cellHeight * rows

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw POSIXError(.EIO) }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.setLineWidth(2)
        for col in 0...cols {
            let x = CGFloat(col * cellWidth)
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: CGFloat(height)))
        }
        for row in 0...rows {
            let y = CGFloat(row * cellHeight)
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: CGFloat(width), y: y))
        }
        context.strokePath()

        let cellText = [
            ["Name", "Qty", "Price"],
            ["Apples", "3", "1.50"],
            ["Bread", "1", "2.25"],
        ]
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        // CoreGraphics' origin is bottom-left; row 0 (top of the image)
        // needs the highest y baseline.
        for (rowIndex, rowText) in cellText.enumerated() {
            for (colIndex, text) in rowText.enumerated() {
                let attributed = NSAttributedString(string: text, attributes: attrs)
                let line = CTLineCreateWithAttributedString(attributed)
                let x = CGFloat(colIndex * cellWidth) + 16
                let topY = CGFloat((rows - rowIndex) * cellHeight)
                context.textPosition = CGPoint(x: x, y: topY - CGFloat(cellHeight) / 2 - 8)
                CTLineDraw(line, context)
            }
        }

        guard let cgImage = context.makeImage() else { throw POSIXError(.EIO) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw POSIXError(.EIO) }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw POSIXError(.EIO) }
        return output as Data
    }

    // NOTE: this test depends on Vision's on-device table-recognition
    // model actually finding the ruled grid drawn above. If it proves
    // flaky in CI (model behavior differs across macOS point releases,
    // or the synthetic grid isn't "table-like" enough for the
    // heuristic), disable with `.disabled("flaky: see DocumentTableService
    // integration test notes")` rather than deleting it — the emitter
    // tests above cover the deterministic logic either way.
    @Test(
        "extractTables recognizes a synthetically rendered 3x3 table",
        .enabled(if: DocumentTableService.isAvailable)
    )
    func recognizesSyntheticTable() async throws {
        let png = try renderTableImage()
        let result = try await DocumentTableService.extractTables(from: png)
        let table = try #require(result, "expected Vision to find a table in the rendered grid")
        let csvRowCount = table.csv.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(csvRowCount >= 2, "expected at least 2 rows recognized, got csv:\n\(table.csv)")
    }
}
