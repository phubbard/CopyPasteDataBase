#if os(iOS)
import Foundation

/// Tiny helpers for deciding if a chunk of text is URL-shaped. Shared
/// between EntryRow (row icon/color) and EntryDetailView (body rendering
/// as boxed link). Both views need the same rules so what looks like a
/// URL in the list matches what acts like a URL in the detail.
enum URLDetection {

    /// True iff the trimmed string is exactly one URL — no leading or
    /// trailing text, no embedded whitespace. Used to decide whether
    /// to promote a text-kind entry to the link UI.
    static func isWholeStringAURL(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline })
        else { return false }
        return cleanURL(from: trimmed) != nil
    }

    /// Best-effort URL parse. Accepts trailing whitespace, prepends
    /// https:// when the input has no scheme but looks host-shaped
    /// (e.g. `github.com/foo`). Returns nil for garbage.
    static func cleanURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        if let url = URL(string: "https://\(trimmed)"), url.host != nil {
            return url
        }
        return nil
    }
}
#endif
