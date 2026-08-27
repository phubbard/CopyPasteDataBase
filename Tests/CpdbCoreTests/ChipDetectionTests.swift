import Testing
import Foundation
import GRDB
@testable import CpdbShared

/// Coverage for the QR ingest + data-detector chip pipeline:
/// `Chip` encode/decode/merge, `QRChipMapper` payload mapping,
/// `TrackingCarrier`'s pattern table, and `TextChipDetector`'s
/// `NSDataDetector`-backed mapping plus its pre-macOS-26 regex
/// tracking-number fallback.
@Suite("Chip detection + mapping")
struct ChipDetectionTests {

    // MARK: - Chip encode/decode/merge

    @Test("decodeArray returns [] for nil, empty, and malformed JSON")
    func decodeArrayHandlesBadInput() {
        #expect(Chip.decodeArray(nil) == [])
        #expect(Chip.decodeArray("") == [])
        #expect(Chip.decodeArray("not json") == [])
        #expect(Chip.decodeArray("[]") == [])
    }

    @Test("encodeArray then decodeArray round-trips")
    func encodeDecodeRoundTrips() {
        let chips = [
            Chip(t: ChipType.url, v: "https://example.com", s: "example.com"),
            Chip(t: ChipType.phone, v: "555-1234", s: "555-1234"),
        ]
        let json = Chip.encodeArray(chips)
        #expect(Chip.decodeArray(json) == chips)
    }

    @Test("merge appends new chips onto nil existing json")
    func mergeFromNil() {
        let chips = [Chip(t: ChipType.url, v: "https://a.com", s: "a.com")]
        let json = Chip.merge(existingJson: nil, adding: chips)
        #expect(Chip.decodeArray(json) == chips)
    }

    @Test("merge with no new chips against nil produces an explicit empty array, not null")
    func mergeEmptyProducesEmptyArrayLiteral() {
        let json = Chip.merge(existingJson: nil, adding: [])
        #expect(json == "[]")
    }

    @Test("merge de-duplicates on (t, v) and preserves existing order, appending only new ones")
    func mergeDedupesAndPreservesOrder() {
        let existing = Chip.encodeArray([
            Chip(t: ChipType.url, v: "https://a.com", s: "a.com"),
            Chip(t: ChipType.phone, v: "555-1234", s: "555-1234"),
        ])
        let incoming = [
            Chip(t: ChipType.url, v: "https://a.com", s: "a.com (dup)"),  // duplicate (t,v) — dropped
            Chip(t: ChipType.tracking, v: "1Z999AA10123456784", s: "UPS 1Z999AA10123456784"),
        ]
        let merged = Chip.decodeArray(Chip.merge(existingJson: existing, adding: incoming))
        #expect(merged.count == 3)
        #expect(merged[0].v == "https://a.com")
        #expect(merged[0].s == "a.com")  // original survives, not the "dup" incoming variant
        #expect(merged[1].v == "555-1234")
        #expect(merged[2].t == ChipType.tracking)
    }

    // MARK: - QRChipMapper

    @Test("QR payload that is a bare http(s) URL becomes a url chip")
    func qrHttpURLBecomesURLChip() {
        let chips = QRChipMapper.chips(from: ["https://example.com/promo"])
        #expect(chips.count == 1)
        #expect(chips[0].t == ChipType.url)
        #expect(chips[0].v == "https://example.com/promo")
        #expect(chips[0].s == "example.com")
    }

    @Test("QR payload with a tel: scheme becomes a phone chip with the scheme stripped")
    func qrTelSchemeBecomesPhoneChip() {
        let chips = QRChipMapper.chips(from: ["tel:+14155551234"])
        #expect(chips.count == 1)
        #expect(chips[0].t == ChipType.phone)
        #expect(chips[0].v == "+14155551234")
    }

    @Test("QR payload with another real scheme (mailto:) still becomes a url chip")
    func qrOtherSchemeBecomesURLChip() {
        let chips = QRChipMapper.chips(from: ["mailto:hello@example.com"])
        #expect(chips.count == 1)
        #expect(chips[0].t == ChipType.url)
        #expect(chips[0].v == "mailto:hello@example.com")
    }

    @Test("A WIFI-config-style QR payload also becomes a url chip (Foundation parses its leading token as a URL scheme)")
    func qrWifiConfigPayloadBecomesURLChip() {
        let chips = QRChipMapper.chips(from: ["WIFI:S:MyNetwork;T:WPA;P:hunter2;;"])
        #expect(chips.count == 1)
        #expect(chips[0].t == ChipType.url)
    }

    @Test("QR payload that merely looks like a bare phone number becomes a phone chip")
    func qrBarePhoneNumberBecomesPhoneChip() {
        let chips = QRChipMapper.chips(from: ["(415) 555-1234"])
        #expect(chips.count == 1)
        #expect(chips[0].t == ChipType.phone)
    }

    @Test("QR payload that is neither URL- nor phone-shaped becomes a generic text chip")
    func qrGenericPayloadBecomesTextChip() {
        let chips = QRChipMapper.chips(from: ["Employee Badge #4471"])
        #expect(chips.count == 1)
        #expect(chips[0].t == ChipType.text)
        #expect(chips[0].v == "Employee Badge #4471")
    }

    @Test("QR text chip display truncates long payloads")
    func qrTextChipTruncatesDisplay() {
        let long = String(repeating: "x", count: 100)
        let chips = QRChipMapper.chips(from: [long])
        #expect(chips[0].v == long)  // raw value is untouched
        #expect(chips[0].s.count < long.count)
        #expect(chips[0].s.hasSuffix("\u{2026}"))
    }

    @Test("QRChipMapper drops duplicate and blank payloads")
    func qrChipsDropsDuplicatesAndBlanks() {
        let chips = QRChipMapper.chips(from: ["https://a.com", "https://a.com", "  ", ""])
        #expect(chips.count == 1)
    }

    // MARK: - TrackingCarrier pattern table

    @Test("TrackingCarrier detects UPS, USPS, and FedEx shapes")
    func trackingCarrierDetectsKnownShapes() {
        #expect(TrackingCarrier.detect("1Z999AA10123456784") == .ups)
        #expect(TrackingCarrier.detect("9400111899223197428490") == .usps)
        #expect(TrackingCarrier.detect("123456789012") == .fedex)
    }

    @Test("TrackingCarrier.detect returns nil for an unrecognizable string")
    func trackingCarrierDetectsNothingForJunk() {
        #expect(TrackingCarrier.detect("not-a-tracking-number") == nil)
    }

    @Test("TrackingCarrier.trackingURL builds the right template per carrier, and falls back to search")
    func trackingCarrierBuildsExpectedURLs() {
        let ups = TrackingCarrier.trackingURL(for: "1Z999AA10123456784")
        #expect(ups.absoluteString.contains("ups.com"))
        let usps = TrackingCarrier.trackingURL(for: "9400111899223197428490")
        #expect(usps.absoluteString.contains("usps.com"))
        let fedex = TrackingCarrier.trackingURL(for: "123456789012")
        #expect(fedex.absoluteString.contains("fedex.com"))
        let unknown = TrackingCarrier.trackingURL(for: "junk-value")
        #expect(unknown.absoluteString.contains("google.com/search"))
    }

    // MARK: - TextChipDetector: NSDataDetector mapping

    @Test("classicChips detects a link in plain text")
    func classicChipsDetectsLink() {
        let chips = TextChipDetector.classicChips(in: "Check out https://example.com/path for details")
        #expect(chips.contains { $0.t == ChipType.url && $0.v == "https://example.com/path" })
    }

    @Test("classicChips detects a phone number in plain text")
    func classicChipsDetectsPhoneNumber() {
        let chips = TextChipDetector.classicChips(in: "Call me at (415) 555-2671 tomorrow")
        #expect(chips.contains { $0.t == ChipType.phone })
    }

    @Test("classicChips detects a date in plain text")
    func classicChipsDetectsDate() {
        let chips = TextChipDetector.classicChips(in: "Let's meet on January 5, 2027")
        #expect(chips.contains { $0.t == ChipType.date })
    }

    @Test("TextChipDetector.detect ignores content past maxScanLength")
    func detectCapsScanLength() async {
        // Placing the only detectable date well past the 10k-char cap
        // means it must NOT show up — proving the prefix cap is
        // actually applied, not just present as a constant.
        let padding = String(repeating: "a", count: TextChipDetector.maxScanLength + 500)
        let text = padding + " January 5, 2027"
        let chips = await TextChipDetector.detect(in: text)
        #expect(!chips.contains { $0.t == ChipType.date })
    }

    // MARK: - TextChipDetector: regex tracking fallback

    @Test("regexTrackingFallback finds a UPS number with no context keyword needed")
    func regexFallbackFindsUPSWithoutContext() {
        let chips = TextChipDetector.regexTrackingFallback(in: "here's the number: 1Z999AA10123456784")
        #expect(chips.count == 1)
        #expect(chips[0].t == ChipType.tracking)
        #expect(chips[0].v == "1Z999AA10123456784")
        #expect(chips[0].s.hasPrefix("UPS"))
    }

    @Test("regexTrackingFallback requires a shipping keyword for FedEx's bare digit-run pattern")
    func regexFallbackRequiresContextForFedEx() {
        let noContext = TextChipDetector.regexTrackingFallback(in: "the invoice total was 123456789012 dollars")
        #expect(noContext.isEmpty)

        let withContext = TextChipDetector.regexTrackingFallback(in: "your FedEx tracking number is 123456789012")
        #expect(withContext.contains { $0.t == ChipType.tracking && $0.v == "123456789012" })
    }

    @Test("regexTrackingFallback requires a shipping keyword for USPS's digit-run pattern")
    func regexFallbackRequiresContextForUSPS() {
        let noContext = TextChipDetector.regexTrackingFallback(in: "random number 9400111899223197428490 here")
        #expect(noContext.isEmpty)

        let withContext = TextChipDetector.regexTrackingFallback(
            in: "usps package tracking: 9400111899223197428490")
        #expect(withContext.contains { $0.t == ChipType.tracking && $0.v == "9400111899223197428490" })
    }

    // MARK: - EntryRepository.entriesNeedingChips + TextChipBackfiller

    private func insertEntry(
        in store: Store,
        kind: EntryKind,
        textPreview: String?,
        chipsJson: String? = nil
    ) throws -> Int64 {
        try store.dbQueue.write { db in
            var d = Device(identifier: "chip-test-device-\(UUID())", name: "Test", kind: "mac")
            try d.insert(db)
            var entry = Entry(
                uuid: Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
                createdAt: Date().timeIntervalSince1970,
                capturedAt: Date().timeIntervalSince1970,
                kind: kind,
                sourceDeviceId: d.id!,
                title: nil,
                textPreview: textPreview,
                contentHash: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                totalSize: Int64(textPreview?.utf8.count ?? 0),
                modifiedAt: Date().timeIntervalSince1970,
                chipsJson: chipsJson
            )
            try entry.insert(db)
            return entry.id!
        }
    }

    @Test("entriesNeedingChips returns only live text/link rows with chips_json IS NULL")
    func entriesNeedingChipsFiltersCorrectly() throws {
        let store = try Store.inMemory()
        let needsScan = try insertEntry(in: store, kind: .text, textPreview: "call 415-555-2671")
        _ = try insertEntry(in: store, kind: .text, textPreview: "already scanned", chipsJson: "[]")
        _ = try insertEntry(in: store, kind: .image, textPreview: nil)

        let repo = EntryRepository(store: store)
        let candidates = try repo.entriesNeedingChips(limit: 10)
        #expect(candidates.map(\.entryId) == [needsScan])
    }

    @Test("TextChipBackfiller scans candidates and always stamps chips_json (even when empty)")
    func backfillerStampsChipsJson() async throws {
        let store = try Store.inMemory()
        let withPhone = try insertEntry(in: store, kind: .text, textPreview: "reach me at (415) 555-2671")
        let noMatches = try insertEntry(in: store, kind: .text, textPreview: "just some ordinary words")

        let repo = EntryRepository(store: store)
        let backfiller = TextChipBackfiller(repository: repo)
        let report = try await backfiller.runOnce(limit: 10)
        #expect(report.candidates == 2)
        #expect(report.scanned == 2)
        #expect(report.failed == 0)

        // Both rows are stamped (no longer NULL), whether or not chips
        // were actually found — that's what keeps them out of future
        // candidate lists.
        #expect(try repo.entriesNeedingChips(limit: 10).isEmpty)

        let phoneEntry = try repo.fetch(id: withPhone)
        #expect(Chip.decodeArray(phoneEntry?.chipsJson).contains { $0.t == ChipType.phone })

        let emptyEntry = try repo.fetch(id: noMatches)
        #expect(emptyEntry?.chipsJson == "[]")
    }
}
