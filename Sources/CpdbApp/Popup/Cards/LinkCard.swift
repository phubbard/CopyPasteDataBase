import SwiftUI
import AppKit
import GRDB
import CpdbCore
import CpdbShared

/// Rendering for `link` entries.
///
/// Full URL is the primary signal — put it at the top in the primary text
/// colour so it's actually readable. Host + title, being derivative, go
/// below in the secondary/tertiary tint.
struct LinkCard: View {
    let row: EntryRepository.EntryRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // v2.7.1: background-fetched preview thumbnail (og:image
            // / oEmbed thumbnail_url). When present, the visual
            // anchor goes on top, then title + URL beneath. Bounded
            // height so a tall image doesn't push the title off the
            // card.
            if let thumb = loadThumbnail() {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .clipped()
            }
            // Background-fetched page / video title (v2.7+). When
            // present, it's the most useful piece of information on
            // the card — promote it to the top in primary weight.
            // The URL still shows below for orientation but in
            // monospaced secondary for de-emphasis.
            if let linkTitle = row.entry.linkTitle, !linkTitle.isEmpty {
                Text(linkTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(urlString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                // No fetched title — fall back to the original
                // layout: URL top, host below.
                Text(urlString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
                Text(hostString)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let title = row.entry.title,
               !title.isEmpty,
               title != urlString,
               title != row.entry.linkTitle
            {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var urlString: String {
        row.entry.textPreview ?? row.entry.title ?? ""
    }

    private var hostString: String {
        guard let url = URL(string: urlString), let host = url.host else {
            return row.entry.title ?? urlString
        }
        return host
    }

    /// Pulls the link-preview thumbnail bytes from the `previews`
    /// table (same table image entries use). v2.7.1's background
    /// link-metadata fetcher writes them after grabbing og:image /
    /// oEmbed thumbnail_url. Returns nil when no preview was
    /// fetched — the caller falls back to the kind glyph.
    ///
    /// Synchronous for the same reason as ImageCard.loadThumbnail:
    /// thumbs are small and the row count on screen is bounded.
    private func loadThumbnail() -> NSImage? {
        guard let id = row.entry.id else { return nil }
        guard let store = try? Store.open() else { return nil }
        let data: Data? = (try? store.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT thumb_large, thumb_small FROM previews WHERE entry_id = ?",
                arguments: [id]
            ).flatMap { row in
                row["thumb_large"] as Data? ?? row["thumb_small"] as Data?
            }
        }) ?? nil
        guard let data else { return nil }
        return NSImage(data: data)
    }
}
