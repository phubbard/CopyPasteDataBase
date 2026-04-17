import SwiftUI
import CpdbCore

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

    static let cardSize = CGSize(width: 320, height: 360)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            body(for: row.entry.kind)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selectionColor, lineWidth: isSelected ? 3 : 1)
        )
        .overlay(alignment: .topTrailing) {
            matchBadge
        }
        .shadow(color: .black.opacity(isSelected ? 0.22 : 0.10), radius: isSelected ? 10 : 4, y: 2)
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
            case .multiple:
                badgeCapsule(label: "•••", color: .purple)
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
                TextCard(row: row, snippet: snippet)
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
