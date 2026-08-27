import Foundation

/// Maps decoded QR/barcode payload strings (from `VNDetectBarcodesRequest`
/// via `ImageAnalyzer`) into `Chip`s.
///
/// Deliberately simple, per the feature's design: `URL(string:)` plus a
/// real scheme is the only "is this a URL" test — no heuristic sniffing
/// of unprefixed host-looking strings (`ImageAnalyzer`'s OCR-derived text
/// chips already cover that territory via `TextChipDetector`'s
/// `NSDataDetector` link type, which IS willing to guess at bare
/// `example.com`-shaped text). A `tel:` scheme becomes a phone chip; any
/// other real scheme (`http(s)`, `mailto:`, `geo:`, `wifi:`, ...) becomes
/// a URL chip since it's still something `NSWorkspace.open` can hand off
/// meaningfully. Anything left over that merely *looks* like a bare phone
/// number becomes a phone chip; everything else is a generic text chip.
public enum QRChipMapper {
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
            let display = (lowerScheme == "http" || lowerScheme == "https") ? (url.host ?? payload) : payload
            return Chip(t: ChipType.url, v: payload, s: display)
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
