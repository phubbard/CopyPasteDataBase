import Testing
import Foundation
import NaturalLanguage
import GRDB
@testable import CpdbShared

/// A free function, not a suite member — see
/// `EmbeddingServiceLiveTests.swift` for why (a type referencing its own
/// static member in its own `@Suite(...)` attribute is a circular
/// reference).
private func embeddingModelAssetsAvailable() -> Bool {
    NLContextualEmbedding(script: .latin)?.hasAvailableAssets ?? false
}

/// End-to-end coverage for `EmbeddingSweeper.runOnce`: candidate
/// selection → embed → persist, gated on the Latin model's assets
/// already being resident (a synchronous, no-download check).
@Suite("Embedding sweep", .enabled(if: embeddingModelAssetsAvailable()))
struct EmbeddingSweeperTests {

    private func insertEntry(
        in store: Store,
        kind: EntryKind = .text,
        textPreview: String? = "some searchable text about clipboard managers"
    ) throws -> Int64 {
        try store.dbQueue.write { db in
            var device = Device(identifier: "test-device", name: "Test", kind: "mac")
            try device.insert(db)
            var entry = Entry(
                uuid: Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
                createdAt: Date().timeIntervalSince1970,
                capturedAt: Date().timeIntervalSince1970,
                kind: kind,
                sourceDeviceId: device.id!,
                title: nil,
                textPreview: textPreview,
                contentHash: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                totalSize: 10
            )
            try entry.insert(db)
            return entry.id!
        }
    }

    @Test("runOnce embeds a candidate and persists a matching entry_embeddings row")
    func runOnceEmbedsCandidate() async throws {
        EmbeddingService.resetCacheForTesting()
        let store = try Store.inMemory()
        let id = try insertEntry(in: store)
        let repo = EntryRepository(store: store)
        let sweeper = EmbeddingSweeper(repository: repo)

        let report = try await sweeper.runOnce(limit: 10)
        #expect(report.embedded == 1)
        #expect(report.failed == 0)

        let saved = try repo.embedding(entryId: id)
        #expect(saved != nil)
        #expect(saved?.modelId == EmbeddingService.modelId)
        #expect(saved?.revision == EmbeddingService.revision)
        #expect(saved?.dims ?? 0 > 0)
    }

    @Test("runOnce skips an entry with blank text_preview")
    func runOnceSkipsBlankText() async throws {
        EmbeddingService.resetCacheForTesting()
        let store = try Store.inMemory()
        _ = try insertEntry(in: store, textPreview: "   ")
        let repo = EntryRepository(store: store)
        let sweeper = EmbeddingSweeper(repository: repo)

        let report = try await sweeper.runOnce(limit: 10)
        #expect(report.embedded == 0)
        #expect(report.skippedEmpty == 1)
    }

    @Test("runOnce with no candidates is a no-op")
    func runOnceNoCandidates() async throws {
        EmbeddingService.resetCacheForTesting()
        let store = try Store.inMemory()
        let repo = EntryRepository(store: store)
        let sweeper = EmbeddingSweeper(repository: repo)

        let report = try await sweeper.runOnce(limit: 10)
        #expect(report.candidates == 0)
        #expect(report.embedded == 0)
    }

    @Test("a second runOnce pass does not re-embed an already-current entry")
    func runOnceIsIdempotent() async throws {
        EmbeddingService.resetCacheForTesting()
        let store = try Store.inMemory()
        _ = try insertEntry(in: store)
        let repo = EntryRepository(store: store)
        let sweeper = EmbeddingSweeper(repository: repo)

        _ = try await sweeper.runOnce(limit: 10)
        let second = try await sweeper.runOnce(limit: 10)
        #expect(second.candidates == 0)
    }
}
