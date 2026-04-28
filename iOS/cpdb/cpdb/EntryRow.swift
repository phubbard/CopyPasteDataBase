#if os(iOS)
import SwiftUI
import CpdbShared
#if canImport(UIKit)
import UIKit
#endif

/// One row in SearchView's list. Renders a kind-appropriate icon +
/// a snippet + the source device/app + relative timestamp. Image
/// entries get their small thumbnail rendered inline instead of the
/// generic photo glyph.
///
/// Intentionally compact so 7-10 rows fit on an iPhone screen without
/// scrolling. Detail view (push from this row) shows the full entry.
struct EntryRow: View {
    let entry: Entry
    /// For link-kind entries whose title + textPreview are empty,
    /// this is the URL pulled from the joined `public.url` /
    /// `public.utf8-plain-text` flavor. Non-nil only in that fallback
    /// case; text/image/etc. entries get nil here.
    var linkURL: String? = nil
    /// Small thumbnail bytes for image-kind entries. When present,
    /// replaces the kind-icon glyph in the leading slot.
    var thumbSmall: Data? = nil
    /// Post-classification kind. Some entries arrive as `.text`
    /// because the source app only provided a text flavor (Zen
    /// browser is a known offender), but the content is obviously a
    /// URL. SearchView reclassifies those to `.link` at query time
    /// and passes the resolved kind here so the row badge + color
    /// match what the detail view will render.
    var effectiveKind: EntryKind? = nil

    /// The kind we actually render with — caller-override wins,
    /// falls back to the entry's stored kind.
    private var displayKind: EntryKind {
        effectiveKind ?? entry.kind
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leadingIcon
                .frame(width: 44, height: 44, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 4) {
                    if entry.pinned {
                        // Inline pin glyph at the start of the
                        // snippet so the eye lands on it before
                        // reading. Tinted accent so it blends with
                        // the kind icon's visual vocabulary.
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tint)
                            .padding(.top, 1)
                            .accessibilityLabel("Pinned")
                    }
                    Text(snippet)
                        .font(.system(size: 14))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }
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

    /// Leading slot: small thumbnail for image entries, kind-icon
    /// glyph for everything else. 44×44 so the column width is
    /// consistent regardless of which branch renders.
    @ViewBuilder
    private var leadingIcon: some View {
        #if canImport(UIKit)
        if displayKind == .image,
           let data = thumbSmall,
           let image = UIImage(data: data)
        {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary, lineWidth: 0.5)
                )
        } else {
            kindGlyph
        }
        #else
        kindGlyph
        #endif
    }

    @ViewBuilder
    private var kindGlyph: some View {
        Image(systemName: kindIcon)
            .font(.system(size: 20))
            .foregroundStyle(kindColor)
    }

    private var snippet: String {
        if let title = entry.title, !title.isEmpty { return title }
        if let text = entry.textPreview, !text.isEmpty { return text }
        if let url = linkURL, !url.isEmpty { return url }
        return "(\(entry.kind.rawValue))"
    }

    private var kindIcon: String {
        switch displayKind {
        case .text:  return "text.alignleft"
        case .link:  return "link"
        case .image: return "photo"
        case .file:  return "doc"
        case .color: return "paintpalette"
        case .other: return "questionmark.square"
        }
    }

    private var kindColor: Color {
        switch displayKind {
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
