#if os(iOS)
import SwiftUI
import Combine
import CpdbShared

/// Root view: navigation stack hosting a searchable list of entries.
///
/// Results come from `EntryRepository` in CpdbShared — same logic the
/// Mac popup uses. iPhone-first layout: vertical list, no strip, no
/// sidebar. Tap pushes `EntryDetailView`.
/// Row model: an Entry plus a resolved link URL string when the
/// entry is kind=.link and lacks a usable `title` / `text_preview`.
/// The URL comes from a joined sub-query on `entry_flavors`; fetching
/// it per-row would be N+1 so SearchView's single query resolves it
/// once for the whole batch.
struct SearchRow: Identifiable {
    let entry: Entry
    let linkURL: String?
    /// Small JPEG thumbnail bytes for image-kind entries, pulled from
    /// the `previews` table in the same query pass so the list
    /// doesn't incur an N+1 row-level load. nil for non-image kinds
    /// or images without a generated thumbnail.
    let thumbSmall: Data?
    /// Display kind after URL-reclassification. Zen (and any source
    /// that only provides a text flavor for a copied URL) lands in
    /// the DB as `.text` even though the content is obviously a
    /// link. We detect the bare-URL case at query time and promote
    /// the row's effective kind to `.link` so the badge, color, and
    /// filter-membership all match what the detail view will render.
    let effectiveKind: EntryKind
    var id: Int64? { entry.id }
}

struct SearchView: View {
    @Environment(AppContainer.self) private var container
    @State private var query: String = ""
    @State private var results: [SearchRow] = []
    /// Debounce timer token — cancelled on every keystroke so rapid
    /// typing only triggers one query after the user pauses.
    @State private var searchTask: Task<Void, Never>? = nil

    /// How many rows the current query is allowed to return. Starts
    /// at `pageSize` and grows by `pageSize` each time the user
    /// scrolls to the bottom. Resets on a new search.
    @State private var resultsLimit: Int = 200
    /// Re-entrancy guard so scroll-triggered loadMore() doesn't fire
    /// while a previous bump is still in flight.
    @State private var isLoadingMore: Bool = false
    private static let pageSize: Int = 200

    /// About-sheet presentation. Tapping the brand header opens it.
    @State private var showAbout: Bool = false

    /// Persisted filter state (kind multiselect + search scopes).
    @State private var filter: SearchFilter = .load()
    @State private var showFilter: Bool = false

    var body: some View {
        NavigationStack {
            // No more VStack-wrapped progress banner — it used to sit
            // above the List and push every row down whenever a pull
            // started/ended, which felt jumpy. The compact version
            // now lives in the toolbar next to the filter button;
            // layout is stable whether we're syncing or not.
            List {
                    // Brand title as a list header so it scrolls
                    // away with the content. Tapping it opens the
                    // About sheet.
                    BrandTitle()
                        .contentShape(Rectangle())
                        .onTapGesture { showAbout = true }
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 14, leading: 16, bottom: 14, trailing: 16))
                        .listRowSeparator(.hidden)

                    ForEach(results) { row in
                        NavigationLink(value: row.entry.id) {
                            EntryRow(
                                entry: row.entry,
                                linkURL: row.linkURL,
                                thumbSmall: row.thumbSmall,
                                effectiveKind: row.effectiveKind
                            )
                        }
                        .onAppear {
                            // Load-more trigger: when the last row
                            // is about to appear, bump the query
                            // limit and re-fetch.
                            if row.id == results.last?.id {
                                Task { await loadMore() }
                            }
                        }
                        // Swipe-left → Delete. Tombstones the entry
                        // (sets deleted_at + enqueues for CloudKit
                        // push), re-runs the query, and ValueObserver
                        // on `entries` independently picks up the
                        // change so the list refresh is redundant-
                        // but-immediate. Blobs stay on disk until
                        // `cpdb gc` runs.
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                guard let id = row.entry.id else { return }
                                Task { await deleteEntry(id: id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    if isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            .navigationDestination(for: Int64.self) { entryId in
                EntryDetailView(entryId: entryId)
            }
            // No nav-bar title — the brand lives as a list header
            // so it scrolls away with the content. An empty title
            // keeps the nav bar's height consistent.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search clipboard history")
            .refreshable {
                await container.pullNow()
                await runQuery()
            }
            .onChange(of: query) { _, _ in
                // New search term: reset the page window so we show
                // the top N matches instead of scrolling through a
                // stale expanded list.
                resultsLimit = Self.pageSize
                scheduleQuery()
            }
            // Re-query every time a pull completes (new `lastPull`)
            // AND every time a pull page lands (new `pullProgress`).
            // The pages one makes the list fill in progressively
            // during a long backfill; the completed one catches the
            // final state.
            .onChange(of: container.lastPull) { _, _ in
                Task { await runQuery() }
            }
            .onChange(of: container.pullProgress?.inserted) { _, _ in
                Task { await runQuery() }
            }
            .onChange(of: container.pullProgress?.updated) { _, _ in
                Task { await runQuery() }
            }
            // Live-update hook: AppContainer bumps `dbChangeToken`
            // every time the `entries` table changes — silent-push
            // pulls, foreground pulls, background refreshes. Re-run
            // the current query so new rows appear without the user
            // having to pull-to-refresh.
            .onChange(of: container.dbChangeToken) { _, _ in
                Task { await runQuery() }
            }
            .onAppear {
                Task { await runQuery() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 10) {
                        filterButton
                        // Inline sync progress — renders only while a
                        // pull is in flight. Sits next to the filter
                        // button so the list never shifts. Hidden
                        // entirely when idle so the toolbar stays
                        // visually quiet.
                        if let progress = container.pullProgress,
                           let started = container.pullStartedAt
                        {
                            InlinePullProgress(progress: progress, startedAt: started)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    syncIndicator
                }
            }
            .sheet(isPresented: $showAbout) {
                AboutSheet()
            }
            .sheet(isPresented: $showFilter) {
                FilterSheet(filter: $filter)
                    .presentationDetents([.medium, .large])
            }
            // Persist + re-query on any filter change.
            .onChange(of: filter) { _, new in
                new.save()
                resultsLimit = Self.pageSize
                Task { await runQuery() }
            }
            .overlay {
                if results.isEmpty && container.pullProgress == nil {
                    emptyState
                }
            }
        }
    }

    @ViewBuilder
    private var filterButton: some View {
        Button {
            showFilter = true
        } label: {
            // Small dot badge when the filter diverges from default.
            Image(systemName: filter.isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter and search scope")
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

    /// Tombstone the entry and refresh the list. Runs off-main for
    /// the DB write, then hops back to re-query. The `dbChangeToken`
    /// observer would eventually re-query on its own but we do it
    /// explicitly here for a snappy "row disappears now" feel.
    private func deleteEntry(id: Int64) async {
        guard let store = container.store else { return }
        do {
            let repo = EntryRepository(store: store)
            try await Task.detached { try repo.tombstone(id: id) }.value
            await runQuery()
        } catch {
            print("[cpdb] delete failed for id=\(id): \(error)")
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

    /// Called when the last row becomes visible — grows the result
    /// window by a page and re-queries. No-op once we've seen fewer
    /// rows than the current limit (means we've hit the end).
    private func loadMore() async {
        guard !isLoadingMore else { return }
        // If the previous query returned fewer than the current
        // limit, there's nothing more to fetch.
        guard results.count >= resultsLimit else { return }
        isLoadingMore = true
        resultsLimit += Self.pageSize
        await runQuery()
        isLoadingMore = false
    }

    /// Query entries + (for link-kind entries) resolve a URL string
    /// from `entry_flavors`. One SQL call, one per-row post-process,
    /// no N+1 lookups during rendering. Respects `filter` (kind
    /// multiselect + search-column scopes).
    private func runQuery() async {
        guard let store = container.store else {
            results = []
            return
        }
        let snapshotQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = resultsLimit
        let snapshotFilter = filter
        do {
            let rows: [SearchRow] = try await store.dbQueue.read { db in
                // Assemble WHERE fragments incrementally so we don't
                // emit `AND ()` or similar when the user toggles
                // scopes off.
                var where_: [String] = ["deleted_at IS NULL"]
                var args: [DatabaseValueConvertible] = []

                // Kind filter. Skip the clause when all kinds are
                // selected (the default) so the query planner doesn't
                // walk a pointless IN (...).
                //
                // Reclassification wrinkle: URL-shaped text entries
                // are promoted to `.link` at display time. If the
                // user's filter includes `.link` but not `.text`,
                // we still need to fetch text rows so we have the
                // chance to promote them; we drop non-URL text in the
                // per-row pass below. Symmetric: if `.text` is
                // selected but `.link` is not, we still fetch text
                // rows, then drop the URL-shaped ones.
                var sqlKinds = snapshotFilter.kinds
                if sqlKinds.contains(.link) { sqlKinds.insert(.text) }
                if sqlKinds.count < EntryKind.allCases.count
                    && !sqlKinds.isEmpty
                {
                    let placeholders = Array(repeating: "?", count: sqlKinds.count)
                        .joined(separator: ",")
                    where_.append("kind IN (\(placeholders))")
                    for k in sqlKinds {
                        args.append(k.rawValue)
                    }
                }

                // Search-string filter, per user-selected scopes.
                if !snapshotQuery.isEmpty,
                   let clause = snapshotFilter.scopeLikeClause(for: snapshotQuery)
                {
                    where_.append(clause.sql)
                    args.append(contentsOf: clause.args)
                }

                let whereSQL = where_.joined(separator: " AND ")
                let entries = try Entry
                    .filter(sql: whereSQL, arguments: StatementArguments(args))
                    .order(sql: "created_at DESC")
                    .limit(limit)
                    .fetchAll(db)

                // Per-row post-processing:
                //   - Link entries with no usable preview → pull the
                //     URL bytes from entry_flavors.
                //   - Image entries → pull thumb_small from previews
                //     for inline rendering in EntryRow.
                return try entries.compactMap { entry -> SearchRow? in
                    // Compute effective kind: promote URL-shaped
                    // text → link so the rest of the pipeline
                    // (icon, color, filter honouring) matches the
                    // detail view.
                    var effective = entry.kind
                    if entry.kind == .text {
                        let candidate = entry.title?.isEmpty == false
                            ? entry.title!
                            : (entry.textPreview ?? "")
                        if URLDetection.isWholeStringAURL(candidate) {
                            effective = .link
                        }
                    }

                    // Honour the user's kind filter against the
                    // effective kind, not the stored kind — see SQL
                    // expansion above for the matching fetch.
                    if snapshotFilter.kinds.count < EntryKind.allCases.count,
                       !snapshotFilter.kinds.contains(effective)
                    {
                        return nil
                    }

                    var linkURL: String? = nil
                    var thumbSmall: Data? = nil

                    if effective == .link {
                        // For real link-kind rows with empty preview,
                        // resolve from flavors. For promoted text
                        // rows, the preview IS the URL.
                        if entry.kind == .link,
                           (entry.title?.isEmpty ?? true) && (entry.textPreview?.isEmpty ?? true)
                        {
                            linkURL = try Self.resolveLinkURL(entryId: entry.id!, in: db)
                        } else if entry.kind == .text {
                            linkURL = (entry.title?.isEmpty == false
                                ? entry.title
                                : entry.textPreview)?
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }

                    if entry.kind == .image {
                        thumbSmall = try Data.fetchOne(
                            db,
                            sql: "SELECT thumb_small FROM previews WHERE entry_id = ?",
                            arguments: [entry.id!]
                        )
                    }

                    return SearchRow(
                        entry: entry,
                        linkURL: linkURL,
                        thumbSmall: thumbSmall,
                        effectiveKind: effective
                    )
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

    /// Fetch the stored URL bytes for a link-kind entry and decode
    /// as UTF-8. Tries `public.url` then `public.utf8-plain-text`.
    /// Returns nil if neither flavor is present — the caller shows
    /// a generic "(link)" fallback in that case.
    private static func resolveLinkURL(entryId: Int64, in db: Database) throws -> String? {
        for uti in ["public.url", "public.utf8-plain-text"] {
            if let data = try Data.fetchOne(
                db,
                sql: "SELECT data FROM entry_flavors WHERE entry_id = ? AND uti = ? LIMIT 1",
                arguments: [entryId, uti]
            ) {
                return String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

import GRDB

/// Compact brand header for the nav bar: app icon glyph + title +
/// subtitle stacked. Sits in the principal toolbar slot. SF Symbol
/// `list.clipboard.fill` is the same glyph the Mac menu-bar icon
/// uses, tinted blue to match the Mac app's rounded-square icon.
private struct BrandTitle: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.clipboard.fill")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("cpdb")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("CopyPasteDataBase client")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("cpdb, CopyPasteDataBase client")
    }
}

/// Inline sync progress shown next to the filter button in the
/// toolbar while a pull is in flight. Replaces the old full-width
/// banner above the list — that version pushed rows down when it
/// appeared/disappeared, which felt jumpy on every pull.
///
/// Honest reporter: we don't know the total record count CloudKit
/// will hand us, so no percentage / ETA — just a live count and
/// rate. Drops the elapsed-time column from the old banner to fit
/// inline; if users want it back, tap the refresh button to see the
/// CLI-equivalent log lines.
private struct InlinePullProgress: View {
    let progress: CloudKitSyncer.PullReport
    let startedAt: Date
    /// Ticks every second so the rate label refreshes even when no
    /// new page has arrived yet (CloudKit can pause between pages
    /// for 10+ seconds when throttling).
    @State private var now: Date = Date()
    private static let ticker = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        let applied = progress.inserted + progress.updated + progress.tombstoned
        let elapsed = max(now.timeIntervalSince(startedAt), 0.001)
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("\(applied)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(Self.rateString(applied: applied, elapsed: elapsed))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .accessibilityLabel("Pulling from iCloud, \(applied) entries")
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
