import Foundation
#if canImport(DataDetection)
import DataDetection
#endif

/// Scans a text preview for data chips.
///
/// Two detection layers:
///   - Classic `NSDataDetector` (macOS 10.7+ / iOS 4+ — well under this
///     package's macOS 14 / iOS 17 floor) for date, address, phone,
///     link, and transit-information (flight number) matches. This is
///     the workhorse and runs everywhere.
///   - The newer standalone `DataDetection` framework (module
///     `DataDetection`, `StringProtocol.dataDetectorMatches` —
///     confirmed present and NOT UIKit/AppKit-gated: it's a plain
///     `AsyncSequence` extension on `StringProtocol`, available
///     `iOS 26 / macOS 26+`) for money-amount and shipment-tracking-
///     number matches, which classic `NSDataDetector` has no checking
///     type for at all. Gated behind `#available(iOS 26, macOS 26, *)`;
///     below that floor, tracking numbers fall back to
///     `regexTrackingFallback` (money amounts are simply skipped pre-26
///     — there's no reasonable regex for "is this a price").
///
/// Runs off the main thread — `Ingestor` fires this from a detached
/// `.utility` Task per `.inserted` text/link capture; `TextChipBackfiller`
/// reuses it for the catch-up pass over pre-existing rows.
public enum TextChipDetector {

    /// Scanning a multi-megabyte text preview is unbounded work for
    /// content the user is unlikely to have pasted expecting chip
    /// detection past the first screenful anyway — bound the
    /// pathological case, not the common one (mirrors
    /// `ImageIndexer.giantImageThresholdBytes`'s reasoning).
    public static let maxScanLength = 10_000

    /// Matches an explicit time-of-day token ("3pm", "3 PM", "14:30")
    /// inside an `NSDataDetector` date match's own substring — see the
    /// `hasTime` comment in `classicChips` for why this exists instead
    /// of trusting `result.timeZone`/`result.duration`.
    private static let timeTokenPattern = try! NSRegularExpression(
        pattern: #"\b\d{1,2}(:\d{2})?\s*(am|pm)\b|\b\d{1,2}:\d{2}\b"#,
        options: [.caseInsensitive]
    )

    public static func detect(in fullText: String) async -> [Chip] {
        let text = String(fullText.prefix(maxScanLength))
        guard !text.isEmpty else { return [] }

        var chips = classicChips(in: text)
        if #available(iOS 26.0, macOS 26.0, *) {
            chips += await frameworkChips(in: text)
        } else {
            chips += regexTrackingFallback(in: text)
        }
        return chips
    }

    // MARK: - NSDataDetector (macOS 14+ / iOS 17+ floor)

    private static let classicTypes: NSTextCheckingResult.CheckingType = [
        .date, .address, .phoneNumber, .link, .transitInformation,
    ]

    static func classicChips(in text: String) -> [Chip] {
        guard let detector = try? NSDataDetector(types: classicTypes.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var chips: [Chip] = []
        detector.enumerateMatches(in: text, options: [], range: range) { result, _, _ in
            guard let result else { return }
            switch result.resultType {
            case .date:
                guard let date = result.date else { return }
                let iso = ISO8601DateFormatter().string(from: date)
                // `result.timeZone`/`result.duration` are NOT reliable
                // "did the text mention a time-of-day" signals despite
                // appearances: empirically, `NSDataDetector` only
                // populates `timeZone` when the match names an
                // *explicit zone* ("3pm PST"), not for the ordinary
                // "January 5 at 3pm" case, and `duration` stays 0 for a
                // plain point-in-time match either way. Fall back to
                // scanning the matched substring itself for a
                // recognizable time token (bare "3pm"/"3 PM" or
                // "14:30") so the common case still renders and
                // round-trips into the `.ics` SUMMARY with its time.
                let matchedText = Range(result.range, in: text).map { String(text[$0]) } ?? ""
                let hasTime = result.timeZone != nil || result.duration > 0
                    || Self.timeTokenPattern.firstMatch(
                        in: matchedText, range: NSRange(matchedText.startIndex..., in: matchedText)
                    ) != nil
                let display = DateFormatter.localizedString(
                    from: date, dateStyle: .medium, timeStyle: hasTime ? .short : .none)
                chips.append(Chip(t: ChipType.date, v: iso, s: display))
            case .address:
                guard let components = result.components else { return }
                let line = [
                    components[.street], components[.city], components[.state],
                    components[.zip], components[.country],
                ]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
                guard !line.isEmpty else { return }
                chips.append(Chip(t: ChipType.address, v: line, s: line))
            case .phoneNumber:
                guard let phone = result.phoneNumber else { return }
                chips.append(Chip(t: ChipType.phone, v: phone, s: phone))
            case .link:
                guard let url = result.url else { return }
                chips.append(Chip(t: ChipType.url, v: url.absoluteString, s: url.host ?? url.absoluteString))
            case .transitInformation:
                guard let components = result.components else { return }
                let airline = components[.airline] ?? ""
                let flight = components[.flight] ?? ""
                let value = airline + flight
                guard !value.isEmpty else { return }
                let display = [airline, flight].filter { !$0.isEmpty }.joined(separator: " ")
                chips.append(Chip(t: ChipType.flight, v: value, s: display))
            default:
                break
            }
        }
        return chips
    }

    // MARK: - DataDetection framework (iOS 26 / macOS 26+)

    @available(iOS 26.0, macOS 26.0, *)
    private static func frameworkChips(in text: String) async -> [Chip] {
        var chips: [Chip] = []
        for await match in text.dataDetectorMatches([.moneyAmount, .shipmentTrackingNumber]) {
            switch match.details {
            case .moneyAmount(let money):
                let formatter = NumberFormatter()
                formatter.numberStyle = .currency
                formatter.currencyCode = money.currency.identifier
                let amount = NSDecimalNumber(decimal: money.amount)
                let display = formatter.string(from: amount) ?? "\(money.amount) \(money.currency.identifier)"
                chips.append(Chip(t: ChipType.money, v: display, s: display))
            case .shipmentTrackingNumber(let tracking):
                let display = "\(tracking.carrier) \(tracking.trackingNumber)"
                chips.append(Chip(t: ChipType.tracking, v: tracking.trackingNumber, s: display))
            default:
                break
            }
        }
        return chips
    }

    // MARK: - Regex tracking-number fallback (pre-macOS/iOS 26)

    /// Requires a nearby shipping-related keyword before trying any
    /// pattern except UPS's (whose `1Z` prefix is distinctive enough on
    /// its own) — a bare 12-digit or 20-digit run is common in
    /// unrelated text (order numbers, phone numbers with a country
    /// code, receipt totals), and the framework path above is what
    /// actually ships for that precision-sensitive case; this fallback
    /// only needs to be "usually right" for the OS versions that lack
    /// it.
    private static let trackingContextKeywords = [
        "tracking", "track", "shipment", "shipped", "package", "parcel",
        "delivery", "fedex", "ups", "usps",
    ]

    static func regexTrackingFallback(in text: String) -> [Chip] {
        let lower = text.lowercased()
        let hasContext = trackingContextKeywords.contains { lower.contains($0) }
        var chips: [Chip] = []
        var seen = Set<String>()
        let range = NSRange(text.startIndex..., in: text)
        for (carrier, regex) in TrackingCarrier.patterns {
            guard carrier == .ups || hasContext else { continue }
            regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match, let r = Range(match.range, in: text) else { return }
                let value = String(text[r])
                guard !seen.contains(value) else { return }
                seen.insert(value)
                chips.append(Chip(t: ChipType.tracking, v: value, s: "\(carrier.displayName) \(value)"))
            }
        }
        return chips
    }
}
