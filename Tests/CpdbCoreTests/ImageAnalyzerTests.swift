import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import CpdbCore

@Suite("Image analyzer")
struct ImageAnalyzerTests {

    /// Render a small white-background PNG with a single line of known text
    /// drawn on it. Good enough for a "OCR sees something" sanity check
    /// without needing to ship binary fixtures in the repo.
    private func renderTextImage(_ text: String) throws -> Data {
        let width = 640
        let height = 160
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw POSIXError(.EIO)
        }

        // White background, high-contrast black text — maximises OCR success.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Render text via Core Text.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 60, nil),
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 20, y: 50)
        CTLineDraw(line, context)

        guard let cgImage = context.makeImage() else {
            throw POSIXError(.EIO)
        }

        // Encode to PNG.
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw POSIXError(.EIO)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw POSIXError(.EIO)
        }
        return output as Data
    }

    @Test("OCR extracts text from a rendered image")
    func ocrExtractsKnownText() throws {
        let phrase = "Hello cpdb OCR"
        let png = try renderTextImage(phrase)
        let analysis = try ImageAnalyzer.analyze(imageData: png)
        // Vision should find every whitespace-split token (case-insensitive).
        let normalized = analysis.ocrText.lowercased()
        for token in phrase.split(separator: " ") {
            #expect(
                normalized.contains(token.lowercased()),
                "expected OCR to see '\(token)' in '\(analysis.ocrText)'"
            )
        }
    }

    @Test("Classifier returns at least one high-confidence tag for a text image")
    func classifierReturnsTags() throws {
        // A text image classifies as something in Vision's vocabulary
        // (`text`, `document`, etc.) reliably.
        let png = try renderTextImage("A quick test")
        let analysis = try ImageAnalyzer.analyze(imageData: png)
        #expect(!analysis.tags.isEmpty, "expected at least one above-threshold tag")
        for tag in analysis.tags {
            #expect(tag.confidence >= 0.15)
            #expect(!tag.label.isEmpty)
        }
    }

    @Test("tagsCSV joins labels, lowercased, comma-separated")
    func tagsCsvShape() {
        let analysis = ImageAnalysis(ocrText: "", tags: [
            .init(label: "Laptop", confidence: 0.9),
            .init(label: "Keyboard", confidence: 0.8),
        ])
        #expect(analysis.tagsCSV == "laptop, keyboard")
    }

    @Test("Supported languages list is non-empty and contains en-US")
    func supportedLanguagesContainsEnglish() {
        let langs = ImageAnalyzer.supportedLanguages()
        #expect(!langs.isEmpty)
        #expect(langs.contains("en-US"))
    }
}
