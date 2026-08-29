using CpdbWin.Core.Analysis;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// End-to-end smoke tests for the bundled MiniLM embedding pipeline.
/// If the model file didn't ship, the tests skip gracefully — same
/// contract Mac's <c>EmbeddingServiceTests</c> uses for its
/// NLContextualEmbedding path when the framework is unavailable.
/// </summary>
public class EmbeddingServiceTests
{
    [Fact]
    public void IsAvailable_WhenModelBundleShipped_LoadsSuccessfully()
    {
        // The test runner copies Models/*.onnx + Models/*.txt into
        // bin/ via the CpdbWin.Core.csproj CopyToOutputDirectory rule,
        // so IsAvailable must be true here. A false result means the
        // csproj bundle rule broke or the model file wasn't committed.
        Assert.True(EmbeddingService.IsAvailable,
            "Model bundle missing at AppContext.BaseDirectory. Check "
          + "CpdbWin.Core.csproj Models/*.onnx CopyToOutputDirectory.");
    }

    [Fact]
    public void Compute_ProducesUnitVectorOfExpectedDimensions()
    {
        if (!EmbeddingService.IsAvailable) return;
        var v = EmbeddingService.Compute("The quick brown fox jumps over the lazy dog.");
        Assert.NotNull(v);
        Assert.Equal(EmbeddingService.Dimensions, v!.Length);
        // Post-L2-normalize the vector should be a unit vector — this
        // is the invariant hybrid search relies on to reduce cosine
        // similarity to a plain dot product.
        double sq = 0;
        foreach (var x in v) sq += x * x;
        Assert.InRange(Math.Sqrt(sq), 0.999, 1.001);
    }

    [Fact]
    public void Compute_SemanticallySimilarInputs_HaveHigherDotProductThanUnrelated()
    {
        if (!EmbeddingService.IsAvailable) return;
        var vDog1  = EmbeddingService.Compute("The dog is chasing the ball in the park.");
        var vDog2  = EmbeddingService.Compute("A puppy plays fetch on the grass.");
        var vSql   = EmbeddingService.Compute("Query optimizer chose a full table scan instead of the index.");
        Assert.NotNull(vDog1); Assert.NotNull(vDog2); Assert.NotNull(vSql);

        double simDogDog = Dot(vDog1!, vDog2!);
        double simDogSql = Dot(vDog1!, vSql!);

        // Semantic near-neighbours should score noticeably higher than
        // unrelated content. Not a tight bound (model varies + INT8
        // quantization adds noise) — just that the ordering is right.
        Assert.True(simDogDog > simDogSql + 0.15,
            $"Expected dog↔dog ({simDogDog:F3}) > dog↔sql ({simDogSql:F3}) by ≥ 0.15. "
          + "If this fails the model or tokenizer isn't producing meaningful embeddings.");
    }

    [Fact]
    public void SerializeDeserialize_RoundTripsLittleEndianFloat32()
    {
        var v = new float[] { 1.0f, -0.5f, 3.14159f, 0f, float.Epsilon };
        var bytes = EmbeddingService.SerializeLittleEndian(v);
        Assert.Equal(v.Length * 4, bytes.Length);
        var round = EmbeddingService.DeserializeLittleEndian(bytes, v.Length);
        Assert.NotNull(round);
        Assert.Equal(v, round);
    }

    [Fact]
    public void Deserialize_WrongLength_ReturnsNull()
    {
        Assert.Null(EmbeddingService.DeserializeLittleEndian(new byte[13], 384));
        Assert.Null(EmbeddingService.DeserializeLittleEndian(new byte[100], 384));
    }

    [Fact]
    public void Compute_EmptyOrWhitespace_ReturnsNull()
    {
        Assert.Null(EmbeddingService.Compute(null));
        Assert.Null(EmbeddingService.Compute(""));
        Assert.Null(EmbeddingService.Compute("   \n\n"));
    }

    // ── Pure chunk-planner tests (no model needed) ─────────────────────

    [Fact]
    public void Chunk_ShortText_YieldsSingleChunk()
    {
        var chunks = EmbeddingServiceInternals.Chunk("hello world");
        Assert.Single(chunks);
        Assert.Equal("hello world", chunks[0]);
    }

    [Fact]
    public void ApproxTokens_MatchesMacHeuristic()
    {
        // Mac's approx = words × 1.4, rounded up.
        Assert.Equal(0,  EmbeddingServiceInternals.ApproxTokens(""));
        Assert.Equal(2,  EmbeddingServiceInternals.ApproxTokens("hello"));           // ceil(1 × 1.4) = 2
        Assert.Equal(3,  EmbeddingServiceInternals.ApproxTokens("hello world"));      // ceil(2 × 1.4) = 3
        Assert.Equal(14, EmbeddingServiceInternals.ApproxTokens(new string('x', 0) + string.Join(" ", Enumerable.Repeat("word", 10))));  // ceil(10 × 1.4) = 14
    }

    private static double Dot(float[] a, float[] b)
    {
        double s = 0;
        for (int i = 0; i < a.Length; i++) s += a[i] * b[i];
        return s;
    }
}

/// <summary>Tiny reflection shim so the pure-function chunk tests can
/// reach EmbeddingService's <c>internal</c> members without
/// InternalsVisibleTo (which would drag production-shipped
/// [InternalsVisibleTo] into the assembly manifest).</summary>
internal static class EmbeddingServiceInternals
{
    public static IReadOnlyList<string> Chunk(string text) =>
        (IReadOnlyList<string>)typeof(EmbeddingService)
            .GetMethod("Chunk", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!
            .Invoke(null, new object[] { text })!;

    public static int ApproxTokens(string s) =>
        (int)typeof(EmbeddingService)
            .GetMethod("ApproxTokens", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!
            .Invoke(null, new object[] { s })!;
}
