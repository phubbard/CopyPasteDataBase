import SwiftUI
import CpdbCore

/// Rendering for text / "other" entries.
///
/// No ellipsis, no fade — the user wants to see the entry verbatim to pick
/// reliably. The bigger `EntryCard.cardSize` (320 × 360) gives plenty of
/// room: ~2 lines of headline plus ~18 lines of 11 pt monospace body text.
/// If the preview is still longer than that, the overflow clips at the
/// card bottom; for *selecting* an entry the leading chunk is what counts.
struct TextCard: View {
    let row: EntryRepository.EntryRow
    let snippet: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(firstLine)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(remaining)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        // Clip the text to the card bounds instead of bleeding into the footer.
        .clipped()
    }

    // The FTS snippet (with `[highlights]`) is the prettier fallback, but
    // for non-search mode we show the raw text_preview. Either way strip
    // the `[` / `]` markers — inline AttributedString styling can come later.
    private var displayText: String {
        if let snippet = snippet {
            return snippet
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
        }
        return row.entry.textPreview ?? ""
    }

    private var firstLine: String {
        displayText.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? row.entry.title
            ?? "(empty)"
    }

    private var remaining: String {
        let lines = displayText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count > 1 else { return "" }
        return lines.dropFirst().joined(separator: "\n")
    }
}
