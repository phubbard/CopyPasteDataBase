#if os(iOS)
import SwiftUI
import CpdbShared

/// One row in SearchView's list. Renders a kind-appropriate icon +
/// a snippet + the source device/app + relative timestamp.
///
/// Intentionally compact so 7-10 rows fit on an iPhone screen without
/// scrolling. Detail view (push from this row) shows the full entry.
struct EntryRow: View {
    let entry: Entry

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kindIcon)
                .font(.system(size: 16))
                .foregroundStyle(kindColor)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(snippet)
                    .font(.system(size: 14))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(Self.relative.localizedString(
                        for: Date(timeIntervalSince1970: entry.createdAt),
                        relativeTo: Date()
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    if entry.ocrText != nil {
                        Label("OCR", systemImage: "textformat.abc.dottedunderline")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var snippet: String {
        if let title = entry.title, !title.isEmpty { return title }
        if let text = entry.textPreview, !text.isEmpty { return text }
        return "(\(entry.kind.rawValue))"
    }

    private var kindIcon: String {
        switch entry.kind {
        case .text:  return "text.alignleft"
        case .link:  return "link"
        case .image: return "photo"
        case .file:  return "doc"
        case .color: return "paintpalette"
        case .other: return "questionmark.square"
        }
    }

    private var kindColor: Color {
        switch entry.kind {
        case .text:  return .primary
        case .link:  return .blue
        case .image: return .purple
        case .file:  return .orange
        case .color: return .pink
        case .other: return .secondary
        }
    }
}
#endif
