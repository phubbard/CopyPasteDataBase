import Testing
import Foundation
@testable import CpdbShared

/// Pure-math coverage for `EmbeddingService`'s chunking, pooling, and
/// vector encode/normalize helpers — none of this touches
/// `NLContextualEmbedding` itself, so it runs unconditionally (no asset
/// download, no model load) on any machine, CI included.
@Suite("EmbeddingService pure math")
struct EmbeddingServiceMathTests {

    // MARK: - chunk

    @Test("chunk returns the whole text as one chunk when it's under the token budget")
    func chunkSinglePieceUnderBudget() {
        let text = "A short paste that easily fits in one chunk."
        let chunks = EmbeddingService.chunk(text, maxTokens: 256)
        #expect(chunks.count == 1)
        #expect(chunks.first == text)
    }

    @Test("chunk splits long text into multiple pieces, each under the token budget")
    func chunkSplitsLongText() {
        // One sentence repeated enough times to blow well past a tiny
        // budget — forces the paragraph-too-long → sentence-packing path.
        let sentence = "The quick brown fox jumps over the lazy dog."
        let text = Array(repeating: sentence, count: 40).joined(separator: " ")
        let chunks = EmbeddingService.chunk(text, maxTokens: 20)
        #expect(chunks.count > 1)
        for piece in chunks {
            #expect(EmbeddingService.approxTokenCount(piece) <= 20 + 20) // generous slack for the last sentence that tips a chunk over
        }
        // No sentence content lost: every chunk's words, concatenated,
        // reproduce the same total word count as the source.
        let totalWords = chunks.reduce(0) { $0 + $1.split(separator: " ").count }
        #expect(totalWords == text.split(separator: " ").count)
    }

    @Test("chunk splits on paragraph boundaries when paragraphs individually fit")
    func chunkRespectsParagraphBoundaries() {
        let text = "First paragraph here.\n\nSecond paragraph here.\n\nThird paragraph here."
        let chunks = EmbeddingService.chunk(text, maxTokens: 256)
        #expect(chunks.count == 3)
    }

    @Test("chunk of empty/whitespace-only text returns no chunks")
    func chunkEmptyText() {
        #expect(EmbeddingService.chunk("", maxTokens: 256).isEmpty)
        #expect(EmbeddingService.chunk("   \n\n  ", maxTokens: 256).isEmpty)
    }

    // MARK: - approxTokenCount

    @Test("approxTokenCount scales with word count and never returns zero for non-empty text")
    func approxTokenCountScales() {
        let short = EmbeddingService.approxTokenCount("one two three")
        let long = EmbeddingService.approxTokenCount("one two three four five six seven eight nine ten")
        #expect(short > 0)
        #expect(long > short)
    }

    @Test("approxTokenCount of empty text is zero")
    func approxTokenCountEmpty() {
        #expect(EmbeddingService.approxTokenCount("") == 0)
    }

    // MARK: - normalizeL2

    @Test("normalizeL2 produces a unit vector")
    func normalizeL2ProducesUnitVector() {
        var v: [Double] = [3, 4] // 3-4-5 triangle: norm is exactly 5
        EmbeddingService.normalizeL2(&v)
        #expect(abs(v[0] - 0.6) < 1e-9)
        #expect(abs(v[1] - 0.8) < 1e-9)
        let normSquared = v.reduce(0) { $0 + $1 * $1 }
        #expect(abs(normSquared - 1.0) < 1e-9)
    }

    @Test("normalizeL2 leaves an all-zero vector untouched rather than dividing by zero")
    func normalizeL2ZeroVectorIsNoOp() {
        var v: [Double] = [0, 0, 0]
        EmbeddingService.normalizeL2(&v)
        #expect(v == [0, 0, 0])
    }

    // MARK: - little-endian Float32 encode/decode round-trip

    @Test("littleEndianFloat32Data round-trips through float32Array")
    func float32EncodeDecodeRoundTrips() {
        let original: [Double] = [1.0, -0.5, 0.25, 0.0, 123.456]
        let data = EmbeddingService.littleEndianFloat32Data(from: original)
        #expect(data.count == original.count * 4)
        let decoded = EmbeddingService.float32Array(fromLittleEndianData: data)
        #expect(decoded.count == original.count)
        for (a, b) in zip(decoded, original) {
            #expect(abs(Double(a) - b) < 1e-4)
        }
    }

    @Test("float32Array of empty data is empty")
    func float32ArrayOfEmptyData() {
        #expect(EmbeddingService.float32Array(fromLittleEndianData: Data()).isEmpty)
    }

    @Test("littleEndianFloat32Data encodes a known value byte-for-byte")
    func float32EncodeKnownValue() {
        // 1.0f as little-endian bytes is 00 00 80 3F.
        let data = EmbeddingService.littleEndianFloat32Data(from: [1.0])
        #expect(data == Data([0x00, 0x00, 0x80, 0x3F]))
    }
}
