import SwiftUI
import CpdbCore

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
            // first card to the leading edge so the user always lands on
            // the newest entry, regardless of where they were scrolled
            // last time. Anchor differs from the selectedIndex handler
            // above (leading vs. center) — this one is a reset, the other
            // a navigation follow.
            .onChange(of: state.scrollToken) { _, _ in
                guard let firstId = state.rows.first?.entry.id else { return }
                proxy.scrollTo(firstId, anchor: .leading)
            }
        }
    }
}
