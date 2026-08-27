import Foundation
#if os(macOS)
import FoundationModels
#endif

/// Cross-platform outcome of "can Foundation Models generate something
/// right now". Deliberately independent of `FoundationModels` itself
/// (which isn't importable outside `#if os(macOS)`) so callers compiled
/// for iOS — `Ingestor`'s capture-time hook, chiefly — can branch on this
/// without their own `#if os(macOS)` / `#available` guards.
public enum AIAvailability: Sendable, Equatable {
    /// Generation can run right now.
    case available
    /// Foundation Models exists on this OS but isn't usable yet — no
    /// Apple Intelligence on this Mac, the user hasn't turned it on, or
    /// the on-device model is still downloading. `reason` is a short,
    /// user-facing sentence (Preferences shows it verbatim as status
    /// text in place of the toggle).
    case notEnabled(String)
    /// This process is on a platform/OS version that doesn't ship
    /// Foundation Models at all (macOS < 26, or any non-macOS platform —
    /// this facade is macOS-only per the stream brief).
    case unsupportedOS
}

/// Facade over Apple's on-device Foundation Models framework. Every
/// generation happens locally via `SystemLanguageModel` — this type never
/// makes a network call, and never will (that's the whole point of
/// "on-device").
///
/// macOS only, macOS 26+ only. Everything below that reports
/// `.unsupportedOS` uniformly through `availability` — see
/// `CloudKitEntitlementPreflight` for the same "report a safe enum value
/// instead of failing to compile on other platforms" convention this
/// mirrors. Two callers:
///   1. `AIEnrichmentSweeper` — periodic + capture-wake batch backfill,
///      mirroring `ImageAnalysisSweeper`'s architecture.
///   2. `Ingestor.ingest(...)` — a capture-time `Task.detached`, exactly
///      like the image-analysis kickoff a few lines above it there.
public enum AIService {
    /// A text clip shorter than this (chars, matching `Entry.textPreview`)
    /// isn't worth summarizing — a short clip's headline already IS its
    /// content. Shared by the capture-time hook and the sweeper's
    /// candidate query so both apply the identical bar.
    public static let longTextThreshold = 500

    /// Foundation Models' context window, in tokens. `SystemLanguageModel
    /// .contextSize` reports the same constant at runtime (backdeployed to
    /// 26.0), but we need this before ever touching the framework — e.g.
    /// to size the heuristic char budget below without an `#available`
    /// dance at every call site.
    public static let contextWindowTokens = 4096

    /// Tokens reserved for the fixed instructions + schema + the
    /// generated title/summary themselves, leaving the remainder of the
    /// context window for the input text. Generous on purpose: system
    /// prompt + schema overhead for a two-field `@Generable` struct is
    /// small, but a bad estimate here just means slightly-early
    /// truncation, never a context-window overflow.
    public static let reservedTokens = 700

    /// Whether generation can run right now. Version-agnostic: safe to
    /// call from any platform/OS version, no `#available` needed at the
    /// call site.
    public static var availability: AIAvailability {
        #if os(macOS)
        guard #available(macOS 26.0, *) else { return .unsupportedOS }
        return map(SystemLanguageModel.default.availability)
        #else
        return .unsupportedOS
        #endif
    }

    // MARK: - Budgeting (pure, testable without touching FoundationModels)

    /// Cheap chars/4 heuristic for how much input text fits alongside
    /// `reservedTokens` in a `contextWindowTokens`-token window. This is
    /// the ONLY budgeting available before macOS 26.4 (`tokenCount(for:)`
    /// ships in 26.4); `generateTitleAndSummary` also uses it as the
    /// first pass on 26.4+ before refining with a real token count, since
    /// asking the model to count tokens on already-reasonably-sized text
    /// is pure overhead in the common case.
    public static func heuristicCharBudget(
        reservedTokens: Int = AIService.reservedTokens,
        contextWindowTokens: Int = AIService.contextWindowTokens
    ) -> Int {
        max(contextWindowTokens - reservedTokens, 0) * 4
    }

    /// Truncate `text` to at most `budgetChars` characters. Character
    /// truncation (not word-boundary trimming) is deliberate: this feeds
    /// a summarizer, not a display string — a clipped final word costs
    /// nothing there, and keeping it simple keeps it exactly predictable
    /// for the token-aware second pass in `generateTitleAndSummary` to
    /// shrink further if needed.
    public static func truncated(_ text: String, toCharBudget budgetChars: Int) -> String {
        guard budgetChars > 0 else { return "" }
        guard text.count > budgetChars else { return text }
        return String(text.prefix(budgetChars))
    }

    #if os(macOS)
    /// Pure mapping, pulled out of `availability` so it's unit-testable
    /// by constructing `SystemLanguageModel.Availability` values directly
    /// rather than depending on this Mac's actual Apple Intelligence
    /// state (which the test suite can't control).
    @available(macOS 26.0, *)
    static func map(_ raw: SystemLanguageModel.Availability) -> AIAvailability {
        switch raw {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .notEnabled("This Mac doesn't support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .notEnabled("Turn on Apple Intelligence in System Settings to enable AI enrichment.")
            case .modelNotReady:
                return .notEnabled("The on-device model is still downloading.")
            @unknown default:
                return .notEnabled("The on-device model isn't available right now.")
            }
        }
    }

    /// Structured output for one generation call. `@Guide` descriptions
    /// carry the length caps as instructions to the model; `generateTitleAndSummary`
    /// still hard-truncates the result afterward (belt-and-braces — the
    /// model follows guidance closely but isn't a validator).
    @available(macOS 26.0, *)
    @Generable
    struct EntrySummary: Sendable {
        @Guide(description: "A short, specific title for this text, at most 60 characters. No surrounding quotes.")
        var title: String
        @Guide(description: "A concise 1-3 sentence summary of the text, at most 200 characters.")
        var summary: String
    }
    #endif

    /// Run one generation for `text`, returning `nil` on any failure
    /// (unavailable model, generation error, empty result) rather than
    /// throwing — callers (the sweeper, the capture-time hook) treat
    /// "no result this pass" as routine and retry later rather than
    /// something to propagate.
    public static func generateTitleAndSummary(for text: String) async -> (title: String, summary: String)? {
        #if os(macOS)
        guard #available(macOS 26.0, *) else { return nil }
        return await generateTitleAndSummaryOnDevice(text: text)
        #else
        return nil
        #endif
    }

    #if os(macOS)
    @available(macOS 26.0, *)
    private static func generateTitleAndSummaryOnDevice(text: String) async -> (title: String, summary: String)? {
        var input = truncated(text, toCharBudget: heuristicCharBudget())

        // Refine with a real token count where available (26.4+). The
        // heuristic above is deliberately generous (~4 chars/token is a
        // rough average for English prose); this second pass catches
        // text that heuristic undercounts — dense punctuation, non-Latin
        // scripts — before it overflows the context window mid-generation.
        if #available(macOS 26.4, *) {
            let budget = contextWindowTokens - reservedTokens
            if let count = try? await SystemLanguageModel.default.tokenCount(for: input), count > budget, count > 0 {
                let ratio = Double(budget) / Double(count)
                let shrunkLength = max(Int(Double(input.count) * ratio) - 32, 0)
                input = String(input.prefix(shrunkLength))
            }
        }
        guard !input.isEmpty else { return nil }

        let session = LanguageModelSession(
            instructions: """
                You write short, accurate titles and summaries for clipboard text \
                snippets. Base the title and summary only on the text given — never \
                invent details that aren't present in it.
                """
        )
        do {
            let response = try await session.respond(
                to: "Summarize this text:\n\n\(input)",
                generating: EntrySummary.self
            )
            let title = String(response.content.title.prefix(60))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = String(response.content.summary.prefix(200))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !summary.isEmpty else { return nil }
            return (title, summary)
        } catch {
            Log.capture.error(
                "AIService: generation failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }
    #endif

    // MARK: - Persistence glue (shared by the sweeper and the capture hook)

    /// Generate + persist title/summary for one entry. Returns whether it
    /// wrote a result, purely so callers can tally a report — failures of
    /// every kind (unavailable, generation, persistence) are logged here
    /// or in the callee and never thrown; an entry that fails just stays
    /// `ai_title IS NULL` and is retried on the next sweep pass.
    @discardableResult
    public static func enrichEntry(entryId: Int64, text: String, repository: EntryRepository) async -> Bool {
        guard availability == .available else { return false }
        guard text.count > longTextThreshold else { return false }
        guard let (title, summary) = await generateTitleAndSummary(for: text) else { return false }
        do {
            try repository.setAITitleSummary(entryId: entryId, title: title, summary: summary)
            return true
        } catch {
            Log.capture.error(
                "AIService: failed to persist title/summary for entry \(entryId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// Capture-time enrichment kickoff — the ONE line `Ingestor.ingest`
    /// calls after a fresh `.inserted` outcome, mirroring the image-
    /// analysis `Task.detached` a few lines above that call site. No-ops
    /// (synchronously, before ever spawning a Task) for non-text kinds,
    /// short text, a disabled preference, or an unavailable model — so
    /// the call is always safe to make unconditionally.
    ///
    /// `textPreview` is capped to 2048 chars to match `Entry.textPreview`
    /// exactly (the column this reads back from on later sweep passes),
    /// so capture-time and sweep-time enrichment always see the same
    /// input for a given entry.
    public static func enrichAtCaptureIfEligible(
        entryId: Int64,
        kind: EntryKind,
        textPreview: String?,
        store: Store
    ) {
        guard kind == .text, let raw = textPreview else { return }
        let text = String(raw.prefix(2048))
        guard text.count > longTextThreshold else { return }
        guard AIEnrichmentPrefs.load().enabled else { return }
        guard availability == .available else { return }
        let repository = EntryRepository(store: store)
        Task.detached(priority: .utility) {
            await enrichEntry(entryId: entryId, text: text, repository: repository)
        }
    }
}
