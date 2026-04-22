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
        ZStack {
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
        }
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
