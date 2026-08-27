import Foundation

/// Maps decoded QR/barcode payload strings (from `VNDetectBarcodesRequest`
/// via `ImageAnalyzer`) into `Chip`s.
///
/// Deliberately simple, per the feature's design: `URL(string:)` plus a
/// recognized scheme is the "is this a URL" test — no heuristic sniffing
/// of unprefixed host-looking strings (`ImageAnalyzer`'s OCR-derived text
/// chips already cover that territory via `TextChipDetector`'s
/// `NSDataDetector` link type, which IS willing to guess at bare
/// `example.com`-shaped text). A `tel:` scheme becomes a phone chip; any
/// other scheme in `recognizedURLSchemes` (`http(s)`, `mailto:`, `geo:`,
/// `wifi:`, ...) becomes a URL chip since it's still something
/// `NSWorkspace.open` can hand off meaningfully. Anything left over that
/// merely *looks* like a bare phone number becomes a phone chip;
/// everything else is a generic text chip.
///
/// The allowlist matters beyond just scoping "what's a URL": Foundation's
/// `URL(string:)` parser (macOS 14+) is lenient enough to hand back a
/// non-nil `scheme` for plain key/value or labeled text that was never
/// meant as a URI at all — `URL(string: "NOTE: call mom")!.scheme ==
/// "NOTE"`, `URL(string: "SN:12345-ABC")!.scheme == "SN"`. Accepting
/// *any* non-empty scheme would misclassify a QR-encoded serial number
/// or label as a URL chip whose tap silently no-ops (`NSWorkspace.open`
/// on a scheme with no handler) instead of the generic text chip's
/// copy-to-pasteboard — the one useful affordance that payload class
/// actually has.
public enum QRChipMapper {
    /// Schemes worth treating as "this payload is a URL". Deliberately
    /// closed rather than "any real scheme" — see the type's doc
    /// comment. `tel` is handled separately, before this set is
    /// consulted. Kept to schemes an actual QR-code generator would
    /// plausibly emit, not an open-ended "whatever `NSWorkspace.open`
    /// might do something with" set (which would readmit the
    /// misclassification problem this exists to prevent, one unusual
    /// but real word/label prefix at a time).
    private static let recognizedURLSchemes: Set<String> = [
        "http", "https", "mailto", "sms", "smsto", "geo", "wifi", "ftp",
    ]
    public static func chips(from payloads: [String]) -> [Chip] {
        var chips: [Chip] = []
        var seen = Set<String>()
        for raw in payloads {
            let payload = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, !seen.contains(payload) else { continue }
            seen.insert(payload)
            chips.append(chip(for: payload))
        }
        return chips
    }

    private static func chip(for payload: String) -> Chip {
        if let url = URL(string: payload), let scheme = url.scheme, !scheme.isEmpty {
            let lowerScheme = scheme.lowercased()
            if lowerScheme == "tel" {
                let number = payload.dropFirst(scheme.count + 1)
                let display = String(number)
                return Chip(t: ChipType.phone, v: display, s: display)
            }
            if recognizedURLSchemes.contains(lowerScheme) {
                let display = (lowerScheme == "http" || lowerScheme == "https") ? (url.host ?? payload) : payload
                return Chip(t: ChipType.url, v: payload, s: display)
            }
            // Parsed with a scheme, but not one we recognize as a real
            // URI scheme — most likely a labeled/key-value text payload
            // ("NOTE: call mom", "SN:12345-ABC") that Foundation's
            // lenient parser happens to accept. Fall through to the
            // phone/text checks below instead of treating it as a URL.
        }
        if looksLikePhoneNumber(payload) {
            return Chip(t: ChipType.phone, v: payload, s: payload)
        }
        let display = payload.count > 60 ? String(payload.prefix(60)) + "\u{2026}" : payload
        return Chip(t: ChipType.text, v: payload, s: display)
    }

    /// Conservative bare-phone-number sniff for payloads with no `tel:`
    /// scheme — digits (plus common separators) only, in a plausible
    /// phone-number length range.
    private static func looksLikePhoneNumber(_ s: String) -> Bool {
        let digitCount = s.filter(\.isNumber).count
        guard digitCount >= 7, digitCount <= 15 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789+-() .")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
