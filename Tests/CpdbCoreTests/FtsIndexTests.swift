import Testing
import Foundation
import GRDB
@testable import CpdbCore
@testable import CpdbShared

@Suite("FTS index")
struct FtsIndexTests {

    /// Inserts an entry and indexes it into FTS5 with the given text in the
    /// `text` column. Returns the entry id for assertions.
    @discardableResult
    private func seed(
        store: Store,
        title: String? = nil,
        text: String? = nil,
        ocr: String? = nil,
        tags: String? = nil,
        appName: String? = nil,
        note: String? = nil
    ) throws -> Int64 {
        try store.dbQueue.write { db in
            var device = Device(identifier: "TEST", name: "Test", kind: "mac")
            try device.insert(db, onConflict: .ignore)
            let deviceId: Int64
            if let id = device.id {
                deviceId = id
            } else {
                deviceId = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM devices WHERE identifier = 'TEST'"
                ) ?? 0
            }
            var uuid = UUID().uuid
            let uuidData = withUnsafeBytes(of: &uuid) { Data($0) }
            var entry = Entry(
                uuid: uuidData,
                createdAt: 1_000_000,
                capturedAt: 1_000_000,
                kind: .text,
                sourceDeviceId: deviceId,
                title: title,
                textPreview: text,
                contentHash: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                totalSize: 0
            )
            try entry.insert(db)
            try FtsIndex.indexEntry(
                db: db,
                entryId: entry.id!,
                title: title,
                text: text,
                appName: appName,
                ocrText: ocr,
                imageTags: tags,
                note: note
            )
            return entry.id!
        }
    }

    @Test("prefix match: typing a shortening of a word still matches")
    func prefixMatchShortening() throws {
        // Live-search regression: `tgncha` should match entries containing
        // `tgnchat` — typing ever-shorter prefixes must not make a hit
        // disappear and reappear when the user adds a letter.
        //
        // We deliberately don't also assert on e.g. `tgnchats` because
        // FTS5's Porter stemmer strips trailing `s` (plural rule) from
        // both index and query, so `tgnchats` *does* collapse to match
        // `tgnchat`. That's expected stemming behaviour, not a bug here.
        let store = try Store.inMemory()
        let id = try seed(store: store, text: "meeting notes tgnchat follow-up")

        try store.dbQueue.read { db in
            let shortHits = try FtsIndex.search(db: db, query: "tgncha")
            #expect(shortHits.contains { $0.entryId == id },
                    "expected prefix 'tgncha' to match 'tgnchat'")

            let longerHits = try FtsIndex.search(db: db, query: "tgnchat")
            #expect(longerHits.contains { $0.entryId == id })
        }
    }

    @Test("multi-token prefix match: every typed token gets prefix treatment")
    func multiTokenPrefix() throws {
        let store = try Store.inMemory()
        let id = try seed(store: store, text: "github actions workflow")

        try store.dbQueue.read { db in
            let hits = try FtsIndex.search(db: db, query: "git work")
            #expect(hits.contains { $0.entryId == id },
                    "expected 'git work' to prefix-match 'github workflow'")
        }
    }

    @Test("scope filter: OCR off means OCR-only hits don't surface")
    func scopeFilterDropsOcr() throws {
        let store = try Store.inMemory()
        let id = try seed(
            store: store,
            text: "",
            ocr: "unique-ocr-token-xyz"
        )

        try store.dbQueue.read { db in
            // Default scope includes OCR → hit
            let withOcr = try FtsIndex.search(
                db: db,
                query: "unique-ocr-token-xyz",
                scope: .all
            )
            #expect(withOcr.contains { $0.entryId == id })

            // OCR disabled → no hit
            let withoutOcr = try FtsIndex.search(
                db: db,
                query: "unique-ocr-token-xyz",
                scope: .init(text: true, ocr: false, tags: true)
            )
            #expect(!withoutOcr.contains { $0.entryId == id })
        }
    }

    @Test("match source: OCR-only hit attributes to .ocr")
    func matchSourceOcr() throws {
        let store = try Store.inMemory()
        let id = try seed(store: store, ocr: "distinctivewordabc")
        try store.dbQueue.read { db in
            let hits = try FtsIndex.search(db: db, query: "distinctivewordabc")
            let hit = try #require(hits.first { $0.entryId == id })
            #expect(hit.source == .ocr)
        }
    }

    @Test("match source: tags-only hit attributes to .tag")
    func matchSourceTag() throws {
        let store = try Store.inMemory()
        let id = try seed(store: store, tags: "anomaloustaglabel")
        try store.dbQueue.read { db in
            let hits = try FtsIndex.search(db: db, query: "anomaloustaglabel")
            let hit = try #require(hits.first { $0.entryId == id })
            #expect(hit.source == .tag)
        }
    }

    @Test("match source: note-only hit attributes to .note")
    func matchSourceNote() throws {
        let store = try Store.inMemory()
        let id = try seed(store: store, text: "unrelated body", note: "peculiarannotationword")
        try store.dbQueue.read { db in
            let hits = try FtsIndex.search(db: db, query: "peculiarannotationword")
            let hit = try #require(hits.first { $0.entryId == id })
            #expect(hit.source == .note)
        }
    }

    @Test("match source: a query hitting the note and another column attributes to .multiple")
    func matchSourceNoteAndText() throws {
        let store = try Store.inMemory()
        let id = try seed(store: store, text: "shared term in the body", note: "shared term in the note")
        try store.dbQueue.read { db in
            let hit = try #require(try FtsIndex.search(db: db, query: "shared").first { $0.entryId == id })
            #expect(hit.source == .multiple)
        }
    }

    @Test("scope filter: the content-column toggles never hide a note")
    func scopeFilterKeepsNote() throws {
        let store = try Store.inMemory()
        let id = try seed(store: store, note: "uniquenotetoken")
        try store.dbQueue.read { db in
            let narrowest = try FtsIndex.search(
                db: db, query: "uniquenotetoken", scope: .init(text: false, ocr: false, tags: true))
            #expect(narrowest.contains { $0.entryId == id })
        }
    }

    @Test("all three scope toggles off is the search-nothing state for every column, the note included")
    func scopeAllOffFindsNothing() throws {
        let store = try Store.inMemory()
        _ = try seed(store: store, title: "headlineword", note: "uniquenotetoken")
        try store.dbQueue.read { db in
            let off = FtsIndex.SearchScope(text: false, ocr: false, tags: false)
            let byNote = try FtsIndex.search(db: db, query: "uniquenotetoken", scope: off)
            let byTitle = try FtsIndex.search(db: db, query: "headlineword", scope: off)
            #expect(byNote.isEmpty)
            #expect(byTitle.isEmpty)
        }
    }

    @Test("a note-less row is unaffected by the note column (no phantom .note attribution)")
    func noteAbsentDoesNotChangeAttribution() throws {
        let store = try Store.inMemory()
        let id = try seed(store: store, text: "plainly textual", ocr: nil)
        try store.dbQueue.read { db in
            let hit = try #require(try FtsIndex.search(db: db, query: "textual").first { $0.entryId == id })
            #expect(hit.source == .text)
        }
    }

    @Test("escapeForFts5: every token gets quoted and suffixed with *")
    func escapeShape() {
        #expect(FtsIndex.escapeForFts5("foo") == "\"foo\"*")
        #expect(FtsIndex.escapeForFts5("foo bar") == "\"foo\"* \"bar\"*")
        #expect(FtsIndex.escapeForFts5("") == "\"\"")
        // Internal double-quotes get doubled per FTS5 escaping rules.
        #expect(FtsIndex.escapeForFts5("a\"b") == "\"a\"\"b\"*")
    }
}
