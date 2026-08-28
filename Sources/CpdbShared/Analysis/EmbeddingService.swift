import Foundation
import NaturalLanguage

/// On-device text embeddings via `NLContextualEmbedding` — Apple's
/// contextual sentence/paragraph embedding model, resident on-device once
/// its assets are downloaded (no network call per embed).
///
/// Generation (embedding entries and storing the result) is Mac-only —
/// see `EmbeddingSweeper`'s doc comment, and the capture hook in
/// `Ingestor.ingest`, both gated `#if os(macOS)`. This type itself has no
/// platform gate: `NLContextualEmbedding` is iOS 17+ too, and iOS embeds
/// the popup's SEARCH QUERY through the same `embed(text:)` entry point
/// (a query embed is a one-off, not a standing background cost).
///
/// Model identity: `.latin` script covers the common case (English and
/// most Western-European languages cpdb users are likely to paste) with a
/// single resident model rather than one per language. A future revision
/// could route through `NLLanguageRecognizer` to pick script-specific
/// models for non-Latin content; not done here because that would also
/// mean storing per-entry which script's model produced a vector (cosine
/// similarity across differently-trained embedding spaces is meaningless),
/// which the v12 schema's single `model_id`/`revision` pair doesn't yet
/// carry. Latin-only is the honest MVP: non-Latin text still gets FTS.
public enum EmbeddingService {
    /// Persisted alongside every vector in `entry_embeddings` — bump
    /// `revision` (not this string) on a model/behavior change so
    /// `entriesNeedingEmbedding` knows to re-embed everything.
    public static let modelId = "nl-contextual-v1"
    public static let revision: Int64 = 1

    /// Chunk boundary, in approximate subword tokens. `NLContextualEmbedding`
    /// truncates silently past `maximumSequenceLength` (a real limit read
    /// from the loaded model, typically in the low hundreds) — chunking
    /// well under that lets `embed(text:)` fold in signal from the whole
    /// capture instead of just its first paragraph.
    public static let maxTokensPerChunk = 256

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedModel: NLContextualEmbedding?
    nonisolated(unsafe) private static var cachedUnavailable = false
    nonisolated(unsafe) private static var loggedUnavailableOnce = false
    /// In-flight model load, so concurrent first callers await the same
    /// probe instead of each constructing/loading their own
    /// `NLContextualEmbedding` — see `prepare()`.
    nonisolated(unsafe) private static var loadTask: Task<NLContextualEmbedding?, Never>?

    /// True once the Latin-script model is loaded and ready to embed.
    /// False (persistently, until relaunch) once unavailability has been
    /// confirmed once — callers (the sweep, the capture hook) should stop
    /// probing per-entry rather than repeat a failed asset check.
    public static func isAvailable() async -> Bool {
        await prepare() != nil
    }

    /// The loaded model's vector width, or nil if unavailable. Read at
    /// runtime rather than hardcoded — Apple's docs describe 512-dim
    /// vectors for the current Latin model, but `saveEmbedding` should
    /// persist whatever the resident model actually reports.
    public static func currentDims() async -> Int64? {
        guard let model = await prepare() else { return nil }
        return Int64(model.dimension)
    }

    /// Embed `text`: split into ≤`maxTokensPerChunk`-token chunks along
    /// paragraph/sentence boundaries, mean-pool each chunk's per-token
    /// vectors, mean-pool across chunks, then L2-normalize. Returns nil if
    /// the model is unavailable, `text` is blank, or every chunk fails to
    /// embed.
    public static func embed(text: String) async -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let model = await prepare() else { return nil }

        let chunks = Self.chunk(trimmed, maxTokens: maxTokensPerChunk)
        guard !chunks.isEmpty else { return nil }

        var summed: [Double]?
        var chunkCount = 0
        for piece in chunks {
            // Routed through `inferenceQueue` — Apple doesn't document
            // `NLContextualEmbedding` as safe for concurrent calls on one
            // instance (unlike `NLTokenizer`, whose header says so
            // explicitly), and this same cached model instance is shared
            // across the capture hook, the backlog sweep, and every
            // popup query embed, any of which can be in flight at once.
            // Serializing here is cheap insurance against a real
            // concurrency hazard, not a performance-critical section.
            guard let vector = await inferenceQueue.meanPooledVector(for: piece, model: model) else { continue }
            if summed == nil {
                summed = vector
            } else {
                for i in 0..<vector.count { summed![i] += vector[i] }
            }
            chunkCount += 1
        }
        guard var pooled = summed, chunkCount > 0 else { return nil }
        let denom = Double(chunkCount)
        for i in 0..<pooled.count { pooled[i] /= denom }
        normalizeL2(&pooled)
        return littleEndianFloat32Data(from: pooled)
    }

    // MARK: - Model lifecycle

    /// `NSLock.lock()`/`unlock()` are flagged when called directly inside
    /// an `async` function body (a Swift 6 strict-concurrency error, a
    /// warning under today's mode) — routing through this synchronous
    /// helper keeps the actual lock/unlock pair lexically inside a
    /// non-async function, which the diagnostic doesn't flag, without
    /// pulling in an actor just to guard three booleans.
    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Snapshot of `withLock`'s three-way read: a resident model, a
    /// confirmed-unavailable verdict, or "not decided yet — go probe".
    private enum CacheState {
        case ready(NLContextualEmbedding)
        case unavailable
        case undecided
    }

    private static func prepare() async -> NLContextualEmbedding? {
        switch withLock({ () -> CacheState in
            if let cachedModel { return .ready(cachedModel) }
            if cachedUnavailable { return .unavailable }
            return .undecided
        }) {
        case .ready(let model): return model
        case .unavailable: return nil
        case .undecided: break
        }

        // Three independent probes race by design at cold start (the
        // popup's availability check, the periodic sweep's first tick,
        // the first capture's embed hook) — without coalescing, every
        // one of them would see `.undecided` above and construct,
        // request assets for, and load its own `NLContextualEmbedding`
        // in parallel, only for all but the last to be discarded. Route
        // concurrent undecided callers onto the same in-flight `Task`
        // instead so the model loads once.
        let task: Task<NLContextualEmbedding?, Never> = withLock {
            if let loadTask { return loadTask }
            let t = Task { await Self.loadModel() }
            loadTask = t
            return t
        }
        return await task.value
    }

    private static func loadModel() async -> NLContextualEmbedding? {
        guard let model = NLContextualEmbedding(script: .latin) else {
            markUnavailable("NLContextualEmbedding(script: .latin) returned nil — unsupported on this OS")
            withLock { loadTask = nil }
            return nil
        }
        if !model.hasAvailableAssets {
            let result: NLContextualEmbedding.AssetsResult
            do {
                result = try await model.requestAssets()
            } catch {
                markUnavailable("requestAssets threw: \(error)")
                withLock { loadTask = nil }
                return nil
            }
            guard result == .available else {
                markUnavailable("assets not available after request (\(result))")
                withLock { loadTask = nil }
                return nil
            }
        }
        do {
            try model.load()
        } catch {
            markUnavailable("load() failed: \(error)")
            withLock { loadTask = nil }
            return nil
        }

        withLock {
            cachedModel = model
            loadTask = nil
        }
        return model
    }

    private static func markUnavailable(_ reason: String) {
        withLock { cachedUnavailable = true }
        if !loggedUnavailableOnce {
            loggedUnavailableOnce = true
            Log.capture.info("EmbeddingService unavailable: \(reason, privacy: .public)")
        }
    }

    /// Test-only hook: forces the next `isAvailable()`/`embed(text:)` call
    /// to re-probe instead of serving a cached (un)availability verdict.
    /// Production code never needs this — the whole point of the cache is
    /// that a real process only decides once.
    static func resetCacheForTesting() {
        withLock {
            cachedModel = nil
            cachedUnavailable = false
            loggedUnavailableOnce = false
            loadTask = nil
        }
    }

    // MARK: - Pooling

    /// Serializes every call into `NLContextualEmbedding.embeddingResult`
    /// on the shared cached model. An actor (not a lock) because the work
    /// itself — running the model — is the thing being serialized, not
    /// just a data access; actor isolation gives that for free without a
    /// separate lock/unlock dance around a synchronous call.
    private actor InferenceQueue {
        func meanPooledVector(for text: String, model: NLContextualEmbedding) -> [Double]? {
            guard !text.isEmpty else { return nil }
            guard let result = try? model.embeddingResult(for: text, language: nil) else { return nil }
            var sum = [Double](repeating: 0, count: model.dimension)
            var count = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                for i in 0..<min(vector.count, sum.count) { sum[i] += vector[i] }
                count += 1
                return true
            }
            guard count > 0 else { return nil }
            for i in 0..<sum.count { sum[i] /= Double(count) }
            return sum
        }
    }
    private static let inferenceQueue = InferenceQueue()

    // MARK: - Pure math (unit-testable without a loaded model)

    /// Split `text` into pieces each estimated to be at most `maxTokens`
    /// subword tokens: paragraph-tokenize first, then re-split any
    /// paragraph that's still too long by sentence, greedily packing
    /// sentences into a chunk until the estimate would exceed the budget.
    /// Pure and synchronous — no `NLContextualEmbedding` needed — so it's
    /// unit-testable without a resident model.
    static func chunk(_ text: String, maxTokens: Int) -> [String] {
        let paragraphs = tokenize(text, unit: .paragraph)
        guard !paragraphs.isEmpty else { return [] }

        var chunks: [String] = []
        for paragraph in paragraphs {
            let trimmedParagraph = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedParagraph.isEmpty else { continue }
            if approxTokenCount(trimmedParagraph) <= maxTokens {
                chunks.append(trimmedParagraph)
                continue
            }
            let sentences = tokenize(trimmedParagraph, unit: .sentence)
            var current = ""
            var currentTokens = 0
            for sentence in sentences {
                let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedSentence.isEmpty else { continue }
                let sentenceTokens = approxTokenCount(trimmedSentence)
                if !current.isEmpty, currentTokens + sentenceTokens > maxTokens {
                    chunks.append(current)
                    current = trimmedSentence
                    currentTokens = sentenceTokens
                } else {
                    current = current.isEmpty ? trimmedSentence : current + " " + trimmedSentence
                    currentTokens += sentenceTokens
                }
            }
            if !current.isEmpty { chunks.append(current) }
        }
        return chunks
    }

    /// Cheap proxy for subword-token count: whitespace-delimited word
    /// count scaled up, since `NLContextualEmbedding` operates on subword
    /// tokens (typically 1–1.5 per word for Latin-script prose) and
    /// running the real tokenizer just to count would cost as much as
    /// embedding itself. Only needs to be a safe *upper* estimate so
    /// chunks stay comfortably under the model's real limit.
    static func approxTokenCount(_ text: String) -> Int {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        guard words > 0 else { return 0 }
        return Int((Double(words) * 1.4).rounded(.up))
    }

    static func tokenize(_ text: String, unit: NLTokenUnit) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: unit)
        tokenizer.string = text
        var pieces: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            pieces.append(String(text[range]))
            return true
        }
        return pieces
    }

    /// L2-normalize in place. No-op (rather than divide-by-zero) on an
    /// all-zero vector — cosine similarity against a zero vector is
    /// undefined either way, and `EmbeddingIndex.search` treats a
    /// mismatched/degenerate row as a zero-score match, not a crash.
    static func normalizeL2(_ v: inout [Double]) {
        let normSquared = v.reduce(0) { $0 + $1 * $1 }
        guard normSquared > 0 else { return }
        let norm = normSquared.squareRoot()
        for i in 0..<v.count { v[i] /= norm }
    }

    /// Encode as `dims` × Float32, little-endian — the exact layout
    /// `EntryRepository.saveEmbedding` persists and `EmbeddingIndex`
    /// expects to read back.
    static func littleEndianFloat32Data(from v: [Double]) -> Data {
        var data = Data(capacity: v.count * MemoryLayout<Float32>.size)
        for value in v {
            let bits = Float32(value).bitPattern.littleEndian
            withUnsafeBytes(of: bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Inverse of `littleEndianFloat32Data`. Shared with `EmbeddingIndex`
    /// so both sides of the read/write path agree on layout.
    static func float32Array(fromLittleEndianData data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float32>.size
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let bits = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                out[i] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return out
    }
}
