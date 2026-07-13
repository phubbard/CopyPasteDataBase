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

    /// Settings sheet (capture toggle + manual save). Capture is opt-in
    /// per device — see `SettingsSheet` / `IOSClipboardCapture`.
    @State private var showSettings: Bool = false

    /// Undo snackbar after a delete/pin. Auto-dismisses; the token
    /// guards against a stale dismissal cancelling a newer toast.
    @State private var undoToast: UndoToastState? = nil
    @State private var undoToastToken: Int = 0
    struct UndoToastState: Equatable { let message: String; let token: Int }

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

                    // Thin status row for the canonical-hash v2 identity
                    // cutover and gated-sync states. Deliberately NOT the
                    // old push-every-row-down banner (see comment above)
                    // — a single caption line under the brand header, so
                    // layout stays stable whether it's showing or not.
                    // Pull-to-refresh doesn't get special-cased: `pullNow`
                    // still runs and returns quickly with `gated == true`
                    // while this row keeps telling the truth throughout.
                    migrationStatusRow

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
                        // Swipe-right → Pin / Unpin. Pinned entries
                        // skip eviction policies and float to the top
                        // of the list. Same toggle as the Mac context
                        // menu's Pin / Unpin item; CloudKit pushes
                        // the new state to other devices.
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                guard let id = row.entry.id else { return }
                                Task { await togglePin(id: id, currentlyPinned: row.entry.pinned) }
                            } label: {
                                if row.entry.pinned {
                                    Label("Unpin", systemImage: "pin.slash")
                                } else {
                                    Label("Pin", systemImage: "pin")
                                }
                            }
                            .tint(.orange)
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
            // Shake-to-undo (the iOS system gesture). Works when the
            // search field isn't first responder; the snackbar is the
            // always-available path. Wired to the same coordinator.
            .background(ShakeDetector { Task { await performUndo() } })
            // Undo snackbar — the Mail-style toast with an Undo button.
            .overlay(alignment: .bottom) {
                if let toast = undoToast {
                    UndoSnackbar(message: toast.message) {
                        Task { await performUndo() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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
                    HStack(spacing: 10) {
                        syncIndicator
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .sheet(isPresented: $showAbout) {
                AboutSheet()
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet()
                    .environment(container)
                    .presentationDetents([.medium, .large])
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

    /// Status row shown while the canonical-hash v2 identity cutover is
    /// running / has failed, or (more generally) while sync is gated
    /// for any reason. Priority: an in-progress or failed cutover is
    /// the most specific, actionable message; a bare `syncGated` (e.g.
    /// caught between cutover completing and its follow-up pull) falls
    /// back to a generic "paused" line. Empty view when everything's
    /// healthy so the list layout doesn't shift.
    @ViewBuilder
    private var migrationStatusRow: some View {
        switch container.migrationState {
        case .running(let text):
            migrationBanner(icon: "arrow.triangle.2.circlepath", text: "Upgrading library… \(text)")
        case .failed:
            migrationBanner(icon: "exclamationmark.triangle", text: "Library upgrade paused — will retry", tint: .orange)
        case .idle:
            if container.syncGated {
                migrationBanner(icon: "icloud.slash", text: "Sync paused — library upgrade pending")
            }
        }
    }

    private func migrationBanner(icon: String, text: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .listRowInsets(.init(top: 0, leading: 0, bottom: 6, trailing: 0))
        .listRowSeparator(.hidden)
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
    ///
    /// After the DB write, kick a push so the tombstone propagates
    /// to the Mac and other devices right away instead of waiting
    /// for the next foreground poll.
    /// Flip the entry's pin state. Same shape as deleteEntry —
    /// run the DB write off-main, refresh, kick a push so the
    /// other devices learn about it within seconds.
    private func togglePin(id: Int64, currentlyPinned: Bool) async {
        guard let undo = container.undo else { return }
        do {
            // Through the UndoCoordinator so it's reversible. The
            // single-row write runs on the main actor (sub-ms).
            let desc = try await MainActor.run { try undo.setPinned(id: id, pinned: !currentlyPinned) }
            await runQuery()
            await container.pushNow()
            if let desc { await MainActor.run { showUndoToast(desc) } }
        } catch {
            print("[cpdb] pin toggle failed for id=\(id): \(error)")
        }
    }

    private func deleteEntry(id: Int64) async {
        guard let undo = container.undo else { return }
        do {
            let desc = try await MainActor.run { try undo.delete(id: id) }
            await runQuery()
            await container.pushNow()
            await MainActor.run { showUndoToast(desc) }
        } catch {
            print("[cpdb] delete failed for id=\(id): \(error)")
        }
    }

    /// Apply the most recent undo (from the snackbar's Undo button or a
    /// shake) and propagate.
    private func performUndo() async {
        guard let undo = container.undo, undo.canUndo else { return }
        do {
            _ = try await MainActor.run { try undo.undo() }
            await runQuery()
            await container.pushNow()
            await MainActor.run { undoToast = nil }
        } catch {
            print("[cpdb] undo failed: \(error)")
        }
    }

    private func showUndoToast(_ desc: UndoCoordinator.ActionDescription) {
        undoToastToken += 1
        let token = undoToastToken
        withAnimation { undoToast = UndoToastState(message: desc.pastTense, token: token) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if undoToast?.token == token { withAnimation { undoToast = nil } }
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

                    // Image and link kinds both write thumbnails to
                    // the same `previews` table — image entries get
                    // their captured payload thumbnailed at ingest
                    // (v1.1+), link entries get the og:image / oEmbed
                    // / Wikipedia / favicon-fallback bytes from the
                    // background backfiller (v2.7.1+). Either way
                    // the row renders with a real visual instead of
                    // the kind glyph.
                    if entry.kind == .image || effective == .link {
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

/// Settings sheet. First pass: clipboard-capture controls.
///
/// Capture is **opt-in and OFF by default** — see `IOSClipboardCapture`
/// for why iOS can't safely auto-capture in the background and why every
/// read is gated behind `detectPatterns` (no paste banner). Two controls:
///
///   - **Capture clipboard on this device** — the master toggle. Persisted
///     via `@AppStorage` to the same key `AppContainer` reads to gate all
///     capture. When on, the app may save the clipboard on foreground
///     activation (still detect-gated).
///   - **Save clipboard now** — explicit one-shot capture. Reads the
///     clipboard (shows the system paste banner, as expected for an
///     explicit user action) and stores text/links. Disabled while the
///     toggle is off.
struct SettingsSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    /// Bound to the same UserDefaults key `AppContainer.isCaptureEnabled`
    /// reads. `@AppStorage` keeps the toggle and the container's gate in
    /// lockstep without any manual plumbing.
    @AppStorage(AppContainer.captureEnabledKey) private var captureEnabled: Bool = false

    /// Transient confirmation after a manual save.
    @State private var lastSaveNote: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Capture clipboard on this device", isOn: $captureEnabled)
                } header: {
                    Text("Clipboard capture")
                } footer: {
                    Text("Off by default. When on, cpdb can save what you copy on this iPhone so it syncs to your other devices. iOS can only read the clipboard while the app is open, and shows a “pasted from” banner each time it reads — so capture happens on an explicit save or when you return to the app, never silently in the background.")
                }

                Section {
                    Button {
                        Task {
                            await container.saveClipboardNow()
                            lastSaveNote = "Saved current clipboard"
                        }
                    } label: {
                        Label("Save clipboard now", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(!captureEnabled)

                    if let note = lastSaveNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Reads the current clipboard once and stores any text or link. iOS will briefly show a “pasted from” banner — that’s the system telling you cpdb read the clipboard because you asked it to.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Mail-style undo snackbar: a floating capsule with a message and an
/// Undo button. Auto-dismissal is owned by the caller (SearchView).
struct UndoSnackbar: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.subheadline)
            Spacer(minLength: 8)
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .frame(maxWidth: 480)
    }
}

/// Detects the iOS shake gesture and reports it. Implemented as a
/// first-responder `UIView` overriding `motionEnded`. It yields first
/// responder to the search field when the user taps it (so typing's own
/// shake-to-undo still works); the snackbar is the always-available
/// affordance when the detector isn't focused.
struct ShakeDetector: UIViewRepresentable {
    let onShake: () -> Void

    func makeUIView(context: Context) -> ShakeView {
        let v = ShakeView()
        v.onShake = onShake
        return v
    }
    func updateUIView(_ uiView: ShakeView, context: Context) {
        uiView.onShake = onShake
    }

    final class ShakeView: UIView {
        var onShake: (() -> Void)?
        override var canBecomeFirstResponder: Bool { true }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Grab first responder when nothing else (e.g. the search
            // field) currently holds it, so shakes route here.
            if window != nil { becomeFirstResponder() }
        }
        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            if motion == .motionShake { onShake?() }
            super.motionEnded(motion, with: event)
        }
    }
}

#endif
