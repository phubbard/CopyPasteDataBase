import Foundation
import Observation
import GRDB
import CpdbCore
import CpdbShared

/// Observable state backing the popup view.
///
/// One instance per popup, owned by `PopupController`. Re-queries the
/// store whenever `query` changes or `refresh()` is called (e.g. when the
/// popup is summoned). Uses fetch-on-demand rather than GRDB
/// `ValueObservation` — simpler, and "live updates while open" isn't
/// something the user needs yet.
@MainActor
@Observable
final class PopupState {
    private(set) var rows: [EntryRepository.EntryRow] = []
    private(set) var snippetsById: [Int64: String] = [:]
    /// Per-entry match source, populated only while searching. Empty in
    /// "most recent" mode. Used by `EntryCard` to show a small badge.
    private(set) var matchSourcesById: [Int64: FtsIndex.MatchSource] = [:]
    private(set) var totalLive: Int = 0
    private(set) var isSearching: Bool = false

    /// What the user is typing in the search field. Empty = "most recent".
    var query: String = "" {
        didSet { if query != oldValue { refresh() } }
    }

    /// Which FTS5 columns participate in search. Persisted to UserDefaults
    /// so the user's preference sticks across launches.
    var searchScope: FtsIndex.SearchScope = PopupState.loadScope() {
        didSet {
            if searchScope != oldValue {
                PopupState.saveScope(searchScope)
                refresh()
            }
        }
    }

    /// Entry-kind filter chips in the popup header. Default is "all
    /// kinds". Persisted across launches so the user's preference
    /// survives relaunch — same contract as `searchScope`. An empty
    /// set OR a set containing every kind both mean "no filter"; the
    /// repository normalises both to a no-op clause.
    var kindFilter: Set<EntryKind> = PopupState.loadKindFilter() {
        didSet {
            if kindFilter != oldValue {
                PopupState.saveKindFilter(kindFilter)
                refresh()
            }
        }
    }

    /// When true, dismissing the popup to launch Quick Look preserves
    /// the current search query and selection so the next summon
    /// resumes from the same spot — useful if the user has scrolled
    /// deep into history. When false (default), preview-triggered
    /// dismiss resets to the top like a normal close.
    var rememberScrollOnPreview: Bool = PopupState.loadRememberScroll() {
        didSet {
            if rememberScrollOnPreview != oldValue {
                UserDefaults.standard.set(
                    rememberScrollOnPreview,
                    forKey: PopupState.rememberScrollKey
                )
            }
        }
    }

    /// Highlight/selection index within `rows`. Clamped to valid range.
    var selectedIndex: Int = 0

    /// Time-pivot mode — non-nil means the popup is showing
    /// neighbors of an anchor entry instead of search/recent.
    /// `⌘T` on a selected card enters this mode; `Esc` exits and
    /// restores the prior query/selection. `[` / `]` widen / narrow
    /// the window. See `enterTimePivot(...)`.
    private(set) var timePivot: TimePivot?

    /// Allowed time-pivot window sizes, in seconds. Tap `[`/`]` to
    /// move between adjacent entries. 30 min is the default for
    /// "around when I copied this" (clipboard sessions are usually
    /// minutes-to-hours).
    nonisolated(unsafe) public static let timePivotWindowSeconds: [TimeInterval] = [
        15 * 60,        // 15 min
        30 * 60,        // 30 min  ← default
        60 * 60,        // 1 h
        3 * 60 * 60,    // 3 h
        6 * 60 * 60,    // 6 h
        12 * 60 * 60,   // 12 h
        24 * 60 * 60,   // 1 d
    ]

    struct TimePivot: Sendable {
        /// Entry id this pivot is anchored on. Surfaced to the card
        /// renderer so the anchor gets a visual marker among
        /// neighbors.
        let anchorEntryId: Int64
        /// `captured_at` of the anchor — pinned so widening the
        /// window keeps the same pivot point even if the anchor
        /// gets bumped by a re-capture.
        let anchorCapturedAt: Double
        /// Index into `PopupState.timePivotWindowSeconds`.
        var windowIndex: Int
        /// State to restore on Esc exit.
        let savedQuery: String
        let savedSelectedIndex: Int

        var windowSeconds: TimeInterval { PopupState.timePivotWindowSeconds[windowIndex] }
    }

    /// Monotonically-bumped token used to trigger a "scroll to newest" on
    /// every summon. Hiding the popup resets `selectedIndex` to 0 and
    /// `refresh()` repopulates `rows`, but neither of those changes on
    /// their own — `PopupController.show()` bumps this token so
    /// `EntryStripView` knows to snap the first card to the leading edge.
    var scrollToken: Int = 0

    /// Lifecycle banner. Set by `DaemonLifecycle` via the AppDelegate.
    var captureMode: CaptureMode = .capturing

    enum CaptureMode: Equatable {
        case capturing
        case readOnly(holder: String)
    }

    let store: Store
    private let repository: EntryRepository
    /// Maximum number of rows we fetch per refresh. Exposed so the header
    /// can show a `+` on the results counter when we've hit the cap.
    let searchLimit: Int
    /// Monotonic token so stale async results don't overwrite newer ones.
    private var generation: Int = 0

    /// GRDB live-update subscription. Installed by `startLiveUpdates()`
    /// while the popup is on-screen; torn down in `stopLiveUpdates()`
    /// on hide. We don't keep it running 24/7 — it would pin the DB
    /// file and emit work we'd throw away.
    private var liveObservation: (any DatabaseCancellable)?
    /// Debounce token: a burst of writes (an insert touches `entries`,
    /// `entry_flavors`, and FTS rows in one transaction) should only
    /// run refresh() once. Bumping this cancels any prior pending task.
    private var liveRefreshGeneration: Int = 0

    init(store: Store, recentLimit: Int = 200) {
        self.store = store
        self.repository = EntryRepository(store: store)
        self.searchLimit = recentLimit
    }

    /// Re-run the current query. Called when the popup is shown, when
    /// `query` changes, or after a paste to reflect the bumped entry.
    func refresh() {
        generation += 1
        let gen = generation
        let q = query.trimmingCharacters(in: .whitespaces)

        // Total count is cheap; update eagerly.
        totalLive = (try? repository.totalLiveCount()) ?? totalLive

        // Fetch synchronously on main — the DB reads are fast and the popup
        // UI expects an immediate result on summon. If this turns out to
        // block the UI for image-heavy rows we can push it to a task.
        isSearching = !q.isEmpty && timePivot == nil
        do {
            // Time-pivot mode supersedes search + recent — the user
            // explicitly switched away from those.
            if let pivot = timePivot {
                let fetched = try repository.neighbors(
                    ofCapturedAt: pivot.anchorCapturedAt,
                    windowSeconds: pivot.windowSeconds
                )
                guard gen == generation else { return }
                rows = fetched
                snippetsById = [:]
                matchSourcesById = [:]
                // Selection lands on the anchor so it's the focused
                // card when pivot mode opens (and after widen/narrow).
                if let i = rows.firstIndex(where: { $0.entry.id == pivot.anchorEntryId }) {
                    selectedIndex = i
                } else {
                    selectedIndex = rows.isEmpty ? 0 : min(selectedIndex, rows.count - 1)
                }
                return
            }
            if q.isEmpty {
                let fetched = try repository.recent(
                    limit: searchLimit,
                    kinds: kindFilter
                )
                guard gen == generation else { return }
                rows = fetched
                snippetsById = [:]
                matchSourcesById = [:]
            } else {
                let results = try repository.search(
                    query: q,
                    scope: searchScope,
                    kinds: kindFilter,
                    limit: searchLimit
                )
                guard gen == generation else { return }
                rows = results.map(\.row)
                snippetsById = Dictionary(
                    uniqueKeysWithValues: results.map { ($0.row.entry.id!, $0.snippet) }
                )
                matchSourcesById = Dictionary(
                    uniqueKeysWithValues: results.map { ($0.row.entry.id!, $0.source) }
                )
            }
            selectedIndex = rows.isEmpty ? 0 : min(selectedIndex, rows.count - 1)
        } catch {
            Log.cli.error("popup refresh failed: \(String(describing: error), privacy: .public)")
            rows = []
            snippetsById = [:]
            matchSourcesById = [:]
            selectedIndex = 0
        }
    }

    // MARK: - Live updates while the popup is visible

    /// Subscribe to writes on `entries` so new captures (local or
    /// CloudKit-pulled) show up in the popup without the user having
    /// to dismiss + re-summon. Idempotent: calling twice is a no-op.
    ///
    /// We track `entries` only — flavors changing without a parent row
    /// change aren't user-visible in the strip, and observing more
    /// tables means more wake-ups with nothing to show. CloudKit pulls
    /// touch `entries` inside the same transaction that writes flavors,
    /// so we don't miss remote updates either.
    func startLiveUpdates() {
        guard liveObservation == nil else { return }
        // Projection that changes when anything user-visible changes:
        //   - row count (insert / tombstone)
        //   - max created_at (insert)
        //   - sum of link_fetched_at across links (background link
        //     backfill stamps this on every UPDATE — so a fresh title
        //     coming in causes the sum to change)
        //   - preview row count (thumbnail writes — link backfill
        //     phase 2, image-kind imports, oEmbed thumb downloads)
        //   - max captured_at (covers in-place bumps from re-capture)
        // GRDB ValueObservation auto-tracks every table read inside
        // the closure, so adding a SELECT against `previews` here is
        // also what subscribes us to that table — no manual wiring
        // needed.
        let observation = ValueObservation.tracking { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL") ?? 0
            let maxCreated = try Double.fetchOne(db, sql: "SELECT MAX(created_at) FROM entries WHERE deleted_at IS NULL") ?? 0
            let maxCaptured = try Double.fetchOne(db, sql: "SELECT MAX(captured_at) FROM entries WHERE deleted_at IS NULL") ?? 0
            let linkProgress = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(link_fetched_at), 0) FROM entries WHERE kind = 'link' AND deleted_at IS NULL") ?? 0
            let previewCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM previews") ?? 0
            return LiveSignal(
                count: count,
                maxCreated: maxCreated,
                maxCaptured: maxCaptured,
                linkProgress: linkProgress,
                previewCount: previewCount
            )
        }
        liveObservation = observation.start(
            in: store.dbQueue,
            scheduling: .immediate,
            onError: { error in
                Log.cli.error("popup live updates errored: \(String(describing: error), privacy: .public)")
            },
            onChange: { [weak self] _ in
                Task { @MainActor in self?.scheduleLiveRefresh() }
            }
        )
    }

    /// Tear down the live-update subscription. Called by `PopupController`
    /// on hide so we don't pin the DB file or burn CPU refreshing an
    /// invisible view.
    func stopLiveUpdates() {
        liveObservation?.cancel()
        liveObservation = nil
        liveRefreshGeneration &+= 1  // drop any pending debounced task
    }

    /// Debounced wrapper around `refresh()`. A single pasteboard
    /// capture triggers multiple writes on `entries` + `entry_flavors`
    /// + FTS; GRDB fires ValueObservation once per transaction, but
    /// back-to-back captures (e.g. CloudKit applying a pull page of
    /// 100 rows) would otherwise thrash the popup. 120 ms feels live
    /// without flicker.
    private func scheduleLiveRefresh() {
        liveRefreshGeneration &+= 1
        let gen = liveRefreshGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard gen == self.liveRefreshGeneration else { return }
            self.refresh()
        }
    }

    /// Opaque projection used to drive `ValueObservation`. Equatable
    /// so GRDB can suppress no-op change notifications (e.g. a flavor
    /// insert that doesn't touch `entries`).
    private struct LiveSignal: Equatable {
        let count: Int
        let maxCreated: Double
        let maxCaptured: Double
        let linkProgress: Double
        let previewCount: Int
    }

    // MARK: - Scope persistence

    private static let scopeDefaultsKey = "cpdb.popup.scope"

    private static func loadScope() -> FtsIndex.SearchScope {
        guard
            let data = UserDefaults.standard.data(forKey: scopeDefaultsKey),
            let scope = try? JSONDecoder().decode(FtsIndex.SearchScope.self, from: data)
        else {
            return .all
        }
        return scope
    }

    private static func saveScope(_ scope: FtsIndex.SearchScope) {
        if let data = try? JSONEncoder().encode(scope) {
            UserDefaults.standard.set(data, forKey: scopeDefaultsKey)
        }
    }

    // MARK: - Kind filter persistence

    private static let kindFilterDefaultsKey = "cpdb.popup.kindFilter"

    private static func loadKindFilter() -> Set<EntryKind> {
        // Persisted as an array of raw strings (stable across versions
        // even if we rearrange the EntryKind cases). Missing key or
        // empty list → "all kinds".
        guard let raw = UserDefaults.standard.array(forKey: kindFilterDefaultsKey) as? [String],
              !raw.isEmpty
        else {
            return Set(EntryKind.allCases)
        }
        let parsed = raw.compactMap(EntryKind.init(rawValue:))
        return parsed.isEmpty ? Set(EntryKind.allCases) : Set(parsed)
    }

    private static func saveKindFilter(_ kinds: Set<EntryKind>) {
        let raw = kinds.map(\.rawValue).sorted()
        UserDefaults.standard.set(raw, forKey: kindFilterDefaultsKey)
    }

    // MARK: - Remember-scroll-on-preview persistence

    static let rememberScrollKey = "cpdb.popup.rememberScrollOnPreview"

    private static func loadRememberScroll() -> Bool {
        // Default is false — preview-triggered dismiss matches the rest of
        // the app's "reset to top on close" model unless the user opts in.
        if UserDefaults.standard.object(forKey: rememberScrollKey) == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: rememberScrollKey)
    }

    func selectNext() {
        guard !rows.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % rows.count
    }

    func selectPrevious() {
        guard !rows.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + rows.count) % rows.count
    }

    var selectedEntry: Entry? {
        guard rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex].entry
    }

    // MARK: - Time pivot

    /// Default window index (30 min) — second entry in
    /// `timePivotWindowSeconds`. Pulled out so other defaults
    /// (e.g. iOS later) can pin the same convention.
    public static let timePivotDefaultIndex = 1

    /// Enter time-pivot mode anchored on `entry`. Saves the
    /// current search query + selection so `exitTimePivot()` can
    /// restore them. No-op when called twice (re-entering replaces
    /// the anchor rather than nesting state).
    func enterTimePivot(anchoredOn entry: Entry) {
        guard let id = entry.id else { return }
        let saved = (timePivot == nil)
            ? TimePivot(
                anchorEntryId: id,
                anchorCapturedAt: entry.capturedAt,
                windowIndex: Self.timePivotDefaultIndex,
                savedQuery: query,
                savedSelectedIndex: selectedIndex
              )
            : TimePivot(
                anchorEntryId: id,
                anchorCapturedAt: entry.capturedAt,
                windowIndex: timePivot!.windowIndex,
                // Re-entering preserves what was originally saved
                // so the user can pivot → pivot → Esc and still
                // land back at their first search.
                savedQuery: timePivot!.savedQuery,
                savedSelectedIndex: timePivot!.savedSelectedIndex
              )
        timePivot = saved
        refresh()
    }

    /// Exit time-pivot mode and restore the prior search/recent
    /// state (search query + selection). No-op when not in pivot.
    func exitTimePivot() {
        guard let saved = timePivot else { return }
        timePivot = nil
        query = saved.savedQuery
        selectedIndex = saved.savedSelectedIndex
        refresh()
    }

    /// Widen the time window (next step in `timePivotWindowSeconds`).
    /// Caps at the last index. No-op outside pivot mode.
    func widenTimePivot() {
        guard var pivot = timePivot else { return }
        let maxIdx = Self.timePivotWindowSeconds.count - 1
        guard pivot.windowIndex < maxIdx else { return }
        pivot.windowIndex += 1
        timePivot = pivot
        refresh()
    }

    /// Narrow the time window (previous step). Floored at 0.
    func narrowTimePivot() {
        guard var pivot = timePivot else { return }
        guard pivot.windowIndex > 0 else { return }
        pivot.windowIndex -= 1
        timePivot = pivot
        refresh()
    }
}
