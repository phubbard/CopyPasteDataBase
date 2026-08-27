import Testing
import Foundation
import GRDB
@testable import CpdbShared

/// Correctness tests for `EmbeddingIndex.search` against synthetic
/// vectors — no `NLContextualEmbedding` involved, so these run
/// unconditionally. Each test builds its own `EmbeddingIndex()` instance
/// (not `.shared`) so cached state from one test never leaks into
/// another's assertions.
@Suite("EmbeddingIndex search")
struct EmbeddingIndexTests {

    private func insertEntry(in store: Store, textPreview: String = "x") throws -> Int64 {
        try store.dbQueue.write { db in
            let devId: Int64
            if let existing = try Device.filter(Column("identifier") == "test-device").fetchOne(db) {
                devId = existing.id!
            } else {
                var d = Device(identifier: "test-device", name: "Test", kind: "mac")
                try d.insert(db)
                devId = d.id!
            }
            var entry = Entry(
                uuid: Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
                createdAt: Date().timeIntervalSince1970,
                capturedAt: Date().timeIntervalSince1970,
                kind: .text,
                sourceDeviceId: devId,
                title: nil,
                textPreview: textPreview,
                contentHash: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                totalSize: 10
            )
            try entry.insert(db)
            return entry.id!
        }
    }

    /// Encode a plain `[Float]` (not necessarily normalized — tests
    /// exercise the raw dot-product math) as little-endian bytes,
    /// mirroring the layout `EmbeddingService` writes.
    private func encode(_ v: [Float]) -> Data {
        var data = Data(capacity: v.count * 4)
        for f in v {
            var bits = f.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func saveEmbedding(_ store: Store, entryId: Int64, vector: [Float]) throws {
        try store.dbQueue.write { db in
            try EntryRepository.saveEmbedding(
                entryId: entryId, modelId: "test", revision: 1,
                dims: Int64(vector.count), vector: encode(vector), in: db
            )
        }
    }

    @Test("search ranks the identical vector first with score 1.0")
    func searchRanksIdenticalVectorFirst() async throws {
        let store = try Store.inMemory()
        let idA = try insertEntry(in: store)
        let idB = try insertEntry(in: store)
        let idC = try insertEntry(in: store)
        // Unit vectors in 2D: A = query direction, B = orthogonal, C = opposite.
        try saveEmbedding(store, entryId: idA, vector: [1, 0])
        try saveEmbedding(store, entryId: idB, vector: [0, 1])
        try saveEmbedding(store, entryId: idC, vector: [-1, 0])

        let index = EmbeddingIndex()
        let results = try await index.search(queryVector: encode([1, 0]), topK: 3, store: store)

        #expect(results.count == 3)
        #expect(results[0].entryId == idA)
        #expect(abs(results[0].score - 1.0) < 1e-5)
        #expect(results[1].entryId == idB)
        #expect(abs(results[1].score - 0.0) < 1e-5)
        #expect(results[2].entryId == idC)
        #expect(abs(results[2].score - (-1.0)) < 1e-5)
    }

    @Test("search respects topK")
    func searchRespectsTopK() async throws {
        let store = try Store.inMemory()
        for i in 0..<5 {
            let id = try insertEntry(in: store)
            try saveEmbedding(store, entryId: id, vector: [Float(i), 1])
        }
        let index = EmbeddingIndex()
        let results = try await index.search(queryVector: encode([1, 0]), topK: 2, store: store)
        #expect(results.count == 2)
    }

    @Test("search on an empty index returns no results")
    func searchEmptyIndex() async throws {
        let store = try Store.inMemory()
        let index = EmbeddingIndex()
        let results = try await index.search(queryVector: encode([1, 0]), topK: 5, store: store)
        #expect(results.isEmpty)
    }

    @Test("search returns empty when the query's dimensionality doesn't match stored vectors")
    func searchDimensionMismatch() async throws {
        let store = try Store.inMemory()
        let id = try insertEntry(in: store)
        try saveEmbedding(store, entryId: id, vector: [1, 0, 0])
        let index = EmbeddingIndex()
        let results = try await index.search(queryVector: encode([1, 0]), topK: 5, store: store)
        #expect(results.isEmpty)
    }

    @Test("search reloads after invalidate() to pick up a newly-saved embedding")
    func searchReloadsAfterInvalidate() async throws {
        let store = try Store.inMemory()
        let idA = try insertEntry(in: store)
        try saveEmbedding(store, entryId: idA, vector: [1, 0])

        let index = EmbeddingIndex()
        let first = try await index.search(queryVector: encode([1, 0]), topK: 5, store: store)
        #expect(first.map(\.entryId) == [idA])

        let idB = try insertEntry(in: store)
        try saveEmbedding(store, entryId: idB, vector: [1, 0])
        // Without invalidate(), the cached buffer from `first` above
        // would still be served.
        let stale = try await index.search(queryVector: encode([1, 0]), topK: 5, store: store)
        #expect(stale.count == 1, "cache should still be serving the pre-insert snapshot")

        await index.invalidate()
        let fresh = try await index.search(queryVector: encode([1, 0]), topK: 5, store: store)
        #expect(Set(fresh.map(\.entryId)) == Set([idA, idB]))
    }

    @Test("a separate EmbeddingIndex instance starts with no cached state")
    func separateInstancesDoNotShareCache() async throws {
        let store = try Store.inMemory()
        let id = try insertEntry(in: store)
        try saveEmbedding(store, entryId: id, vector: [1, 0])

        let indexOne = EmbeddingIndex()
        _ = try await indexOne.search(queryVector: encode([1, 0]), topK: 5, store: store)

        let indexTwo = EmbeddingIndex()
        let results = try await indexTwo.search(queryVector: encode([1, 0]), topK: 5, store: store)
        #expect(results.map(\.entryId) == [id])
    }
}
