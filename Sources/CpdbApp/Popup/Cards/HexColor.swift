import Foundation

/// Detects hex color literals inside text entries.
///
/// Recognises three forms:
/// - `#RGB` (short form, e.g. `#F30` → `#FF3300`)
/// - `#RRGGBB` (e.g. `#FF3300`)
/// - `#RRGGBBAA` (with alpha)
///
/// Returns the expanded `#RRGGBB` or `#RRGGBBAA` form in uppercase, or nil
/// if the trimmed input isn't a hex color. The match is deliberately
/// anchored — a `#FF3300` *inside* a larger string (e.g. "color: #FF3300 !important")
/// doesn't qualify, because misclassifying any CSS snippet as a color card
/// would hide a lot of useful code.
enum HexColor {
    static func detect(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let hex = String(trimmed.dropFirst())
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        switch hex.count {
        case 3:
            // Expand #RGB -> #RRGGBB
            let r = hex[hex.startIndex]
            let g = hex[hex.index(after: hex.startIndex)]
            let b = hex[hex.index(hex.startIndex, offsetBy: 2)]
            return "#\(String([r, r, g, g, b, b]).uppercased())"
        case 6, 8:
            return "#\(hex.uppercased())"
        default:
            return nil
        }
    }
}

private extension Character {
    var isHexDigit: Bool {
        switch self {
        case "0"..."9", "a"..."f", "A"..."F": return true
        default: return false
        }
    }
}
