using System.Buffers.Binary;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using Microsoft.ML.Tokenizers;

namespace CpdbWin.Core.Analysis;

/// <summary>
/// On-device sentence-embedding service for cpdb-win's semantic search.
/// Bundled model + tokenizer: <c>all-MiniLM-L6-v2</c> (INT8 quantized,
/// ~22 MB, 384-dim, BERT WordPiece tokenization) loaded lazily via
/// <see cref="Microsoft.ML.OnnxRuntime"/> + <see cref="BertTokenizer"/>.
///
/// <para>
/// Mirrors the shape of <c>Sources/CpdbShared/Analysis/EmbeddingService.swift</c>
/// (Mac uses NLContextualEmbedding, 512-dim; Windows uses ONNX MiniLM,
/// 384-dim — cross-platform vectors do NOT compare, and the schema's
/// <c>model_id</c>/<c>revision</c> columns exist precisely to record
/// which model produced which vector). Per docs/handoffs/windows-v33-
/// features.md.
/// </para>
///
/// <para>
/// <b>Concurrency:</b> the ONNX <see cref="InferenceSession"/> is not
/// documented as thread-safe, so calls funnel through a
/// <see cref="SemaphoreSlim"/>. First-callers race on init is coalesced
/// via a <see cref="Lazy{T}"/>. Once
/// <see cref="IsAvailable"/> returns false, the class stays unavailable
/// until process restart — model-load failures are almost always
/// deterministic (missing file, wrong architecture), so re-probing per
/// row would burn CPU for nothing.
/// </para>
/// </summary>
public static class EmbeddingService
{
    /// <summary>Written to <c>entry_embeddings.model_id</c> for every
    /// vector this service produces. Bump alongside a physical model
    /// swap; sweep will re-embed rows whose stored <c>model_id</c> no
    /// longer matches.</summary>
    public const string ModelId = "onnx-minilm-l6-v2-quantized";

    /// <summary>Written to <c>entry_embeddings.revision</c>. Bump for a
    /// preprocessing tweak to the same model (e.g. new normalization
    /// step) without changing <see cref="ModelId"/>. Sweep re-embeds
    /// rows below the current revision.</summary>
    public const int Revision = 1;

    /// <summary>Output dimension of the bundled model. Also written to
    /// <c>entry_embeddings.dims</c> so the reader can validate before
    /// deserialising into a <c>float[Dimensions]</c> buffer.</summary>
    public const int Dimensions = 384;

    /// <summary>MiniLM's positional embeddings top out at 512 tokens;
    /// the Xenova ONNX export was calibrated at 128. We hard-cap
    /// per-chunk encoding at 256 — comfortably below both — and chunk
    /// longer inputs at paragraph boundaries then mean-pool. Matches
    /// the Mac's <c>maxTokensPerChunk = 256</c>.</summary>
    public const int MaxTokensPerChunk = 256;

    private const string ModelFile = "Models/all-minilm-l6-v2-quantized.onnx";
    private const string VocabFile = "Models/all-minilm-l6-v2-vocab.txt";

    // Lazy init coalesced across concurrent first-callers. `.Value` on
    // multiple threads runs the factory exactly once; the LazyThreadSafetyMode
    // default is ExecutionAndPublication which is what we want.
    private static readonly Lazy<Loaded?> _loaded = new(TryLoad);
    // Serialize inference — ONNX InferenceSession isn't documented as
    // thread-safe. Init happens under Lazy, so this only guards Run.
    private static readonly SemaphoreSlim _inferLock = new(1, 1);

    private sealed record Loaded(InferenceSession Session, BertTokenizer Tokenizer);

    /// <summary>
    /// True when the model + vocab loaded successfully. Sticky: once
    /// false, stays false until process restart (deterministic failure
    /// mode — retrying per row wouldn't help). Callers gate embedding
    /// work on this so a missing bundle doesn't spam exceptions.
    /// </summary>
    public static bool IsAvailable => _loaded.Value is not null;

    /// <summary>
    /// Embed <paramref name="text"/> into a <see cref="Dimensions"/>-dim
    /// L2-normalized <see cref="float"/>[] vector. Returns null when the
    /// model isn't available, when the text is empty, or when tokenization
    /// yields no non-special tokens. Cosine similarity between two
    /// results is a plain dot product (both are unit vectors).
    /// </summary>
    public static float[]? Compute(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var loaded = _loaded.Value;
        if (loaded is null) return null;

        var chunks = Chunk(text);
        if (chunks.Count == 0) return null;

        var pooled = new float[Dimensions];
        int chunkCount = 0;
        _inferLock.Wait();
        try
        {
            foreach (var chunk in chunks)
            {
                var vec = EmbedOne(loaded, chunk);
                if (vec is null) continue;
                for (int i = 0; i < Dimensions; i++) pooled[i] += vec[i];
                chunkCount++;
            }
        }
        finally
        {
            _inferLock.Release();
        }
        if (chunkCount == 0) return null;
        for (int i = 0; i < Dimensions; i++) pooled[i] /= chunkCount;
        L2Normalize(pooled);
        return pooled;
    }

    /// <summary>
    /// Serialize a vector for the <c>entry_embeddings.vector</c> BLOB
    /// column: <c>dims × Float32 little-endian</c>. Matches the Mac
    /// binary layout exactly so a future sync substrate can move
    /// bytes without transcoding.
    /// </summary>
    public static byte[] SerializeLittleEndian(float[] vector)
    {
        var bytes = new byte[vector.Length * sizeof(float)];
        for (int i = 0; i < vector.Length; i++)
        {
            BinaryPrimitives.WriteSingleLittleEndian(
                bytes.AsSpan(i * sizeof(float), sizeof(float)), vector[i]);
        }
        return bytes;
    }

    /// <summary>Inverse of <see cref="SerializeLittleEndian"/>. Returns
    /// null if <paramref name="bytes"/>.Length is not divisible by 4 or
    /// doesn't match <paramref name="expectedDims"/> × 4.</summary>
    public static float[]? DeserializeLittleEndian(byte[] bytes, int expectedDims)
    {
        if (bytes.Length != expectedDims * sizeof(float)) return null;
        var vec = new float[expectedDims];
        for (int i = 0; i < expectedDims; i++)
        {
            vec[i] = BinaryPrimitives.ReadSingleLittleEndian(
                bytes.AsSpan(i * sizeof(float), sizeof(float)));
        }
        return vec;
    }

    // ── Internals ────────────────────────────────────────────────────────

    private static Loaded? TryLoad()
    {
        try
        {
            var baseDir = AppContext.BaseDirectory;
            var modelPath = Path.Combine(baseDir, ModelFile);
            var vocabPath = Path.Combine(baseDir, VocabFile);
            if (!File.Exists(modelPath) || !File.Exists(vocabPath)) return null;

            using var vocabStream = File.OpenRead(vocabPath);
            var tokenizer = BertTokenizer.Create(vocabStream);
            var session   = new InferenceSession(modelPath);
            return new Loaded(session, tokenizer);
        }
        catch
        {
            // Missing native runtime, wrong architecture, corrupted
            // model, tokenizer parse failure — all deterministic once
            // this process is running. Sticky-unavailable via the Lazy
            // caching null.
            return null;
        }
    }

    /// <summary>
    /// Split <paramref name="text"/> into ≤ <see cref="MaxTokensPerChunk"/>-
    /// token chunks. Prefers paragraph boundaries; falls back to
    /// sentence-ish splitting (period/newline runs) when a paragraph
    /// blows the cap. Non-word tokens are approximated at 1.4× word
    /// count — matches the Mac's <c>approxTokenCount</c> heuristic
    /// (words × 1.4, rounded up) so chunk sizes come out similar.
    /// </summary>
    internal static IReadOnlyList<string> Chunk(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return Array.Empty<string>();
        if (ApproxTokens(trimmed) <= MaxTokensPerChunk)
            return new[] { trimmed };

        var paragraphs = trimmed
            .Replace("\r\n", "\n")
            .Split(new[] { "\n\n" }, StringSplitOptions.RemoveEmptyEntries);
        var chunks = new List<string>();
        var cur = new System.Text.StringBuilder();
        int curTokens = 0;
        foreach (var raw in paragraphs)
        {
            var p = raw.Trim();
            if (p.Length == 0) continue;
            var pt = ApproxTokens(p);
            if (pt > MaxTokensPerChunk)
            {
                // Paragraph on its own is too big — pack by sentence.
                if (cur.Length > 0) { chunks.Add(cur.ToString()); cur.Clear(); curTokens = 0; }
                foreach (var s in SplitSentences(p))
                {
                    var st = ApproxTokens(s);
                    if (curTokens + st > MaxTokensPerChunk && cur.Length > 0)
                    {
                        chunks.Add(cur.ToString()); cur.Clear(); curTokens = 0;
                    }
                    if (cur.Length > 0) cur.Append(' ');
                    cur.Append(s);
                    curTokens += st;
                }
                continue;
            }
            if (curTokens + pt > MaxTokensPerChunk && cur.Length > 0)
            {
                chunks.Add(cur.ToString()); cur.Clear(); curTokens = 0;
            }
            if (cur.Length > 0) cur.Append("\n\n");
            cur.Append(p);
            curTokens += pt;
        }
        if (cur.Length > 0) chunks.Add(cur.ToString());
        return chunks;
    }

    internal static int ApproxTokens(string s)
    {
        if (string.IsNullOrEmpty(s)) return 0;
        // Word count × 1.4, rounded up. Simple + portable — matches
        // Mac's heuristic exactly.
        int words = s.Split(default(char[]), StringSplitOptions.RemoveEmptyEntries).Length;
        return (int)Math.Ceiling(words * 1.4);
    }

    private static IEnumerable<string> SplitSentences(string p)
    {
        // Deliberately narrow — a real sentence splitter would need
        // locale + abbreviation heuristics we don't want to maintain.
        // For clipboard text this is good enough; over-splitting just
        // costs a few extra inference calls.
        var parts = System.Text.RegularExpressions.Regex.Split(p, @"(?<=[\.!\?])\s+");
        foreach (var s in parts)
        {
            var t = s.Trim();
            if (t.Length > 0) yield return t;
        }
    }

    /// <summary>Single-chunk inference: tokenize → run ONNX →
    /// attention-mask-weighted mean pool over token embeddings.
    /// Not L2-normalized (caller pools across chunks first). Caller
    /// holds <see cref="_inferLock"/>.</summary>
    private static float[]? EmbedOne(Loaded loaded, string chunk)
    {
        var intIds = loaded.Tokenizer.EncodeToIds(chunk).ToArray();
        if (intIds.Length < 2) return null;  // [CLS] + [SEP] at minimum

        // Enforce per-chunk cap: truncate before running (BertTokenizer
        // itself may already respect the tokenizer.json's max_length, but
        // Chunk() sizes on approximate tokens and the actual WordPiece
        // count can drift, so belt-and-braces here).
        int seq = Math.Min(intIds.Length, MaxTokensPerChunk);
        var ids  = new long[seq];
        var mask = new long[seq];
        var typeIds = new long[seq];
        for (int i = 0; i < seq; i++) { ids[i] = intIds[i]; mask[i] = 1L; typeIds[i] = 0L; }

        int[] shape = new int[] { 1, seq };
        var inputs = new List<NamedOnnxValue>
        {
            NamedOnnxValue.CreateFromTensor("input_ids",      new DenseTensor<long>(ids,     shape)),
            NamedOnnxValue.CreateFromTensor("attention_mask", new DenseTensor<long>(mask,    shape)),
            NamedOnnxValue.CreateFromTensor("token_type_ids", new DenseTensor<long>(typeIds, shape)),
        };

        using var results = loaded.Session.Run(inputs);
        var lastHidden = results.First().AsTensor<float>();
        var dims = lastHidden.Dimensions;
        if (dims.Length != 3 || dims[2] != Dimensions) return null;

        var pooled = new float[Dimensions];
        float denom = 0;
        for (int t = 0; t < seq; t++)
        {
            if (mask[t] == 0) continue;
            denom++;
            for (int h = 0; h < Dimensions; h++) pooled[h] += lastHidden[0, t, h];
        }
        if (denom == 0) return null;
        for (int h = 0; h < Dimensions; h++) pooled[h] /= denom;
        return pooled;
    }

    private static void L2Normalize(float[] v)
    {
        double sq = 0;
        for (int i = 0; i < v.Length; i++) sq += v[i] * v[i];
        var norm = Math.Sqrt(sq);
        if (norm == 0) return;
        for (int i = 0; i < v.Length; i++) v[i] = (float)(v[i] / norm);
    }
}
