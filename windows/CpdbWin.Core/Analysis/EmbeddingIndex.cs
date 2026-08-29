using System.Numerics.Tensors;
using CpdbWin.Core.Store;

namespace CpdbWin.Core.Analysis;

/// <summary>
/// In-memory cosine-similarity search over the vectors persisted in
/// <c>entry_embeddings</c>. Windows port of macOS
/// <c>Sources/CpdbShared/Analysis/EmbeddingIndex.swift</c>.
///
/// <para>
/// Sized for the 10k-entry library the Mac's design targets:
/// 10k × 384 × 4 B ≈ 15 MB of contiguous <see cref="float"/> — small
/// enough to keep in RAM, big enough to make one query a
/// <see cref="System.Numerics.Tensors.TensorPrimitives"/> dot product
/// per row (~sub-ms). No approximate-nearest-neighbour index needed at
/// this scale.
/// </para>
///
/// <para>
/// <b>Invalidation:</b> writers of <c>entry_embeddings</c> (the sweeper,
/// a re-embed after model bump) call <see cref="Invalidate"/> which
/// bumps a generation counter. The next
/// <see cref="Search(float[], int)"/> reloads the cache before searching.
/// A race-guard on <see cref="_generation"/> during reload means a
/// mid-reload invalidation gets re-picked up on the next call.
/// </para>
///
/// <para>
/// <b>Model boundary:</b> rows in <c>entry_embeddings</c> may span two
/// generations of the model briefly (during a re-embed sweep after a
/// model bump). The index groups by <c>(model_id, revision)</c> and
/// keeps only the largest group — the one the fresh writes are landing
/// in — so cosine similarity is always computed against a homogeneous
/// space. Matches Mac's <c>reloadChunkSize</c>-driven behaviour.
/// </para>
/// </summary>
public sealed class EmbeddingIndex
{
    private readonly EntryRepository _entries;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private Loaded? _loaded;
    private long _generation = 1;

    public EmbeddingIndex(EntryRepository entries) => _entries = entries;

    /// <summary>Top-K cosine-similarity result.</summary>
    public readonly record struct Result(long EntryId, float Score);

    private sealed record Loaded(
        long[] EntryIds,
        int Dims,
        float[] Vectors,          // row-major, length = EntryIds.Length * Dims
        string ModelId,
        int Revision,
        long Generation);

    /// <summary>Signal that a writer changed <c>entry_embeddings</c>.
    /// The next search will reload the cache from SQLite before matching.
    /// Cheap: just bumps a counter.</summary>
    public void Invalidate() => Interlocked.Increment(ref _generation);

    /// <summary>
    /// Return the top-<paramref name="topK"/> entries by cosine
    /// similarity to <paramref name="queryVector"/>, filtered by an
    /// optional score floor. Empty result when the index has no rows,
    /// when the query dimension doesn't match the index (mid-model-swap
    /// guard), or when nothing clears the floor.
    /// </summary>
    public async Task<IReadOnlyList<Result>> SearchAsync(
        float[] queryVector, int topK, float scoreFloor = 0.0f, CancellationToken ct = default)
    {
        var snapshot = await EnsureLoadedAsync(ct).ConfigureAwait(false);
        if (snapshot is null || snapshot.EntryIds.Length == 0 || topK <= 0) return Array.Empty<Result>();
        if (queryVector.Length != snapshot.Dims) return Array.Empty<Result>();
        // Score + sort in a sync helper: TensorPrimitives.Dot needs
        // Span args, and Span isn't allowed inside async method bodies
        // pre-C# 13.
        return SearchSync(snapshot, queryVector, topK, scoreFloor);
    }

    private static IReadOnlyList<Result> SearchSync(Loaded snapshot, float[] queryVector, int topK, float scoreFloor)
    {
        int n = snapshot.EntryIds.Length;
        int dims = snapshot.Dims;
        var scores = new float[n];
        // Dot product = cosine similarity because both sides are already
        // L2-normalized (EmbeddingService.Compute guarantees the stored
        // side; caller is responsible for the query side).
        var q = queryVector.AsSpan();
        for (int i = 0; i < n; i++)
        {
            var row = snapshot.Vectors.AsSpan(i * dims, dims);
            scores[i] = TensorPrimitives.Dot(row, q);
        }

        // Full sort of indices by score DESC. For N ≤ ~10k a full sort
        // is cheap enough that a priority-queue optimisation isn't
        // worth the complexity.
        var indices = new int[n];
        for (int i = 0; i < n; i++) indices[i] = i;
        Array.Sort(indices, (a, b) => scores[b].CompareTo(scores[a]));

        var results = new List<Result>(Math.Min(topK, n));
        for (int rank = 0; rank < n && results.Count < topK; rank++)
        {
            var i = indices[rank];
            var score = scores[i];
            if (score < scoreFloor) break;  // sorted DESC → done once below floor
            results.Add(new Result(snapshot.EntryIds[i], score));
        }
        return results;
    }

    private async Task<Loaded?> EnsureLoadedAsync(CancellationToken ct)
    {
        var snap = _loaded;
        if (snap is not null && snap.Generation == Interlocked.Read(ref _generation))
            return snap;

        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            // Re-check under lock: another caller may have reloaded already.
            snap = _loaded;
            var gen = Interlocked.Read(ref _generation);
            if (snap is not null && snap.Generation == gen) return snap;

            var rows = _entries.LoadAllEmbeddings();
            if (rows.Count == 0)
            {
                _loaded = new Loaded(Array.Empty<long>(), 0, Array.Empty<float>(),
                    ModelId: EmbeddingService.ModelId,
                    Revision: EmbeddingService.Revision,
                    Generation: gen);
                return _loaded;
            }

            // Steady-state consistency: keep only the biggest
            // (model_id, revision) group. A re-embed after a model
            // bump migrates rows one at a time; the tie-break here
            // ensures search always runs against a homogeneous space.
            var groups = rows.GroupBy(r => (r.ModelId, r.Revision))
                             .OrderByDescending(g => g.Count())
                             .ThenBy(g => g.Key.ModelId, StringComparer.Ordinal);
            var chosen = groups.First().ToArray();
            var dims = chosen[0].Dims;
            var homogeneous = chosen.Where(r => r.Dims == dims).ToArray();

            var ids = new long[homogeneous.Length];
            var buf = new float[homogeneous.Length * dims];
            for (int i = 0; i < homogeneous.Length; i++)
            {
                ids[i] = homogeneous[i].EntryId;
                var v = EmbeddingService.DeserializeLittleEndian(homogeneous[i].Vector, dims);
                if (v is null) continue;
                Array.Copy(v, 0, buf, i * dims, dims);
            }

            _loaded = new Loaded(ids, dims, buf,
                ModelId: chosen[0].ModelId,
                Revision: chosen[0].Revision,
                Generation: gen);
            return _loaded;
        }
        finally
        {
            _lock.Release();
        }
    }
}

/// <summary>
/// Pure Reciprocal Rank Fusion of two ranked id lists — the
/// combining step in cpdb's hybrid FTS5 + semantic search. Windows
/// port of Mac's <c>fuseByReciprocalRank</c>. Kept in its own class so
/// unit tests can exercise it without any DB / model plumbing.
/// </summary>
public static class HybridRank
{
    /// <summary>Cormack et al. RRF default. Larger values weight the
    /// combined ranking toward more evenly-scored candidates; k=60
    /// is what the semantic-search literature settled on.</summary>
    public const double DefaultRrfK = 60.0;

    /// <summary>Semantic-search similarity floor. Cosine scores below
    /// this are dropped before fusion so garbage queries don't inject
    /// noise into the merged ranking. Empirical threshold Mac tuned in
    /// 3.3.0.</summary>
    public const float DefaultSemanticFloor = 0.35f;

    /// <summary>Cap on semantic candidates fetched before fusion.
    /// Deliberately smaller than the popup's page-size (100) so the
    /// FTS list still dominates for exact-word queries.</summary>
    public const int DefaultSemanticTopK = 50;

    /// <summary>
    /// Fuse two 1-indexed rank lists via
    /// <c>score(id) = sum over sources of 1 / (k + rank_1based)</c>.
    /// Ids appearing in both lists get contributions from both.
    /// Ties broken by id DESC (determinism only — the ranks disagreed
    /// on ordering so any tiebreak is arbitrary, but a stable one
    /// gives reproducible search results).
    /// </summary>
    public static IReadOnlyList<long> Fuse(IReadOnlyList<long> ftsIds, IReadOnlyList<long> semanticIds, double k = DefaultRrfK)
    {
        var scores = new Dictionary<long, double>(capacity: ftsIds.Count + semanticIds.Count);
        Accumulate(scores, ftsIds, k);
        Accumulate(scores, semanticIds, k);
        return scores
            .OrderByDescending(kv => kv.Value)
            .ThenByDescending(kv => kv.Key)
            .Select(kv => kv.Key)
            .ToList();
    }

    private static void Accumulate(Dictionary<long, double> scores, IReadOnlyList<long> ids, double k)
    {
        for (int i = 0; i < ids.Count; i++)
        {
            var id = ids[i];
            var contribution = 1.0 / (k + (i + 1));
            scores.TryGetValue(id, out var existing);
            scores[id] = existing + contribution;
        }
    }
}
