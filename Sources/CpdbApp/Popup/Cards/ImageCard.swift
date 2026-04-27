import SwiftUI
import AppKit
import GRDB
import CpdbCore
import CpdbShared

/// Rendering for `image` entries. Reads the stored JPEG thumbnail from
/// `previews.thumb_large` (fallback `thumb_small`) and fills the card
/// edge-to-edge. Thumbnails are tiny (<100 KB typically) so we load them
/// synchronously on render — SwiftUI caches `Image` instances by identity
/// so cheap re-renders don't re-decode.
struct ImageCard: View {
    let row: EntryRepository.EntryRow

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let thumb = loadThumbnail() {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("(no thumbnail)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Source-domain overlay. Browser "Copy Image" actions
            // ship a `public.url` flavor on the pasteboard alongside
            // the image bytes — that becomes the entry's
            // text_preview during ingest. Surfacing the host is a
            // big visual anchor: "this image came from nytimes.com"
            // is way more useful at a glance than the truncated
            // image bytes alone. Skip when the preview isn't a
            // recognisable URL (screenshots, in-app captures, etc.)
            //
            // Layout note: the overlay sits inside an explicit
            // alignment frame so SwiftUI lays the capsule out as a
            // fixed-position floating element instead of letting
            // an unbounded host string blow past the card edge
            // before truncation kicks in.
            if let host = sourceDomain {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.system(size: 9, weight: .semibold))
                    Text(host)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(.black.opacity(0.55))
                )
                // Cap width so a long host (e.g.
                // `encrypted-tbn0.gstatic.com`) wraps via the
                // .truncationMode(.middle) above instead of pushing
                // the whole capsule off-screen.
                .frame(maxWidth: 220, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(10)
                .allowsHitTesting(false)
                .help(row.entry.textPreview ?? host)
            }
        }
    }

    /// Best-effort host extraction. `text_preview` for browser image
    /// copies is the source URL (set by `Ingestor.deriveTitle` from
    /// the pasteboard's `public.url` flavor when no plain-text
    /// flavor is present). Strip the scheme and any leading `www.`
    /// for a tighter visual.
    private var sourceDomain: String? {
        guard let raw = row.entry.textPreview?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let host = url.host,
              !host.isEmpty
        else { return nil }
        // Drop a leading "www." — it's almost never useful and
        // burns 4 chars in a tight overlay.
        if host.hasPrefix("www."), host.count > 4 {
            return String(host.dropFirst(4))
        }
        return host
    }

    /// Pulls the thumbnail blob from the `previews` table. This is main-
    /// thread + synchronous; acceptable because thumbs are small and the
    /// row count is capped at 200 on screen.
    private func loadThumbnail() -> NSImage? {
        guard let id = row.entry.id else { return nil }
        // We don't have a store handle here, so open a fresh DatabaseQueue
        // against the canonical DB. Readers are cheap in WAL mode.
        // TODO: pass the store down through environment so this doesn't
        // reopen on every render. Works for now.
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
