import Testing
import Foundation
import GRDB
@testable import CpdbShared

@Suite("Link backfill retry backoff (v9 schema)")
struct LinkRetryBackoffTests {

    /// Insert a kind=link entry with text_preview = url. Returns id.
    private func insertLink(in store: Store, url: String) throws -> Int64 {
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
                kind: .link,
                sourceDeviceId: devId,
                title: nil,
                textPreview: url,
                contentHash: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                totalSize: Int64(url.utf8.count)
            )
            try entry.insert(db)
            return entry.id!
        }
    }

    private func retryState(_ store: Store, _ id: Int64) throws -> (count: Int, after: Double?) {
        try store.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT link_retry_count, link_retry_after FROM entries WHERE id = ?",
                arguments: [id]
            )!
            return ((row["link_retry_count"] as Int? ?? 0), (row["link_retry_after"] as Double?))
        }
    }

    @Test("Transient failure increments count and schedules backoff")
    func firstFailureScheduledAtOneMinute() throws {
        let store = try Store.inMemory()
        let id = try insertLink(in: store, url: "https://example.com/")
        let repo = EntryRepository(store: store)
        let before = Date().timeIntervalSince1970
        try repo.recordLinkFetchTransientFailure(entryId: id)
        let (count, after) = try retryState(store, id)
        #expect(count == 1)
        #expect(after != nil)
        // Backoff for the FIRST failure (initial count == 0):
        // 60 * (1<<0) = 60 seconds, scheduled from "now". Allow a
        // small slop for test-execution time.
        let delay = (after ?? 0) - before
        #expect(delay >= 59.0 && delay <= 65.0, "expected ~60s delay, got \(delay)s")
    }

    @Test("Successive failures double the backoff")
    func backoffDoubles() throws {
        let store = try Store.inMemory()
        let id = try insertLink(in: store, url: "https://example.com/")
        let repo = EntryRepository(store: store)
        var lastAfter: Double = 0
        // Record 3 transient failures and check each backoff is
        // ~ 2× the previous (modulo execution-time noise).
        for _ in 0..<3 {
            try repo.recordLinkFetchTransientFailure(entryId: id)
            let (_, after) = try retryState(store, id)
            lastAfter = after ?? 0
        }
        // After 3 failures: count = 3, retry_after at attempt-3 was
        // computed from old count=2 → 60 * 4 = 240 seconds.
        let delay = lastAfter - Date().timeIntervalSince1970
        #expect(delay >= 235.0 && delay <= 245.0, "expected ~240s delay after 3 failures, got \(delay)s")
        let (count, _) = try retryState(store, id)
        #expect(count == 3)
    }

    @Test("Backoff caps at 60 minutes")
    func backoffCappedAtSixtyMinutes() throws {
        let store = try Store.inMemory()
        let id = try insertLink(in: store, url: "https://example.com/")
        let repo = EntryRepository(store: store)
        // 7 failures: 1<<6 = 64, capped at 60. The 7th call is
        // computed with old count=6 → MIN(60, 64) = 60 → 3600s.
        for _ in 0..<7 {
            try repo.recordLinkFetchTransientFailure(entryId: id)
        }
        let (_, after) = try retryState(store, id)
        let delay = (after ?? 0) - Date().timeIntervalSince1970
        #expect(delay >= 3590.0 && delay <= 3610.0, "expected ~3600s cap, got \(delay)s")
    }

    @Test("setLinkMetadata clears retry state")
    func successResetsRetryState() throws {
        let store = try Store.inMemory()
        let id = try insertLink(in: store, url: "https://example.com/")
        let repo = EntryRepository(store: store)
        // Burn a couple of failures.
        try repo.recordLinkFetchTransientFailure(entryId: id)
        try repo.recordLinkFetchTransientFailure(entryId: id)
        let (countBefore, _) = try retryState(store, id)
        #expect(countBefore == 2)
        // A successful fetch should clear count and after.
        try repo.setLinkMetadata(entryId: id, title: "An Example Page")
        let (countAfter, retryAfter) = try retryState(store, id)
        #expect(countAfter == 0)
        #expect(retryAfter == nil)
    }

    @Test("linksNeedingMetadata respects retry_after gate")
    func queueRespectsBackoff() throws {
        let store = try Store.inMemory()
        let id = try insertLink(in: store, url: "https://example.com/")
        let repo = EntryRepository(store: store)
        // No failure yet — row should be a candidate.
        var candidates = try repo.linksNeedingMetadata()
        #expect(candidates.contains(where: { $0.entryId == id }))
        // First failure schedules retry_after ~60s in future →
        // row drops out of the queue.
        try repo.recordLinkFetchTransientFailure(entryId: id)
        candidates = try repo.linksNeedingMetadata()
        #expect(!candidates.contains(where: { $0.entryId == id }))
    }

    @Test("linksNeedingMetadata caps at maxRetries")
    func queueCapsAtMaxRetries() throws {
        let store = try Store.inMemory()
        let id = try insertLink(in: store, url: "https://example.com/")
        let repo = EntryRepository(store: store)
        // Burn through max attempts and force the retry_after into
        // the past so it's the cap (not the schedule) that excludes
        // the row.
        for _ in 0..<EntryRepository.linkBackfillMaxRetries {
            try repo.recordLinkFetchTransientFailure(entryId: id)
        }
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE entries SET link_retry_after = 0 WHERE id = ?", arguments: [id])
        }
        let candidates = try repo.linksNeedingMetadata()
        #expect(!candidates.contains(where: { $0.entryId == id }))
    }
}
