import SwiftUI
import AppKit
import ImageIO
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

    @Environment(\.cpdbStore) private var store
    @Environment(\.popupLiveRefreshToken) private var liveRefreshToken
    @State private var thumb: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let thumb {
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
        // Keyed on entry.id AND liveRefreshToken: entry.id alone never
        // changes for an existing row, so a thumbnail written to
        // `previews` *after* this card's first render (e.g. the link-
        // metadata backfiller landing late) would never be picked up —
        // ForEach keeps the card's identity, `refresh()` just hands it
        // a new `row` value, which re-evaluates `body` but does not
        // restart a `.task` whose id is unchanged. Bumping
        // liveRefreshToken only on live-triggered refreshes (not on
        // every keystroke-driven search refresh) re-runs this task so
        // late thumbnails still appear, without refetching on every
        // search-field edit.
        .task(id: "\(row.entry.id ?? -1)#\(liveRefreshToken)") {
            await loadThumbnail()
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

    /// Pulls the thumbnail blob from the `previews` table via the store
    /// injected through the environment (`\.cpdbStore`, set once in
    /// `PopupController.configure` — no more per-render `Store.open()`).
    /// The DB read + `NSImage` decode both happen off the main actor in
    /// `fetchThumbnail`; only the final `thumb = image` assignment lands
    /// back on main. Placeholder art (the `if`/`else` above) covers the
    /// gap while this is in flight, same as the old synchronous version.
    ///
    /// perf: bumps `PopupPerfCounters` (loads + elapsed time) so
    /// `PopupController.show()`/`hide()` can log per-summon card-load
    /// overhead. Measurement only — no behavior change. `storeOpens`
    /// stays untouched here on purpose: this path makes zero
    /// `Store.open()` calls, which is part of the acceptance evidence.
    @MainActor
    private func loadThumbnail() async {
        // Already have a thumb from a prior run of this task (e.g. this
        // re-run was triggered by liveRefreshToken bumping for an
        // unrelated write, not a new preview for THIS row) — skip the
        // DB round trip entirely.
        guard thumb == nil else { return }
        guard let id = row.entry.id, let store else {
            thumb = nil
            return
        }
        let perfStart = DispatchTime.now()
        let image = await Self.fetchThumbnail(id: id, dbQueue: store.dbQueue)
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - perfStart.uptimeNanoseconds
        PopupPerfCounters.shared.recordThumbLoad(nanos: elapsedNanos)
        thumb = image
    }

    /// `nonisolated` so awaiting it from the `@MainActor` caller above
    /// actually hops off the main actor for the blocking GRDB read and
    /// the image decode, instead of running them inline on main.
    private nonisolated static func fetchThumbnail(id: Int64, dbQueue: DatabaseQueue) async -> NSImage? {
        let data: Data? = (try? await dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT thumb_large, thumb_small FROM previews WHERE entry_id = ?",
                arguments: [id]
            ).flatMap { row in
                row["thumb_large"] as Data? ?? row["thumb_small"] as Data?
            }
        }) ?? nil
        guard let data else { return nil }
        return Self.decode(data)
    }

    /// `NSImage(data:)` only parses headers eagerly — the raster decode
    /// of a compressed representation (JPEG/PNG) is deferred until the
    /// image is first drawn, which for an `Image(nsImage:)` in this
    /// view happens on the main thread the frame `thumb` is set. That
    /// would move the expensive part of "decode off main" right back
    /// onto main. Going through `CGImageSource` forces the full raster
    /// decode here, off the main actor, so all that's left for the
    /// main thread is compositing an already-decoded bitmap.
    private nonisolated static func decode(_ data: Data) -> NSImage? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
