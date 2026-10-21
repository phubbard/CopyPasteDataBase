import SwiftUI
import AppKit

/// Colours shared by the sticky-note strip on a card and the editor that
/// opens over it. The strip is a tint over the card so it follows light /
/// dark mode; the editor is "paper" with fixed dark ink in both modes,
/// because yellow paper with white ink is unreadable.
enum StickyNoteStyle {
    static let stripFill = Color.yellow.opacity(0.30)
    static let glyph = Color.orange
    static let paper = Color(red: 1.0, green: 0.95, blue: 0.60)
    static let ink = Color(red: 0.16, green: 0.14, blue: 0.08)
    static let nsInk = NSColor(red: 0.16, green: 0.14, blue: 0.08, alpha: 1)
}

/// One-line sticky-note strip: a note glyph plus the first line of the
/// user's note, truncated. Occupies `EntryCard.noteBand`, a fixed band
/// carved out of the card's body slot between the body (and its
/// `ChipRow`) and the footer — never added to the card's height, so
/// `PopupController.panelHeight`'s contract holds. The full note rides in
/// the tooltip.
struct NoteStrip: View {
    let note: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StickyNoteStyle.glyph)
            Text(Self.firstLine(of: note))
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(StickyNoteStyle.stripFill)
        .help(note)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Note: \(note)")
    }

    /// The note when it has visible content, else nil. Notes are stored
    /// normalized (blank → NULL), but a card must not reserve a band for
    /// text that renders as nothing.
    static func visibleNote(_ note: String?) -> String? {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return note
    }

    /// First line with visible content — a note that opens with blank
    /// lines still shows its first real line.
    static func firstLine(of note: String) -> String {
        let line = note.split(whereSeparator: \.isNewline)
            .first { !$0.allSatisfy(\.isWhitespace) }
        return (line.map(String.init) ?? note).trimmingCharacters(in: .whitespaces)
    }
}
