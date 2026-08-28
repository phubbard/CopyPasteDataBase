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

    /// Whether the semantic (embedding cosine-similarity) re-rank pass
    /// runs alongside FTS search. Persisted like `searchScope`. Toggling
    /// it re-runs the current search so switching it off snaps back to
    /// pure-FTS ordering immediately rather than waiting for the next
    /// keystroke.
    var semanticSearchEnabled: Bool = PopupState.loadSemanticSearchEnabled() {
        didSet {
            if semanticSearchEnabled != oldValue {
                PopupState.saveSemanticSearchEnabled(semanticSearchEnabled)
                refresh()
            }
        }
    }

    /// Whether `EmbeddingService` actually has a usable model on this
    /// machine — checked once, asynchronously, at init. The popup's
    /// "Semantic" chip only renders when this is true; there's no point
    /// offering a toggle for a re-rank pass that can never do anything.
    private(set) var semanticAvailable: Bool = false

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

    /// Bumped only when a live-update observation (see
    /// `startLiveUpdates`) actually triggers a `refresh()` — i.e. when
    /// something wrote to `entries` or `previews` while the popup was
    /// open. `ImageCard`/`LinkCard` fold this into their `.task(id:)`
    /// key alongside `entry.id` so a thumbnail that lands *after* a
    /// card first renders (e.g. the link-metadata backfiller writing
    /// `previews` a few hundred ms into the summon) gets picked up —
    /// `entry.id` alone never changes for an existing row, so without
    /// this the card's `.task` would never re-run and the placeholder
    /// would stick around indefinitely. NOT bumped by query/filter-
    /// driven `refresh()` calls, so typing in the search field doesn't
    /// re-trigger already-loaded thumbnails.
    private(set) var liveRefreshToken: Int = 0

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

    /// Undo/redo for delete + pin. Shared logic in CpdbShared; the popup
    /// drives it via `delete`/`togglePin`/`performUndo`/`performRedo` and
    /// surfaces `undoHint`.
    let undo: UndoCoordinator

    /// Transient one-line status hint after an undoable action ("Deleted ·
    /// ⌘Z to undo"). Auto-clears; rendered in the popup header.
    var undoHint: String?
    private var undoHintToken = 0

    init(store: Store, recentLimit: Int = 200) {
        self.store = store
        self.repository = EntryRepository(store: store)
        self.undo = UndoCoordinator(repo: EntryRepository(store: store))
        self.searchLimit = recentLimit

        // One-time async probe: does this machine have a usable
        // embedding model? Gates whether the "Semantic" chip renders at
        // all. Cheap once cached — `EmbeddingService.isAvailable()`
        // memoizes its verdict process-wide.
        Task { @MainActor [weak self] in
            let available = await EmbeddingService.isAvailable()
            self?.semanticAvailable = available
        }
    }

    // MARK: - Undoable mutations (popup entry points)

    /// Delete an entry (tombstone) with undo recorded. Refreshes the strip.
    func delete(id: Int64) {
        do {
            let d = try undo.delete(id: id)
            flashHint("\(d.pastTense) · ⌘Z to undo")
        } catch {
            Log.cli.error("delete failed id=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    /// Toggle pin with undo recorded.
    func togglePin(id: Int64, currentlyPinned: Bool) {
        do {
            if let d = try undo.setPinned(id: id, pinned: !currentlyPinned) {
                flashHint("\(d.pastTense) · ⌘Z to undo")
            }
        } catch {
            Log.cli.error("pin toggle failed id=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    func performUndo() {
        do {
            if let d = try undo.undo() {
                flashHint("\(d.pastTense)\(undo.canRedo ? " · ⌘⇧Z to redo" : "")")
            }
        } catch {
            Log.cli.error("undo failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    func performRedo() {
        do {
            if let d = try undo.redo() {
                flashHint("\(d.pastTense)\(undo.canUndo ? " · ⌘Z to undo" : "")")
            }
        } catch {
            Log.cli.error("redo failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    private func flashHint(_ message: String) {
        undoHint = message
        undoHintToken += 1
        let token = undoHintToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if undoHintToken == token { undoHint = nil }
        }
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
                // Only reassign when content actually changed. A no-op
                // reassignment is not free under the LazyHStack: swapping
                // `rows` mid-materialization (e.g. the live-observation's
                // first post-summon delivery re-running an identical
                // fetch) makes the lazy diff repaint items at estimated
                // offsets — ghost text fragments and blank cards
                // (v3.2.2 regression).
                if rows != fetched { rows = fetched }
                if !snippetsById.isEmpty { snippetsById = [:] }
                if !matchSourcesById.isEmpty { matchSourcesById = [:] }
            } else {
                let results = try repository.search(
                    query: q,
                    scope: searchScope,
                    kinds: kindFilter,
                    limit: searchLimit
                )
                guard gen == generation else { return }
                let newRows = results.map(\.row)
                let newSnippets = Dictionary(
                    uniqueKeysWithValues: results.map { ($0.row.entry.id!, $0.snippet) }
                )
                let newSources = Dictionary(
                    uniqueKeysWithValues: results.map { ($0.row.entry.id!, $0.source) }
                )
                if rows != newRows { rows = newRows }
                if snippetsById != newSnippets { snippetsById = newSnippets }
                if matchSourcesById != newSources { matchSourcesById = newSources }

                // Semantic re-rank runs as a second pass, not inline here:
                // embedding the query is a few-millisecond model call we
                // don't want blocking the summon-time refresh above. It
                // lands as a follow-up `rows` update ONLY if merging in
                // cosine-similarity rank actually changes the result —
                // the `rows != newRows` guard inside `spawnSemanticRerank`
                // reuses the same no-op-skip discipline as everywhere
                // else in this file, so a query with no semantic lift
                // doesn't churn the strip a second time.
                if semanticAvailable, semanticSearchEnabled {
                    spawnSemanticRerank(query: q, generation: gen, ftsHits: results)
                }
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

    /// Reciprocal-rank-fusion constant. 60 is the standard RRF default
    /// from the literature (Cormack et al.) — large enough that a rank
    /// near the bottom of either list still contributes a little, small
    /// enough that a #1 rank in one list clearly outweighs a mid-pack
    /// rank in the other.
    nonisolated static let rrfK = 60.0

    /// Cap on how many nearest neighbors `EmbeddingIndex.search` returns
    /// for a re-rank pass. Deliberately smaller than `searchLimit` (the
    /// FTS/"recent" page size): a re-rank only ever needs a modest
    /// number of genuinely-similar candidates to fuse in, and asking for
    /// as many neighbors as the whole popup page (`searchLimit`) forces
    /// `EmbeddingIndex` to score and return matches far down its ranked
    /// list — which `semanticScoreFloor` below would filter out anyway,
    /// so there's no point paying to rank and hydrate them.
    nonisolated static let semanticTopK = 50

    /// Minimum cosine similarity (`EmbeddingIndex.Result.score`, range
    /// [-1, 1]) for a semantic hit to be treated as an actual match
    /// rather than noise. `EmbeddingIndex.search` returns its top-K by
    /// rank regardless of how weak the best available match is — a
    /// typo/garbage query with zero real semantic signal still returns
    /// up to top-K entries at whatever (possibly near-zero) similarity
    /// happens to lead the pack. Without a floor those get fused in and
    /// shown with the same ≈ badge as a genuine paraphrase match. 0.35 is
    /// a conservative starting point pending real calibration against
    /// `NLContextualEmbedding`'s actual similarity distribution — the
    /// goal is "clearly related," not a precise threshold.
    nonisolated static let semanticScoreFloor: Float = 0.35

    /// Merge two ranked id lists (FTS bm25 order, embedding cosine order)
    /// by Reciprocal Rank Fusion: each list contributes `1/(k+rank)`
    /// (rank is 1-based) for every id it contains, an id in both lists
    /// sums both contributions, and the union is sorted by that score
    /// descending. A tie breaks on id (descending — newer/higher-id
    /// first) purely so the result is deterministic rather than at the
    /// mercy of `Dictionary`'s iteration order.
    ///
    /// Pure and static so it's unit-testable without a loaded embedding
    /// model, a `Store`, or the `@MainActor` hop `spawnSemanticRerank`
    /// needs for everything else it does.
    nonisolated static func fuseByReciprocalRank(
        _ ftsIds: [Int64],
        _ semanticIds: [Int64],
        k: Double = rrfK
    ) -> [Int64] {
        var fused: [Int64: Double] = [:]
        for (index, id) in ftsIds.enumerated() {
            fused[id, default: 0] += 1.0 / (k + Double(index + 1))
        }
        for (index, id) in semanticIds.enumerated() {
            fused[id, default: 0] += 1.0 / (k + Double(index + 1))
        }
        return fused.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value > rhs.value
        }.map(\.key)
    }

    /// Second-pass semantic re-rank for the current search. Embeds `q`,
    /// runs it against `EmbeddingIndex`, fuses that ranking with the FTS
    /// ranking already on screen via Reciprocal Rank Fusion, and — only
    /// if the fused order actually differs from what's showing — swaps
    /// `rows` to the merged result. Fire-and-forget: `refresh()` has
    /// already returned with FTS-only results by the time this runs.
    private func spawnSemanticRerank(query: String, generation: Int, ftsHits: [EntryRepository.SearchHit]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let queryVector = await EmbeddingService.embed(text: query) else { return }
            let semanticHits: [EmbeddingIndex.Result]
            do {
                let rawHits = try await EmbeddingIndex.shared.search(
                    queryVector: queryVector,
                    topK: Self.semanticTopK,
                    store: self.store
                )
                // Drop weak matches before they ever reach RRF fusion —
                // see `semanticScoreFloor`'s doc comment. A query with no
                // real semantic signal should fuse in nothing, not the
                // whole top-K by rank regardless of how unrelated it is.
                semanticHits = rawHits.filter { $0.score >= Self.semanticScoreFloor }
            } catch {
                Log.cli.error("semantic re-rank search failed: \(String(describing: error), privacy: .public)")
                return
            }
            guard !semanticHits.isEmpty else { return }
            // Stale by the time the embed/search round-trip finished
            // (query changed, popup dismissed and re-summoned, etc) —
            // don't clobber whatever `refresh()` has moved on to.
            guard generation == self.generation else { return }

            let ftsIds = ftsHits.compactMap(\.row.entry.id)
            let semanticIds = semanticHits.map(\.entryId)
            let orderedIds = Self.fuseByReciprocalRank(ftsIds, semanticIds)
            guard !orderedIds.isEmpty else { return }

            let existingById = Dictionary(
                uniqueKeysWithValues: ftsHits.compactMap { hit -> (Int64, EntryRepository.SearchHit)? in
                    guard let id = hit.row.entry.id else { return nil }
                    return (id, hit)
                }
            )
            // Hydrate only the entries the FTS pass didn't already
            // return a row for — a paraphrase with no literal overlap
            // that the embedding index still ranked highly.
            let missingIds = orderedIds.filter { existingById[$0] == nil }
            var hydrated: [Int64: EntryRepository.EntryRow] = [:]
            if !missingIds.isEmpty {
                do {
                    let fetched = try self.repository.rows(ids: missingIds, kinds: self.kindFilter)
                    for row in fetched {
                        if let id = row.entry.id { hydrated[id] = row }
                    }
                } catch {
                    Log.cli.error("semantic re-rank hydrate failed: \(String(describing: error), privacy: .public)")
                    return
                }
            }

            var mergedRows: [EntryRepository.EntryRow] = []
            let mergedSnippets = self.snippetsById
            var mergedSources = self.matchSourcesById
            mergedRows.reserveCapacity(min(orderedIds.count, self.searchLimit))
            for id in orderedIds {
                if mergedRows.count >= self.searchLimit { break }
                if let hit = existingById[id] {
                    mergedRows.append(hit.row)
                    // Snippet/source already populated from the FTS pass.
                } else if let row = hydrated[id] {
                    mergedRows.append(row)
                    mergedSources[id] = .semantic
                }
            }

            guard generation == self.generation else { return }
            // Only reassign when the fused order actually differs from
            // what's on screen — same no-op-skip discipline as the rest
            // of `refresh()`, so a query with no semantic lift over pure
            // FTS never touches the LazyHStack a second time.
            if self.rows != mergedRows {
                // This reorder lands asynchronously, possibly after the
                // user has already arrowed to a selection on the FTS-only
                // rows that were showing. Follow that same entry to its
                // new position (by id) rather than keeping the old
                // numeric index, which would silently re-point the
                // highlight — and a subsequent Return — at whatever
                // entry the fused order now puts there instead.
                let selectedId = self.rows.indices.contains(self.selectedIndex)
                    ? self.rows[self.selectedIndex].entry.id
                    : nil
                self.rows = mergedRows
                self.snippetsById = mergedSnippets
                self.matchSourcesById = mergedSources
                if let selectedId, let newIndex = self.rows.firstIndex(where: { $0.entry.id == selectedId }) {
                    self.selectedIndex = newIndex
                } else {
                    self.selectedIndex = self.rows.isEmpty ? 0 : min(self.selectedIndex, self.rows.count - 1)
                }
            }
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
    private var skipNextLiveDelivery = false

    func startLiveUpdates() {
        guard liveObservation == nil else { return }
        skipNextLiveDelivery = true
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
        // .async(onQueue: .main) rather than .immediate: with .immediate,
        // starting the observation runs the 5 aggregate queries above
        // synchronously on the caller (measured ~250ms for rows=200) before
        // the popup is ever shown. Nothing consumes the first value ahead
        // of show() — `refresh()` already populated `rows` moments earlier
        // — so async delivery costs nothing but a debounced re-refresh
        // shortly after first paint (see `scheduleLiveRefresh`), which
        // re-reads the now-identical state and is not visible.
        liveObservation = observation.start(
            in: store.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { error in
                Log.cli.error("popup live updates errored: \(String(describing: error), privacy: .public)")
            },
            onChange: { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    // The async observation's first delivery reflects the
                    // state refresh() just read synchronously — refreshing
                    // again is churn (and churn glitches the lazy strip).
                    if self.skipNextLiveDelivery {
                        self.skipNextLiveDelivery = false
                        return
                    }
                    self.scheduleLiveRefresh()
                }
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
            self.liveRefreshToken &+= 1
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

    // MARK: - Semantic search toggle persistence

    private static let semanticSearchEnabledDefaultsKey = "cpdb.popup.semanticSearchEnabled"

    private static func loadSemanticSearchEnabled() -> Bool {
        // Default true: leaving it on costs nothing when
        // `EmbeddingService` reports unavailable (the re-rank pass never
        // even starts — see `semanticAvailable`), and finding paraphrased
        // matches by default is the whole point of shipping this.
        if UserDefaults.standard.object(forKey: semanticSearchEnabledDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: semanticSearchEnabledDefaultsKey)
    }

    private static func saveSemanticSearchEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: semanticSearchEnabledDefaultsKey)
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
