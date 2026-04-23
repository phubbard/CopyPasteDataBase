#if os(iOS)
import SwiftUI
import Combine
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
            VStack(spacing: 0) {
                if let progress = container.pullProgress,
                   let started = container.pullStartedAt {
                    PullProgressBanner(progress: progress, startedAt: started)
                }
                List(results, id: \.id) { entry in
                    NavigationLink(value: entry.id) {
                        EntryRow(entry: entry)
                    }
                }
                .listStyle(.plain)
            }
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
                if results.isEmpty && container.pullProgress == nil {
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

/// Slim banner shown at the top of SearchView while a pull is in
/// flight. Honest reporter: we don't know the total record count
/// CloudKit will hand us, so no percentage / ETA — just a live
/// count, an overall rate, and elapsed time. User sees motion and
/// can gauge pace.
private struct PullProgressBanner: View {
    let progress: CloudKitSyncer.PullReport
    let startedAt: Date
    /// Ticks every second so the elapsed-time label refreshes even
    /// when no new page has arrived yet (CloudKit can pause between
    /// pages for 10+ seconds when throttling).
    @State private var now: Date = Date()
    private static let ticker = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        let applied = progress.inserted + progress.updated + progress.tombstoned
        let elapsed = max(now.timeIntervalSince(startedAt), 0.001)
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pulling from iCloud")
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 6) {
                    Text("\(applied) entries")
                    Text("·")
                    Text(Self.rateString(applied: applied, elapsed: elapsed))
                    Text("·")
                    Text(Self.elapsedString(elapsed))
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
        .onReceive(Self.ticker) { self.now = $0 }
    }

    private static func rateString(applied: Int, elapsed: TimeInterval) -> String {
        guard elapsed > 0.5, applied > 0 else { return "—" }
        let rate = Double(applied) / elapsed
        if rate >= 10 {
            return String(format: "%.0f/s", rate)
        } else {
            return String(format: "%.1f/s", rate)
        }
    }

    private static func elapsedString(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

#endif
