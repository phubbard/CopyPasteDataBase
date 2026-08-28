#if os(macOS)
import Testing
import Foundation
import GRDB
@testable import CpdbApp
@testable import CpdbShared

// MARK: - ClipIntentSupport (pure logic backing the App Intents)

@Suite("ClipIntentSupport — display strings + recent-index lookup")
struct ClipIntentSupportTests {

    private func makeEntry(
        id: Int64 = 1,
        textPreview: String? = nil,
        title: String? = nil,
        aiTitle: String? = nil,
        kind: EntryKind = .text
    ) -> Entry {
        var e = Entry(
            uuid: Data(repeating: 1, count: 16), createdAt: 100, capturedAt: 100,
            kind: kind, sourceDeviceId: 1, title: title, textPreview: textPreview,
            contentHash: Data(repeating: 2, count: 32), totalSize: 10, aiTitle: aiTitle
        )
        e.id = id
        return e
    }

    @Test("prefers aiTitle over everything else")
    func displayTitlePrefersAiTitle() {
        let e = makeEntry(textPreview: "raw text\nmore", title: "stored title", aiTitle: "AI Title")
        #expect(ClipIntentSupport.displayTitle(for: e) == "AI Title")
    }

    @Test("falls back to first line of textPreview when no aiTitle")
    func displayTitleFallsBackToTextPreview() {
        let e = makeEntry(textPreview: "first line\nsecond line", title: "stored title")
        #expect(ClipIntentSupport.displayTitle(for: e) == "first line")
    }

    @Test("falls back to stored title when no preview")
    func displayTitleFallsBackToTitle() {
        let e = makeEntry(title: "stored title")
        #expect(ClipIntentSupport.displayTitle(for: e) == "stored title")
    }

    @Test("falls back to a kind label when nothing else is set")
    func displayTitleFallsBackToKind() {
        let e = makeEntry(kind: .image)
        #expect(ClipIntentSupport.displayTitle(for: e) == "(image)")
    }

    @Test("truncates long titles with an ellipsis")
    func displayTitleTruncatesLongText() {
        let e = makeEntry(aiTitle: String(repeating: "x", count: 100))
        let title = ClipIntentSupport.displayTitle(for: e, maxLength: 20)
        #expect(title.count == 20)
        #expect(title.hasSuffix("…"))
    }

    @Test("entry(atRecentIndex:) is 1-based, 1 = newest")
    func recentIndexIsOneBased() {
        let rows = [1, 2, 3].map { EntryRepository.EntryRow(entry: makeEntry(id: Int64($0))) }
        #expect(ClipIntentSupport.entry(atRecentIndex: 1, in: rows)?.entry.id == 1)
        #expect(ClipIntentSupport.entry(atRecentIndex: 3, in: rows)?.entry.id == 3)
    }

    @Test("entry(atRecentIndex:) rejects out-of-range positions rather than clamping")
    func recentIndexRejectsOutOfRange() {
        let rows = [EntryRepository.EntryRow(entry: makeEntry(id: 1))]
        #expect(ClipIntentSupport.entry(atRecentIndex: 0, in: rows) == nil)
        #expect(ClipIntentSupport.entry(atRecentIndex: 2, in: rows) == nil)
        #expect(ClipIntentSupport.entry(atRecentIndex: 1, in: []) == nil)
    }
}

// MARK: - ClipDeepLink

@Suite("ClipDeepLink — cpdb://clip/<id> parsing")
struct ClipDeepLinkTests {

    @Test("round-trips an entry id through url(forEntryId:) and entryId(from:)")
    func roundTrips() {
        let url = ClipDeepLink.url(forEntryId: 42)
        #expect(url != nil)
        #expect(ClipDeepLink.entryId(from: url!) == 42)
    }

    @Test("rejects a non-cpdb scheme")
    func rejectsWrongScheme() {
        let url = URL(string: "https://clip/42")!
        #expect(ClipDeepLink.entryId(from: url) == nil)
    }

    @Test("rejects a non-clip host")
    func rejectsWrongHost() {
        let url = URL(string: "cpdb://something-else/42")!
        #expect(ClipDeepLink.entryId(from: url) == nil)
    }

    @Test("rejects a non-numeric id")
    func rejectsNonNumericId() {
        let url = URL(string: "cpdb://clip/not-a-number")!
        #expect(ClipDeepLink.entryId(from: url) == nil)
    }
}

// MARK: - SpotlightDonationService payload builder (no CSSearchableIndex involved)

@Suite("SpotlightDonationService — donation payload builder")
struct SpotlightDonationServiceTests {

    private func makeRow(id: Int64, textPreview: String, capturedAt: Double = 1_700_000_000) -> EntryRepository.EntryRow {
        var e = Entry(
            uuid: Data(repeating: 3, count: 16), createdAt: capturedAt, capturedAt: capturedAt,
            kind: .text, sourceDeviceId: 1, textPreview: textPreview,
            contentHash: Data(repeating: 4, count: 32), totalSize: Int64(textPreview.utf8.count)
        )
        e.id = id
        return EntryRepository.EntryRow(entry: e)
    }

    @Test("maps an EntryRow's fields onto the donation payload")
    func buildsPayloadFromRow() {
        let row = makeRow(id: 7, textPreview: "Meeting notes\nmore detail")
        let payload = SpotlightDonationService.payload(for: row)
        #expect(payload?.entryId == 7)
        #expect(payload?.title == "Meeting notes")
        #expect(payload?.contentText == "Meeting notes\nmore detail")
        #expect(payload?.date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(payload?.deepLink == URL(string: "cpdb://clip/7"))
    }

    @Test("returns nil for a row with no persisted id")
    func returnsNilForUnpersistedRow() {
        let e = Entry(
            uuid: Data(repeating: 5, count: 16), createdAt: 1, capturedAt: 1,
            kind: .text, sourceDeviceId: 1, textPreview: "x",
            contentHash: Data(repeating: 6, count: 32), totalSize: 1
        )
        #expect(SpotlightDonationService.payload(for: EntryRepository.EntryRow(entry: e)) == nil)
    }

    @Test("searchableItem(for:) carries the payload's fields into the attribute set")
    func searchableItemCarriesAttributes() {
        let payload = SpotlightDonationPayload(
            entryId: 9, title: "Title", contentText: "Body text",
            date: Date(timeIntervalSince1970: 123), deepLink: URL(string: "cpdb://clip/9")
        )
        let item = SpotlightDonationService.searchableItem(for: payload)
        #expect(item.uniqueIdentifier == "clip-9")
        #expect(item.domainIdentifier == SpotlightDonationService.domainIdentifier)
        #expect(item.attributeSet.title == "Title")
        #expect(item.attributeSet.contentDescription == "Body text")
        #expect(item.attributeSet.contentURL == URL(string: "cpdb://clip/9"))
    }

    @Test("entryId(fromUniqueIdentifier:) recovers the id, and rejects foreign ids")
    func recoversEntryIdFromUniqueIdentifier() {
        #expect(SpotlightDonationService.entryId(fromUniqueIdentifier: "clip-9") == 9)
        #expect(SpotlightDonationService.entryId(fromUniqueIdentifier: "other-9") == nil)
        #expect(SpotlightDonationService.entryId(fromUniqueIdentifier: "clip-not-a-number") == nil)
    }

    @Test("SpotlightPrefs defaults to disabled")
    func prefsDefaultOff() {
        // Exercises the actual key/getter this privacy-critical default
        // gates on — a prior version of this test asserted on an
        // unrelated freshly-generated UserDefaults key instead, which
        // could never fail no matter what `SpotlightPrefs.enabled`
        // defaulted to. Saves and restores whatever was already there
        // (a prior test run, or a real preference on a dev machine
        // sharing this UserDefaults domain) so this is non-destructive.
        let key = SpotlightPrefs.enabledKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(SpotlightPrefs.enabled == false)
    }
}

// MARK: - PopupController App Intents plumbing (query → popup, paste-by-index, deep-link select)

/// Exercises the seam `SearchClipsIntent`/`PasteLatestIntent`/
/// `PasteNthIntent`/`TogglePinLatestIntent`/the Spotlight deep link
/// hand off to, without driving Siri/Shortcuts or a real
/// `CSSearchableIndex`. Serialized: these tests all reconfigure and
/// drive the `PopupController.shared` singleton (owns real AppKit
/// monitors), so they must not interleave with each other.
@Suite("PopupController — App Intents plumbing", .serialized)
@MainActor
struct PopupControllerIntentPlumbingTests {

    private func makeStoreWithRows(count: Int = 3) throws -> Store {
        let store = try Store.inMemory()
        let devId = try store.dbQueue.write { db -> Int64 in
            var d = Device(identifier: "d", name: "D", kind: "mac")
            try d.insert(db)
            return d.id!
        }
        for i in 0..<count {
            // Ascending createdAt so index 1 (newest) is the LAST one
            // inserted, matching `recent()`'s `ORDER BY created_at DESC`.
            let t = Double(1_700_000_000 + i)
            _ = try store.dbQueue.write { db -> Int64 in
                var e = Entry(
                    uuid: Data(repeating: UInt8(i + 1), count: 16), createdAt: t, capturedAt: t,
                    kind: .text, sourceDeviceId: devId, textPreview: "entry \(i)",
                    contentHash: Data(repeating: UInt8(i + 1), count: 32), totalSize: 8
                )
                try e.insert(db)
                return e.id!
            }
        }
        return store
    }

    private func configureFreshController(store: Store) {
        PopupController.shared.configure(store: store, captureMode: .capturing)
    }

    @Test("searchAndShow pre-fills the query, matching a normal summon + type")
    func searchAndShowPrefillsQuery() throws {
        let store = try makeStoreWithRows()
        configureFreshController(store: store)
        PopupController.shared.searchAndShow(query: "entry 1")
        defer { PopupController.shared.hide() }
        #expect(PopupController.shared.state?.query == "entry 1")
    }

    @Test("pasteRecent(atIndex:) resolves index 1 to the newest row")
    func pasteRecentResolvesNewest() throws {
        let store = try makeStoreWithRows()
        configureFreshController(store: store)
        let newestId = try ClipIntentSupport.recentEntries(store: store, limit: 1).first?.entry.id
        #expect(newestId != nil)
        // paste(entryId:) itself synthesises a keystroke, which needs
        // Accessibility permission this test process won't have — we're
        // only verifying the row-resolution half of the plumbing here,
        // which `pasteRecent` shares with `PasteNthIntent`'s validation.
        let rows = try ClipIntentSupport.recentEntries(store: store, limit: 1)
        #expect(ClipIntentSupport.entry(atRecentIndex: 1, in: rows)?.entry.id == newestId)
    }

    @Test("togglePinLatest flips the pin on the newest row")
    func togglePinLatestFlipsNewestRow() throws {
        let store = try makeStoreWithRows()
        configureFreshController(store: store)
        let repo = EntryRepository(store: store)
        let newest = try repo.recent(limit: 1).first!
        #expect(newest.entry.pinned == false)
        PopupController.shared.togglePinLatest()
        let after = try repo.fetch(id: newest.entry.id!)
        #expect(after?.pinned == true)
    }

    @Test("showAndSelect lands selection + bumps scrollToken on the requested entry")
    func showAndSelectLandsOnEntry() throws {
        let store = try makeStoreWithRows()
        configureFreshController(store: store)
        let rows = try EntryRepository(store: store).recent(limit: 10)
        let target = rows[1].entry.id!
        let tokenBefore = PopupController.shared.state?.scrollToken ?? 0
        PopupController.shared.showAndSelect(entryId: target)
        defer { PopupController.shared.hide() }
        #expect(PopupController.shared.state?.selectedEntry?.id == target)
        #expect((PopupController.shared.state?.scrollToken ?? 0) != tokenBefore)
    }

    @Test("showAndSelect resets a stale kind filter that would otherwise hide the target")
    func showAndSelectClearsBlockingKindFilter() throws {
        let store = try makeStoreWithRows()
        configureFreshController(store: store)
        let rows = try EntryRepository(store: store).recent(limit: 10)
        let target = rows[1].entry.id!
        // Every row `makeStoreWithRows` inserts is `.text`; filtering
        // to `.image` only leaves the target unreachable through the
        // normal "current rows" lookup, same shape as a leftover chip
        // selection from the popup's last session.
        PopupController.shared.state?.kindFilter = [.image]
        defer { PopupController.shared.hide() }
        PopupController.shared.showAndSelect(entryId: target)
        #expect(PopupController.shared.state?.selectedEntry?.id == target)
        #expect(PopupController.shared.state?.kindFilter.isEmpty == true)
    }

    @Test("showAndSelect splices in an entry older than the popup's default window")
    func showAndSelectSplicesInAgedOutEntry() throws {
        // One more than PopupState's default `recentLimit` (200), so
        // the oldest row can never appear in an unfiltered `recent`
        // fetch — the donated-corpus-vs-capped-view mismatch a
        // Spotlight click-through hits after enough clips accumulate.
        let store = try makeStoreWithRows(count: 201)
        configureFreshController(store: store)
        let rows = try EntryRepository(store: store).recent(limit: 201, pinnedFirst: false)
        let oldest = rows.last!.entry.id!
        #expect(PopupController.shared.state?.rows.contains { $0.entry.id == oldest } == false)
        defer { PopupController.shared.hide() }
        PopupController.shared.showAndSelect(entryId: oldest)
        #expect(PopupController.shared.state?.selectedEntry?.id == oldest)
    }
}
#endif
