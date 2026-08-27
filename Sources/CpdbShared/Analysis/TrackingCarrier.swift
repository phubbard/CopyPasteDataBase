import Foundation

/// Shipment-tracking-number carrier detection, shared between two
/// call sites that both need the same answer to "which carrier is this
/// number from":
///   - `TextChipDetector`'s pre-macOS-26 regex fallback, since the
///     `DataDetection` framework's `.shipmentTrackingNumber` match type
///     (which carries its own `carrier` field) is macOS/iOS 26+ only —
///     see that type's doc comment.
///   - The popup card's tap action (`ChipAction`), which re-derives the
///     carrier from a tracking chip's raw value to pick a tracking-site
///     URL template — regardless of whether the chip was originally
///     detected via the framework or the regex fallback, so tap
///     behavior is uniform either way.
public enum TrackingCarrier: String, Sendable {
    case ups, fedex, usps

    public var displayName: String {
        switch self {
        case .ups: return "UPS"
        case .fedex: return "FedEx"
        case .usps: return "USPS"
        }
    }

    /// Ordered most-to-least distinctive: UPS's `1Z` prefix and USPS's
    /// long digit run practically can't collide with anything else, but
    /// FedEx's bare 12/15-digit pattern is checked last since a random
    /// 12-digit number is otherwise unremarkable — see
    /// `TextChipDetector.regexTrackingFallback`'s context-keyword gate,
    /// which exists specifically to keep that pattern from firing on
    /// arbitrary numeric text.
    static let patterns: [(TrackingCarrier, NSRegularExpression)] = [
        (.ups, try! NSRegularExpression(pattern: #"\b1Z[0-9A-Z]{16}\b"#)),
        (.usps, try! NSRegularExpression(pattern: #"\b(94|93|92|82|20)\d{20}\b"#)),
        (.fedex, try! NSRegularExpression(pattern: #"\b\d{15}\b|\b\d{12}\b"#)),
    ]

    /// Best-effort carrier classification from a bare tracking-number
    /// string (no surrounding context available at tap time — this
    /// pattern match is all there is to go on).
    public static func detect(_ value: String) -> TrackingCarrier? {
        let range = NSRange(value.startIndex..., in: value)
        for (carrier, regex) in patterns {
            if regex.firstMatch(in: value, options: [], range: range) != nil {
                return carrier
            }
        }
        return nil
    }

    /// Carrier tracking-site URL for a raw tracking number. Falls back
    /// to a generic web search when the carrier can't be determined —
    /// still a useful tap destination rather than a dead end.
    public static func trackingURL(for value: String) -> URL {
        let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
        switch detect(value) {
        case .ups:
            return URL(string: "https://www.ups.com/track?tracknum=\(encoded)")!
        case .fedex:
            return URL(string: "https://www.fedex.com/fedextrack/?trknbr=\(encoded)")!
        case .usps:
            return URL(string: "https://tools.usps.com/go/TrackConfirmAction?tLabels=\(encoded)")!
        case nil:
            return URL(string: "https://www.google.com/search?q=track+package+\(encoded)")!
        }
    }
}
