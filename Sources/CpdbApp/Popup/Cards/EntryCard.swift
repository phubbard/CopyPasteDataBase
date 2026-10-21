import SwiftUI
import CpdbCore
import CpdbShared

/// Top-level card renderer. Dispatches on `entry.kind` to the per-kind
/// sub-views in this folder, then wraps everything in a consistent
/// selection chrome.
struct EntryCard: View {
    let row: EntryRepository.EntryRow
    let snippet: String?
    /// Which FTS column contained the user's search hit. Nil when the
    /// popup is in "most recent" mode (no active query).
    let matchSource: FtsIndex.MatchSource?
    let isSelected: Bool
    /// True when this card is the anchor of the popup's time-pivot
    /// mode. Renders a small clock badge so the user can spot the
    /// reference point among the chronologically-ordered neighbors.
    var isTimePivotAnchor: Bool = false
    /// Non-nil only on the card whose sticky note is being edited: the
    /// editor overlays this card and writes into the binding.
    var noteDraft: Binding<String>? = nil
    /// Fired when the open editor's text view loses focus (user clicked
    /// the search field); the strip wires this to commit, so editor mode
    /// can never outlive the editor's keyboard ownership.
    var onNoteFocusLost: (() -> Void)? = nil

    static let cardSize = CGSize(width: 320, height: 360)

    /// Fixed footer band so the card's internal layout is fully
    /// determinate. Under the LazyHStack, proposal-driven sizing
    /// (body slot at maxHeight .infinity + natural-height footer)
    /// measured ~a footer taller than the card and the overflow
    /// centered, guillotining the first text line on the card's top
    /// clip edge (v3.2.2 regression, invisible under the eager
    /// HStack's full-height proposals). With both bands explicit,
    /// the VStack always totals exactly cardSize.height.
    static let footerBand: CGFloat = 32

    /// Sticky-note strip band, present only on a card that has a note. It
    /// is taken OUT of the body slot (body = card − footer − note band),
    /// never added on top, so the VStack still totals exactly
    /// `cardSize.height` — the same fixed-band discipline as
    /// `footerBand`, and what keeps `PopupController.panelHeight` valid.
    /// It sits directly under the body, below the bottom-pinned `ChipRow`,
    /// so the two never overlap.
    static let noteBand: CGFloat = 28

    /// Height of the note editor overlaid on the card while editing. An
    /// overlay, so it affects no layout.
    static let noteEditorHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            body(for: row.entry.kind)
                .frame(maxWidth: .infinity)
                .frame(height: Self.cardSize.height - Self.footerBand - (note == nil ? 0 : Self.noteBand), alignment: .topLeading)
                .clipped()
            if let note {
                NoteStrip(note: note)
                    .frame(height: Self.noteBand)
            }
            footer
                .frame(height: Self.footerBand)
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height, alignment: .top)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selectionColor, lineWidth: isSelected ? 3 : 1)
        )
        .overlay(alignment: .topTrailing) {
            matchBadge
        }
        .overlay(alignment: .topLeading) {
            // Pin glyph at top-left for pinned entries. Sits above
            // the body content but below the selection chrome (which
            // is the card's stroked overlay). Accent-colored to
            // match the kind icon, no chrome — pin is a state, not
            // an action target.
            HStack(spacing: 6) {
                if row.entry.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Pinned")
                }
                if isTimePivotAnchor {
                    // Distinct glyph + colour so it doesn't visually
                    // collide with the pin badge when both apply.
                    Image(systemName: "clock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Time-pivot anchor")
                }
            }
            .padding(8)
        }
        .overlay(alignment: .bottom) {
            if let noteDraft {
                NoteEditor(text: noteDraft, onFocusLost: onNoteFocusLost)
                    .padding(8)
            }
        }
        .shadow(color: .black.opacity(isSelected ? 0.22 : 0.10), radius: isSelected ? 10 : 4, y: 2)
        // No card tooltip while editing: it would pop over the editor.
        .help(noteDraft == nil ? tooltip : "")
    }

    /// The user's sticky note, when it has visible content.
    private var note: String? { NoteStrip.visibleNote(row.entry.note) }

    /// The FTS snippet a text card may show in place of its preview. FTS5
    /// picks the best-matching column for the snippet, so on a hit that
    /// involves the note it can be a fragment of the NOTE — the card would
    /// then show the note's words as if they were the clip's. Those hits
    /// keep the clip's own text; the strip and the match badge say why
    /// the card matched.
    static func bodySnippet(_ snippet: String?, matchSource: FtsIndex.MatchSource?) -> String? {
        switch matchSource {
        case .note, .multiple: return nil
        default: return snippet
        }
    }

    /// Multi-line tooltip surfaced via SwiftUI's `.help(...)` modifier.
    /// macOS renders this as a system tooltip after a hover delay.
    /// Four lines: kind, source app (with bundle id when available),
    /// originating device, absolute timestamp. Falls back gracefully
    /// when fields are missing — older entries imported before
    /// devices/apps existed have only timestamps.
    private var tooltip: String {
        var lines: [String] = []
        lines.append("Type: \(prettyKind)")
        if let appName = row.appName, !appName.isEmpty {
            if let bid = row.appBundleId, !bid.isEmpty, bid != appName {
                lines.append("From: \(appName) (\(bid))")
            } else {
                lines.append("From: \(appName)")
            }
        }
        if let dev = row.deviceName, !dev.isEmpty {
            lines.append("Device: \(dev)")
        }
        let captured = Date(timeIntervalSince1970: row.entry.capturedAt)
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        lines.append("Captured: \(f.string(from: captured))")
        if abs(row.entry.createdAt - row.entry.capturedAt) > 1 {
            // Distinct created vs captured (eg. CloudKit pull preserves
            // captured_at from the original device, created_at is local
            // ingest time). Surface both so the user can see the lag.
            lines.append("Imported: \(f.string(from: Date(timeIntervalSince1970: row.entry.createdAt)))")
        }
        if let summary = row.entry.aiSummary, !summary.isEmpty {
            lines.append("Summary: \(summary)")
        }
        return lines.joined(separator: "\n")
    }

    private var prettyKind: String {
        switch row.entry.kind {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return "File"
        case .color: return "Color"
        case .other: return "Other"
        }
    }

    /// Tiny corner chip that surfaces WHY this card showed up in search
    /// results. Hidden for plain-text matches (the common case — no need
    /// to shout about it) and hidden entirely when no query is active.
    @ViewBuilder
    private var matchBadge: some View {
        if let source = matchSource {
            switch source {
            case .ocr:
                badgeCapsule(label: "OCR", color: .accentColor)
            case .tag:
                badgeCapsule(label: "tag", color: .green)
            case .note:
                badgeCapsule(label: "note", color: .orange)
            case .multiple:
                badgeCapsule(label: "•••", color: .purple)
            case .semantic:
                badgeCapsule(label: "≈", color: .blue)
            case .text:
                EmptyView()
            }
        }
    }

    private func badgeCapsule(label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(color))
            .padding(8)
    }

    @ViewBuilder
    private func body(for kind: EntryKind) -> some View {
        switch kind {
        case .text, .other:
            // Promote hex-color-shaped text to a color swatch. Common case:
            // the user copied `#FF3300` from DevTools and it was captured
            // as plain text, not Cocoa's pasteboard color flavor.
            if let hex = HexColor.detect(row.entry.textPreview ?? "") {
                ColorCard(row: row, hexOverride: hex)
            } else {
                TextCard(row: row, snippet: Self.bodySnippet(snippet, matchSource: matchSource))
            }
        case .link:
            LinkCard(row: row)
        case .image:
            ImageCard(row: row)
        case .file:
            FileCard(row: row)
        case .color:
            ColorCard(row: row)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: kindSymbol)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(row.appName ?? row.entry.kind.rawValue)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(relativeDate)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.background.opacity(0.35))
    }

    private var kindSymbol: String {
        switch row.entry.kind {
        case .text:  return "text.alignleft"
        case .link:  return "link"
        case .image: return "photo"
        case .file:  return "doc"
        case .color: return "paintpalette"
        case .other: return "questionmark.square"
        }
    }

    private var cardBackground: some View {
        Color(nsColor: .textBackgroundColor)
    }

    private var selectionColor: Color {
        isSelected ? .accentColor : .secondary.opacity(0.25)
    }

    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(
            for: Date(timeIntervalSince1970: row.entry.createdAt),
            relativeTo: Date()
        )
    }
}
