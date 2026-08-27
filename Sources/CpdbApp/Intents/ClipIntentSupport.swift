#if os(macOS)
import Foundation
import CpdbShared

/// Pure logic shared by the App Intents (`SearchClipsIntent`,
/// `PasteLatestIntent`, `PasteNthIntent`, `TogglePinLatestIntent`) and by
/// `ClipEntityQuery`. Kept free of AppKit/`PopupController` so it's
/// testable without a real popup panel, window server, or Spotlight —
/// this is the "testable seam" the intents sit on top of.
enum ClipIntentSupport {
    /// Entries considered "recent" for intent purposes. Same ordering
    /// `PopupState`/`EntryStripView` show — pinned-first, then
    /// newest-first — so "your last clip" / "clip number N" always
    /// matches what the user would see as card N in the popup itself.
    static func recentEntries(store: Store, limit: Int) throws -> [EntryRepository.EntryRow] {
        try EntryRepository(store: store).recent(limit: limit)
    }

    /// 1-based index into `rows` (1 = newest/top card). Returns nil for
    /// an out-of-range index (empty history, or `n` beyond what's
    /// there) rather than clamping — callers surface that as "nothing
    /// to paste" instead of silently pasting the wrong thing.
    static func entry(atRecentIndex n: Int, in rows: [EntryRepository.EntryRow]) -> EntryRepository.EntryRow? {
        guard n >= 1, n <= rows.count else { return nil }
        return rows[n - 1]
    }

    /// Short display title for a `ClipEntity` row or a donated
    /// Spotlight item: the AI-generated title if the semantic
    /// enrichment pipeline has produced one, else the first line of
    /// the text preview, else the stored title, else a kind fallback.
    static func displayTitle(for entry: Entry, maxLength: Int = 60) -> String {
        let raw = entry.aiTitle?.trimmedNonEmpty
            ?? entry.textPreview?.split(separator: "\n", maxSplits: 1).first.map(String.init)?.trimmedNonEmpty
            ?? entry.title?.trimmedNonEmpty
            ?? "(\(entry.kind.rawValue))"
        guard raw.count > maxLength else { return raw }
        return String(raw.prefix(maxLength - 1)) + "…"
    }

    /// Subtitle line for a `ClipEntity`/Shortcuts row: source app +
    /// relative capture time, matching the metadata the popup card
    /// itself shows.
    static func subtitle(for row: EntryRepository.EntryRow) -> String {
        let app = row.appName ?? "Unknown app"
        return "\(app) · \(relativeDate(row.entry.capturedAt))"
    }

    private static func relativeDate(_ unixSeconds: Double) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: unixSeconds), relativeTo: Date())
    }
}

extension String {
    /// nil for an empty-after-trimming string; used to fall through a
    /// `??` chain of increasingly-generic title candidates.
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
#endif
