import SwiftUI
import AppKit
import ImageIO
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
    /// Decoded once per row — see `TextCard`'s identical field.
    private let chips: [Chip]

    @Environment(\.cpdbStore) private var store
    @Environment(\.popupLiveRefreshToken) private var liveRefreshToken
    @State private var thumb: NSImage?

    init(row: EntryRepository.EntryRow) {
        self.row = row
        self.chips = Chip.decodeArray(row.entry.chipsJson)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // v2.7.1: background-fetched preview thumbnail (og:image
            // / oEmbed thumbnail_url). When present, the visual
            // anchor goes on top, then title + URL beneath. Bounded
            // height so a tall image doesn't push the title off the
            // card.
            if let thumb {
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
            ChipRow(chips: chips)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        // Keyed on entry.id AND liveRefreshToken — see the identical
        // comment on ImageCard.body. This is the primary case that
        // matters for links: LinkMetadataBackfiller writes the og:image
        // bytes into `previews` well after the card's first render, and
        // entry.id alone never changes to pick that up.
        .task(id: "\(row.entry.id ?? -1)#\(liveRefreshToken)") {
            await loadThumbnail()
        }
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
    /// table (same table image entries use), via the store injected
    /// through the environment (`\.cpdbStore`, set once in
    /// `PopupController.configure` — no more per-render `Store.open()`).
    /// v2.7.1's background link-metadata fetcher writes them after
    /// grabbing og:image / oEmbed thumbnail_url. Leaves `thumb` nil
    /// when no preview was fetched — the caller falls back to the
    /// kind glyph.
    ///
    /// The DB read + `NSImage` decode both happen off the main actor
    /// in `fetchThumbnail`; only the final `thumb = image` assignment
    /// lands back on main.
    ///
    /// perf: bumps `PopupPerfCounters` (loads + elapsed time) so
    /// `PopupController.show()`/`hide()` can log per-summon card-load
    /// overhead. Measurement only — no behavior change. `storeOpens`
    /// stays untouched here on purpose: this path makes zero
    /// `Store.open()` calls, which is part of the acceptance evidence.
    @MainActor
    private func loadThumbnail() async {
        // Already have a thumb from a prior run of this task — skip the
        // DB round trip. (When there's genuinely no preview yet, thumb
        // stays nil and we deliberately keep retrying on each
        // liveRefreshToken bump — that's what lets a late-arriving
        // og:image from LinkMetadataBackfiller show up.)
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
    /// is deferred until first draw, which would land back on main.
    /// Going through `CGImageSource` forces the full decode here, off
    /// the main actor. See the identical helper on `ImageCard`.
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
