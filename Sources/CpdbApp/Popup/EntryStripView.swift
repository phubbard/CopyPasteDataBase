import SwiftUI
import AppKit
import GRDB
import CpdbCore
import CpdbShared

/// Horizontal, Paste-style card scroller.
///
/// Cards are a fixed 180×280; the strip scrolls horizontally and scrolls the
/// selected card into view automatically when the user moves the selection
/// via the keyboard monitor in `PopupController`.
struct EntryStripView: View {
    @Bindable var state: PopupState
    let onPaste: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(state.rows.enumerated()), id: \.element.entry.id) { index, row in
                        EntryCard(
                            row: row,
                            snippet: state.snippetsById[row.entry.id!],
                            matchSource: state.matchSourcesById[row.entry.id!],
                            isSelected: index == state.selectedIndex
                        )
                        .id(row.entry.id!)
                        .onTapGesture(count: 2) {
                            state.selectedIndex = index
                            onPaste()
                        }
                        .onTapGesture {
                            state.selectedIndex = index
                        }
                        .contextMenu {
                            contextMenu(for: row, index: index)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onChange(of: state.selectedIndex) { _, newIndex in
                guard state.rows.indices.contains(newIndex) else { return }
                let id = state.rows[newIndex].entry.id!
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // On every popup summon (bumped by PopupController), snap the
            // selected card into view. For a fresh summon selectedIndex is
            // 0 so this puts us at the newest; when the user has enabled
            // "remember scroll on preview" and re-summons after a QL
            // round-trip, selectedIndex is whatever they had — so we
            // resume in place. Anchor differs from the selectedIndex
            // handler above (leading vs. center) — this one is a reset,
            // the other a navigation follow.
            .onChange(of: state.scrollToken) { _, _ in
                guard state.rows.indices.contains(state.selectedIndex) else { return }
                let id = state.rows[state.selectedIndex].entry.id!
                proxy.scrollTo(id, anchor: .leading)
            }
        }
    }

    /// Right-click menu on a card. Three actions mirroring the iOS
    /// detail view's toolbar so the two platforms feel the same:
    ///   - Quick Look (⌘Y also works via the popup's key monitor)
    ///   - Share via the macOS share sheet (NSSharingServicePicker)
    ///   - Delete (tombstone + CloudKit push)
    @ViewBuilder
    private func contextMenu(
        for row: EntryRepository.EntryRow,
        index: Int
    ) -> some View {
        Button {
            state.selectedIndex = index
            PopupController.shared.previewSelected()
        } label: {
            Label("Quick Look", systemImage: "eye")
        }

        Button {
            togglePin(row: row)
        } label: {
            // Pinned entries skip eviction policies and float to the
            // top of the popup. Toggle action lets the same menu
            // item Pin and Unpin without two separate items.
            if row.entry.pinned {
                Label("Unpin", systemImage: "pin.slash")
            } else {
                Label("Pin", systemImage: "pin")
            }
        }

        Button {
            share(row: row)
        } label: {
            Label("Share…", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button(role: .destructive) {
            delete(row: row)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Flip the entry's pin state and refresh the popup. The repo
    /// also enqueues for CloudKit push, so the new state propagates
    /// to iOS and sibling Macs.
    private func togglePin(row: EntryRepository.EntryRow) {
        guard let id = row.entry.id else { return }
        let newState = !row.entry.pinned
        let store = state.store
        Task.detached {
            do {
                let repo = EntryRepository(store: store)
                try repo.setPinned(id: id, pinned: newState)
            } catch {
                Log.cli.error(
                    "pin toggle failed for entry id=\(id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
            await MainActor.run { state.refresh() }
        }
    }

    /// Build the best representation of the entry's payload we can
    /// offer the share sheet. Text-like entries share their text;
    /// link entries share the resolved URL; image entries stage the
    /// largest inline flavor bytes to a temp PNG/JPEG so receiving
    /// apps recognize it as an image. Falls back to text_preview
    /// when nothing better is available.
    private func share(row: EntryRepository.EntryRow) {
        let entry = row.entry
        var items: [Any] = []

        if entry.kind == .image {
            // Try to stage the full image to a temp file so the share
            // sheet renders a proper preview. Fall back to textPreview
            // if the flavor isn't resolvable.
            if let tempURL = stageImageFlavor(entryId: entry.id!) {
                items = [tempURL]
            }
        } else if entry.kind == .link, let preview = entry.textPreview,
                  let url = URL(string: preview.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme != nil
        {
            items = [url]
        }

        if items.isEmpty, let preview = entry.textPreview, !preview.isEmpty {
            items = [preview]
        }
        if items.isEmpty, let title = entry.title, !title.isEmpty {
            items = [title]
        }
        guard !items.isEmpty else { return }

        // Anchor the picker to the popup panel. Using `showRelativeTo`
        // is required when the owning window is a transient NSPanel
        // (the popup) — otherwise AppKit can't find a sensible
        // position and logs a warning.
        let picker = NSSharingServicePicker(items: items)
        if let window = NSApp.keyWindow,
           let contentView = window.contentView
        {
            picker.show(
                relativeTo: .zero,
                of: contentView,
                preferredEdge: .minY
            )
        }
    }

    /// Copy the entry's primary image flavor bytes to a temp file,
    /// returning the URL. Caller uses it for the share sheet;
    /// macOS will clean the temp dir in due course.
    private func stageImageFlavor(entryId: Int64) -> URL? {
        let blobs = BlobStore()
        let data: Data? = try? state.store.dbQueue.read { db -> Data? in
            for uti in ["public.png", "public.jpeg", "public.heic", "public.tiff"] {
                if let flavor = try Flavor
                    .filter(Column("entry_id") == entryId)
                    .filter(Column("uti") == uti)
                    .fetchOne(db)
                {
                    return try blobs.load(inline: flavor.data, blobKey: flavor.blobKey)
                }
            }
            return nil
        }
        guard let bytes = data else { return nil }
        let ext: String = {
            // Best-effort extension from the magic header so Finder /
            // Preview / the share sheet render the right app icon.
            if bytes.count >= 4 {
                let prefix = bytes.prefix(4)
                if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
                if prefix.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
            }
            return "png"
        }()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpdb-share-\(UUID().uuidString).\(ext)")
        do {
            try bytes.write(to: tmp)
            return tmp
        } catch {
            return nil
        }
    }

    /// Tombstone the entry and nudge the popup to re-query.
    /// `PopupState.startLiveUpdates`'s ValueObservation will also
    /// fire, but the explicit refresh makes the row disappear
    /// immediately instead of one GRDB debounce later.
    private func delete(row: EntryRepository.EntryRow) {
        guard let id = row.entry.id else { return }
        let store = state.store
        Task.detached {
            do {
                let repo = EntryRepository(store: store)
                try repo.tombstone(id: id)
            } catch {
                Log.cli.error(
                    "delete failed for entry id=\(id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
            await MainActor.run {
                state.refresh()
            }
        }
    }
}
