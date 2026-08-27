import Testing
import Foundation
import GRDB
#if os(macOS)
import FoundationModels
#endif
@testable import CpdbShared

/// Tests for the on-device AI title/summary pipeline:
/// `AIService`'s pure budgeting math and availability mapping,
/// `EntryRepository`'s candidate-selection queries + persistence, and
/// `AIEnrichmentSweeper`'s preference gate.
///
/// Model-dependent generation itself (`AIService.generateTitleAndSummary`
/// actually calling into `LanguageModelSession`) is NOT unit-tested here —
/// see the manual-run integration test at the bottom of this file, gated
/// on `AIService.availability == .available` so it only ever runs on a
/// machine that can actually do the generation.
@Suite("AI enrichment")
struct AIEnrichmentTests {

    // MARK: - Budgeting math

    @Test("heuristicCharBudget applies the chars/4 heuristic to the remaining token budget")
    func heuristicCharBudgetMath() {
        // (4096 - 700) tokens remaining * 4 chars/token.
        #expect(AIService.heuristicCharBudget(reservedTokens: 700, contextWindowTokens: 4096) == 13_584)
        // Reserved >= window clamps to zero rather than going negative.
        #expect(AIService.heuristicCharBudget(reservedTokens: 5000, contextWindowTokens: 4096) == 0)
    }

    @Test("truncated leaves short text untouched")
    func truncatedLeavesShortTextAlone() {
        let text = "hello world"
        #expect(AIService.truncated(text, toCharBudget: 100) == text)
    }

    @Test("truncated clips to exactly the char budget")
    func truncatedClipsToExactBudget() {
        let text = String(repeating: "a", count: 200)
        let clipped = AIService.truncated(text, toCharBudget: 50)
        #expect(clipped.count == 50)
        #expect(clipped == String(repeating: "a", count: 50))
    }

    @Test("truncated returns empty string for a non-positive budget")
    func truncatedHandlesZeroBudget() {
        #expect(AIService.truncated("anything", toCharBudget: 0) == "")
        #expect(AIService.truncated("anything", toCharBudget: -5) == "")
    }

    // MARK: - Facade availability mapping (injected `SystemLanguageModel.Availability`)

    #if os(macOS)
    @available(macOS 26.0, *)
    @Test("Maps .available straight through")
    func mapsAvailable() {
        #expect(AIService.map(.available) == .available)
    }

    @available(macOS 26.0, *)
    @Test("Maps every .unavailable reason to a non-empty .notEnabled message")
    func mapsUnavailableReasons() {
        let reasons: [SystemLanguageModel.Availability.UnavailableReason] = [
            .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady,
        ]
        for reason in reasons {
            guard case .notEnabled(let message) = AIService.map(.unavailable(reason)) else {
                Issue.record("expected .notEnabled for \(reason)")
                continue
            }
            #expect(!message.isEmpty)
        }
    }
    #endif

    // MARK: - EntryRepository candidate query

    @discardableResult
    private func insertTextEntry(
        _ store: Store,
        createdAt: Double = 1000,
        textPreview: String?,
        kind: EntryKind = .text,
        deleted: Bool = false,
        aiTitle: String? = nil
    ) throws -> Int64 {
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
                createdAt: createdAt,
                capturedAt: createdAt,
                kind: kind,
                sourceDeviceId: devId,
                textPreview: textPreview,
                contentHash: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                totalSize: Int64(textPreview?.utf8.count ?? 0),
                deletedAt: deleted ? createdAt : nil,
                aiTitle: aiTitle
            )
            try entry.insert(db)
            return entry.id!
        }
    }

    private let longText = String(repeating: "word ", count: 200)   // well over 500 chars
    private let shortText = "too short to bother summarizing"

    @Test("Picks unenriched long text entries newest-first")
    func candidatesNewestFirst() throws {
        let store = try Store.inMemory()
        let older = try insertTextEntry(store, createdAt: 100, textPreview: longText)
        let newer = try insertTextEntry(store, createdAt: 200, textPreview: longText)
        let repo = EntryRepository(store: store)
        let candidates = try repo.entriesNeedingAIEnrichment(limit: 10, minLength: AIService.longTextThreshold)
        #expect(candidates.map(\.entryId) == [newer, older])
    }

    @Test("Respects the limit cap")
    func candidatesRespectLimit() throws {
        let store = try Store.inMemory()
        for i in 0..<5 { _ = try insertTextEntry(store, createdAt: Double(i), textPreview: longText) }
        let repo = EntryRepository(store: store)
        let candidates = try repo.entriesNeedingAIEnrichment(limit: 2, minLength: AIService.longTextThreshold)
        #expect(candidates.count == 2)
    }

    @Test("Skips deleted, non-text, too-short, and already-enriched entries")
    func candidatesSkipIneligible() throws {
        let store = try Store.inMemory()
        let live = try insertTextEntry(store, createdAt: 500, textPreview: longText)
        _ = try insertTextEntry(store, createdAt: 400, textPreview: longText, deleted: true)
        _ = try insertTextEntry(store, createdAt: 300, textPreview: longText, kind: .link)
        _ = try insertTextEntry(store, createdAt: 200, textPreview: shortText)
        _ = try insertTextEntry(store, createdAt: 100, textPreview: longText, aiTitle: "Already enriched")
        let repo = EntryRepository(store: store)
        let candidates = try repo.entriesNeedingAIEnrichment(limit: 10, minLength: AIService.longTextThreshold)
        #expect(candidates.map(\.entryId) == [live])
    }

    @Test("isAIUnenriched reflects the current sentinel, for the sweeper's re-check")
    func isAIUnenrichedReflectsSentinel() throws {
        let store = try Store.inMemory()
        let id = try insertTextEntry(store, textPreview: longText)
        let repo = EntryRepository(store: store)
        #expect(try repo.isAIUnenriched(entryId: id) == true)
        // Simulate a sibling Mac's result (or this Mac's capture-time
        // hook) landing between candidate-list build and per-entry work.
        try repo.setAITitleSummary(entryId: id, title: "T", summary: "S")
        #expect(try repo.isAIUnenriched(entryId: id) == false)
    }

    @Test("isAIUnenriched returns false for a missing/tombstoned entry")
    func isAIUnenrichedFalseForMissing() throws {
        let store = try Store.inMemory()
        let repo = EntryRepository(store: store)
        #expect(try repo.isAIUnenriched(entryId: 999_999) == false)
    }

    // MARK: - Persistence round-trip

    @Test("setAITitleSummary round-trips through EntryRepository and enqueues a push")
    func setAITitleSummaryRoundTrips() throws {
        let store = try Store.inMemory()
        let id = try insertTextEntry(store, textPreview: longText)
        let repo = EntryRepository(store: store)
        try repo.setAITitleSummary(entryId: id, title: "A tidy title", summary: "A tidy summary.")
        let entry = try store.dbQueue.read { db in try Entry.fetchOne(db, key: id) }
        #expect(entry?.aiTitle == "A tidy title")
        #expect(entry?.aiSummary == "A tidy summary.")
        let queued = try store.dbQueue.read { db in try PushQueue.count(in: db) }
        #expect(queued == 1)
    }

    @Test("setAITitleSummary is a no-op for a deleted entry")
    func setAITitleSummarySkipsDeleted() throws {
        let store = try Store.inMemory()
        let id = try insertTextEntry(store, textPreview: longText, deleted: true)
        let repo = EntryRepository(store: store)
        try repo.setAITitleSummary(entryId: id, title: "T", summary: "S")
        let entry = try store.dbQueue.read { db in try Entry.fetchOne(db, key: id) }
        #expect(entry?.aiTitle == nil)
    }

    // MARK: - AIEnrichmentSweeper preference gate

    @Test("runOnce is a no-op when the AI-enrichment preference is off, even with eligible candidates")
    func runOnceSkipsWhenDisabled() async throws {
        let store = try Store.inMemory()
        _ = try insertTextEntry(store, textPreview: longText)
        let key = AIEnrichmentPrefs.enabledKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let sweeper = AIEnrichmentSweeper(repository: EntryRepository(store: store))
        let report = try await sweeper.runOnce(limit: 10)
        #expect(report == AIEnrichmentSweeper.Report())
    }

    // MARK: - Manual-run integration test (real, tiny, on-device generation)

    /// Actually calls into Foundation Models — only runs on a machine
    /// where `AIService.availability == .available` (Apple-Intelligence-
    /// enabled Mac, macOS 26+). Everywhere else this is skipped rather
    /// than failing, since availability depends on hardware/System
    /// Settings state the test suite doesn't control.
    @Test(
        "Real generation produces a non-empty, length-capped title and summary",
        .enabled(if: AIService.availability == .available)
    )
    func realGenerationProducesUsableResult() async throws {
        let text = """
            The quick brown fox jumps over the lazy dog. This sentence is a \
            classic pangram used to test typefaces and keyboards because it \
            contains every letter of the English alphabet at least once. It \
            has been used since at least the late 19th century by printers \
            and typists, and today it still shows up in font specimens, \
            typing tutorials, and the occasional unit test that needs a \
            harmless block of plausible-looking prose that's over five \
            hundred characters long so it clears the auto-enrichment \
            threshold this test is exercising.
            """
        #expect(text.count > AIService.longTextThreshold)
        let result = try #require(await AIService.generateTitleAndSummary(for: text))
        #expect(!result.title.isEmpty)
        #expect(!result.summary.isEmpty)
        #expect(result.title.count <= 60)
        #expect(result.summary.count <= 200)
    }
}
