import Foundation
import Vision

/// Result of running both OCR and image classification over an image.
public struct ImageAnalysis: Sendable, Equatable {
    public var ocrText: String                  // "" when no text is found (not the same as "not analyzed")
    public var tags: [Tag]

    public struct Tag: Sendable, Equatable {
        public var label: String
        public var confidence: Float
        public init(label: String, confidence: Float) {
            self.label = label
            self.confidence = confidence
        }
    }

    public init(ocrText: String = "", tags: [Tag] = []) {
        self.ocrText = ocrText
        self.tags = tags
    }

    /// Convenience: comma-separated, lowercased tag labels for FTS5 indexing
    /// and for the `entries.image_tags` column.
    public var tagsCSV: String {
        tags.map { $0.label.lowercased() }.joined(separator: ", ")
    }
}

/// On-device image analysis via the `Vision` framework.
///
/// Runs one OCR pass (`VNRecognizeTextRequest`, `.accurate`) and one
/// classification pass (`VNClassifyImageRequest`) against a single shared
/// `VNImageRequestHandler`, so the image is decoded exactly once per
/// analysis regardless of how many requests are bundled.
///
/// Callers should run this off the main thread — recognition at `.accurate`
/// takes 100 ms – 1 s depending on image size and text density.
public enum ImageAnalyzer {
    public enum AnalysisError: Error, CustomStringConvertible {
        case visionFailed(Error)
        public var description: String {
            switch self {
            case .visionFailed(let e): return "Vision failed: \(e)"
            }
        }
    }

    /// Synchronous wrapper around Vision. Safe to call from a background
    /// queue / detached Task. Returns `ImageAnalysis(ocrText: "", tags: [])`
    /// if the image decodes but genuinely contains no text and no
    /// above-threshold classifications — that's a legitimate result, not
    /// a failure. Throws only on a real Vision error.
    public static func analyze(
        imageData: Data,
        recognitionLanguages: [String] = ["en-US"],
        tagConfidenceThreshold: Float = 0.15,
        maxTags: Int = 12
    ) throws -> ImageAnalysis {
        let handler = VNImageRequestHandler(data: imageData, options: [:])

        // OCR request
        let ocrRequest = VNRecognizeTextRequest()
        ocrRequest.recognitionLevel = .accurate
        ocrRequest.usesLanguageCorrection = true
        if !recognitionLanguages.isEmpty {
            ocrRequest.recognitionLanguages = recognitionLanguages
        }

        // Image classification request
        let classifyRequest = VNClassifyImageRequest()

        do {
            try handler.perform([ocrRequest, classifyRequest])
        } catch {
            throw AnalysisError.visionFailed(error)
        }

        // Extract OCR text, one observation per line.
        let ocrLines: [String] = (ocrRequest.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        let ocrText = ocrLines.joined(separator: "\n")

        // Extract top-N confident tags above the threshold.
        let classifications = (classifyRequest.results ?? [])
            .filter { $0.confidence >= tagConfidenceThreshold }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxTags)

        let tags = classifications.map {
            ImageAnalysis.Tag(label: $0.identifier, confidence: $0.confidence)
        }

        return ImageAnalysis(ocrText: ocrText, tags: tags)
    }

    /// Lookup of the OCR recognition languages Vision supports on this
    /// macOS release. Used by the Preferences language picker.
    public static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }
}
