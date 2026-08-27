import Testing
import Foundation
import NaturalLanguage
@testable import CpdbShared

/// `hasAvailableAssets` is synchronous and triggers no download, so
/// gating on this (rather than `EmbeddingService.isAvailable()`, which is
/// async and would download on a fresh machine) never causes a CI run to
/// reach out to the network — it just skips. A free function, not a
/// member of the suite below: referencing a type's own static member
/// from its own `@Suite(...)` attribute is a circular reference.
private func embeddingModelAssetsAvailable() -> Bool {
    NLContextualEmbedding(script: .latin)?.hasAvailableAssets ?? false
}

/// Model-dependent coverage for `EmbeddingService.embed(text:)`. Gated on
/// the Latin-script model's assets already being resident.
@Suite("EmbeddingService live model", .enabled(if: embeddingModelAssetsAvailable()))
struct EmbeddingServiceLiveTests {

    @Test("embed produces an L2-normalized vector of the model's reported dimension")
    func embedProducesNormalizedVectorOfCorrectDims() async throws {
        EmbeddingService.resetCacheForTesting()
        guard let dims = await EmbeddingService.currentDims() else {
            Issue.record("model reported unavailable despite hasAvailableAssets == true")
            return
        }
        guard let data = await EmbeddingService.embed(text: "The quick brown fox jumps over the lazy dog.") else {
            Issue.record("embed(text:) returned nil for non-empty text")
            return
        }
        let vector = EmbeddingService.float32Array(fromLittleEndianData: data)
        #expect(vector.count == Int(dims))
        let normSquared = vector.reduce(Float(0)) { $0 + $1 * $1 }
        #expect(abs(normSquared - 1.0) < 1e-3)
    }

    @Test("embed of blank text returns nil")
    func embedOfBlankTextReturnsNil() async throws {
        EmbeddingService.resetCacheForTesting()
        let result = await EmbeddingService.embed(text: "   \n  ")
        #expect(result == nil)
    }

    @Test("embed of semantically similar sentences scores higher cosine similarity than unrelated ones")
    func semanticallySimilarSentencesScoreHigher() async throws {
        EmbeddingService.resetCacheForTesting()
        guard let a = await EmbeddingService.embed(text: "The cat sat on the mat."),
              let b = await EmbeddingService.embed(text: "A feline was resting on the rug."),
              let c = await EmbeddingService.embed(text: "Quarterly revenue exceeded analyst expectations.")
        else {
            Issue.record("embed(text:) returned nil for well-formed input")
            return
        }
        let vecA = EmbeddingService.float32Array(fromLittleEndianData: a)
        let vecB = EmbeddingService.float32Array(fromLittleEndianData: b)
        let vecC = EmbeddingService.float32Array(fromLittleEndianData: c)

        func dot(_ x: [Float], _ y: [Float]) -> Float {
            zip(x, y).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        }
        let similarScore = dot(vecA, vecB)
        let unrelatedScore = dot(vecA, vecC)
        #expect(similarScore > unrelatedScore)
    }
}
