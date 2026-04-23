#if os(iOS)
import SwiftUI
import CpdbShared

/// Root view: navigation stack hosting a searchable list of entries.
///
/// Results come from `EntryRepository` in CpdbShared — same logic the
/// Mac popup uses. iPhone-first layout: vertical list, no strip, no
/// sidebar. Tap pushes `EntryDetailView`.
struct SearchView: View {
    @Environment(AppContainer.self) private var container
    @State private var query: String = ""
    @State private var results: [Entry] = []
    /// Debounce timer token — cancelled on every keystroke so rapid
    /// typing only triggers one query after the user pauses.
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        NavigationStack {
            List(results, id: \.id) { entry in
                NavigationLink(value: entry.id) {
                    EntryRow(entry: entry)
                }
            }
            .listStyle(.plain)
            .navigationDestination(for: Int64.self) { entryId in
                EntryDetailView(entryId: entryId)
            }
            .navigationTitle("cpdb")
            .searchable(text: $query, prompt: "Search clipboard history")
            .refreshable {
                await container.pullNow()
                await runQuery()
            }
            .onChange(of: query) { _, _ in
                scheduleQuery()
            }
            .onAppear {
                Task { await runQuery() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    syncIndicator
                }
            }
            .overlay {
                if results.isEmpty {
                    emptyState
                }
            }
        }
    }

    @ViewBuilder
    private var syncIndicator: some View {
        if container.isSyncing {
            ProgressView().controlSize(.small)
        } else {
            Button {
                Task {
                    await container.pullNow()
                    await runQuery()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Pull from iCloud")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if container.store == nil {
            ContentUnavailableView(
                "Starting…",
                systemImage: "icloud.and.arrow.down",
                description: Text("Opening local database and connecting to iCloud.")
            )
        } else if let err = container.lastError {
            ContentUnavailableView(
                "Sync error",
                systemImage: "exclamationmark.icloud",
                description: Text(err).font(.caption)
            )
        } else if query.isEmpty {
            ContentUnavailableView(
                "No entries yet",
                systemImage: "list.clipboard",
                description: Text("Captures on your Macs appear here once they sync.")
            )
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    private func scheduleQuery() {
        searchTask?.cancel()
        searchTask = Task {
            // 200 ms debounce — feels snappy without hammering the DB
            // on every keystroke.
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            await runQuery()
        }
    }

    /// Hit the repository for the top N matches. Uses the same
    /// `EntryRepository.search` used by the Mac popup.
    private func runQuery() async {
        guard let store = container.store else {
            results = []
            return
        }
        let snapshotQuery = query
        do {
            let rows: [Entry] = try await store.dbQueue.read { db in
                if snapshotQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return try Entry
                        .filter(sql: "deleted_at IS NULL")
                        .order(sql: "created_at DESC")
                        .limit(200)
                        .fetchAll(db)
                } else {
                    // Simple LIKE-based fallback for now. A later pass
                    // can wire EntryRepository + FTS5 once its API is
                    // exposed the same way on iOS.
                    let like = "%\(snapshotQuery)%"
                    return try Entry
                        .filter(sql: "deleted_at IS NULL AND (title LIKE ? OR text_preview LIKE ? OR ocr_text LIKE ? OR image_tags LIKE ?)",
                                arguments: [like, like, like, like])
                        .order(sql: "created_at DESC")
                        .limit(200)
                        .fetchAll(db)
                }
            }
            if !Task.isCancelled {
                results = rows
            }
        } catch {
            if !Task.isCancelled {
                results = []
            }
        }
    }
}

import GRDB
#endif
