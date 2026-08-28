import Foundation
import Accelerate
import GRDB

/// Brute-force cosine-similarity search over every stored
/// `entry_embeddings` row, held in one contiguous `[Float]` buffer rather
/// than per-row `Data` blobs — a single vDSP dot-product loop instead of
/// 10k heap-scattered reads. At 10k entries × 512 dims × 4 bytes that's
/// ~20MB resident; `search` is sub-millisecond because every vector is
/// already L2-normalized at write time, so dot product IS cosine
/// similarity (no per-query division).
///
/// Invalidation is a generation counter rather than a live
/// `ValueObservation`: nothing renders this index directly, so there's no
/// UI to keep ticking while it's unused. Whoever writes or removes an
/// `entry_embeddings` row (the capture hook, `EmbeddingSweeper`) calls
/// `invalidate()`; the next `search` notices its cached generation is
/// stale and reloads before answering. A search that arrives between a
/// write and the next `invalidate()` call may miss that one row — same
/// staleness window `PopupState`'s fetch-on-demand search already
/// tolerates elsewhere, and self-heals on the next write.
public actor EmbeddingIndex {
    /// Shared instance for production use. Tests construct their own
    /// (`EmbeddingIndex()`) so cached state from one store never leaks
    /// into another test's assertions.
    public static let shared = EmbeddingIndex()

    public struct Result: Sendable, Equatable {
        public var entryId: Int64
        public var score: Float   // cosine similarity, [-1, 1]

        public init(entryId: Int64, score: Float) {
            self.entryId = entryId
            self.score = score
        }
    }

    private struct Loaded {
        var entryIds: [Int64]
        var dims: Int
        var vectors: [Float]   // entryIds.count * dims, row-major, L2-normalized
        var generation: Int
    }

    private var loaded: Loaded?
    private var currentGeneration = 0

    public init() {}

    /// Bump the generation so the next `search` reloads from `store`
    /// instead of serving a cached buffer. Cheap (an integer increment) —
    /// call freely after any write to, or delete affecting,
    /// `entry_embeddings`.
    public func invalidate() {
        currentGeneration += 1
    }

    /// Top-`topK` entries by cosine similarity to `queryVector` (expected
    /// to be `dims` × Float32 little-endian, L2-normalized — the same
    /// layout `EmbeddingService.embed` produces). Reloads from `store`
    /// first if the cache is missing or stale relative to the last
    /// `invalidate()`. Returns `[]` if the index is empty or the query's
    /// dimensionality doesn't match the loaded model's (e.g. mid-upgrade
    /// before a re-embed sweep finishes).
    public func search(queryVector: Data, topK: Int, store: Store) async throws -> [Result] {
        try await reloadIfNeeded(store: store)
        guard let loaded, !loaded.entryIds.isEmpty, topK > 0 else { return [] }
        let query = EmbeddingService.float32Array(fromLittleEndianData: queryVector)
        guard query.count == loaded.dims else { return [] }

        let n = loaded.entryIds.count
        var scores = [Float](repeating: 0, count: n)
        query.withUnsafeBufferPointer { qBuf in
            loaded.vectors.withUnsafeBufferPointer { vBuf in
                guard let qBase = qBuf.baseAddress, let vBase = vBuf.baseAddress else { return }
                scores.withUnsafeMutableBufferPointer { sBuf in
                    for i in 0..<n {
                        var dot: Float = 0
                        vDSP_dotpr(qBase, 1, vBase + i * loaded.dims, 1, &dot, vDSP_Length(loaded.dims))
                        sBuf[i] = dot
                    }
                }
            }
        }

        let k = min(topK, n)
        // topK is small (bounded by the popup's search limit — tens, not
        // thousands) relative to n (thousands), so a bounded selection
        // beats sorting the whole array.
        let ranked = (0..<n).sorted { scores[$0] > scores[$1] }.prefix(k)
        return ranked.map { Result(entryId: loaded.entryIds[$0], score: scores[$0]) }
    }

    /// Rows fetched per round-trip while rebuilding the buffer. Chosen so
    /// a full reload is many small reads rather than one giant one:
    /// `store.dbQueue` is a single-connection `DatabaseQueue` shared with
    /// every other synchronous read in the app (notably `PopupState`'s
    /// summon-time and keystroke-time search, which run right on the
    /// main thread) — one unbroken read of the whole table would hold
    /// that queue for the full scan and stall those. Splitting into
    /// chunks, each its own `read` call with a yield in between, lets a
    /// competing read that arrives mid-reload get its turn between
    /// chunks instead of waiting out the entire table.
    private static let reloadChunkSize = 500

    private func reloadIfNeeded(store: Store) async throws {
        if let loaded, loaded.generation == currentGeneration { return }
        let generationAtStart = currentGeneration

        var rows: [Row] = []
        var offset = 0
        while true {
            let offsetForThisChunk = offset
            let chunk = try await store.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT entry_id, model_id, revision, dims, vector
                        FROM entry_embeddings
                        ORDER BY entry_id
                        LIMIT ? OFFSET ?
                    """,
                    arguments: [Self.reloadChunkSize, offsetForThisChunk]
                )
            }
            rows.append(contentsOf: chunk)
            if chunk.count < Self.reloadChunkSize { break }
            offset += chunk.count
            await Task.yield()
        }

        // A concurrent invalidate() (or a whole second reload racing in
        // from another `search` call) means this snapshot may already be
        // stale — don't stamp it with a generation newer than what it
        // actually reflects, and don't clobber a fresher `loaded` that
        // finished first. The next `search` will reload again.
        guard currentGeneration == generationAtStart else { return }
        if let loaded, loaded.generation >= generationAtStart { return }

        // Group by (model_id, revision) and keep only the largest group.
        // A bare `dims` check on an arbitrary row (the previous
        // approach) can't tell two same-dims models/revisions apart —
        // it would silently fuse vectors from incompatible embedding
        // spaces, where cosine similarity is meaningless. And picking
        // whichever row happened to load first (oldest, by rowid) as
        // the dims authority means one leftover stale-revision row can
        // make every current row look "mismatched" and get skipped.
        // The largest group is the current model in steady state, or
        // whichever side is winning a mid-backfill transition — either
        // way a single consistent embedding space.
        struct GroupKey: Hashable {
            var modelId: String
            var revision: Int64
        }
        var groups: [GroupKey: [Row]] = [:]
        for row in rows {
            let key = GroupKey(modelId: row["model_id"], revision: row["revision"])
            groups[key, default: []].append(row)
        }
        guard let winningRows = groups.values.max(by: { $0.count < $1.count }),
              let firstDims = winningRows.first.map({ Int($0["dims"] as Int64) }),
              firstDims > 0
        else {
            loaded = Loaded(entryIds: [], dims: 0, vectors: [], generation: currentGeneration)
            return
        }

        var ids: [Int64] = []
        ids.reserveCapacity(winningRows.count)
        var buffer: [Float] = []
        buffer.reserveCapacity(winningRows.count * firstDims)
        for row in winningRows {
            let dims: Int64 = row["dims"]
            guard Int(dims) == firstDims else { continue }
            let vectorData: Data = row["vector"]
            let floats = EmbeddingService.float32Array(fromLittleEndianData: vectorData)
            guard floats.count == firstDims else { continue }
            ids.append(row["entry_id"])
            buffer.append(contentsOf: floats)
        }
        loaded = Loaded(entryIds: ids, dims: firstDims, vectors: buffer, generation: currentGeneration)
    }
}
