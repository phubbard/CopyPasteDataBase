import Foundation
import Observation
import CpdbCore

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
    private(set) var totalLive: Int = 0
    private(set) var isSearching: Bool = false

    /// What the user is typing in the search field. Empty = "most recent".
    var query: String = "" {
        didSet { if query != oldValue { refresh() } }
    }

    /// Highlight/selection index within `rows`. Clamped to valid range.
    var selectedIndex: Int = 0

    /// Lifecycle banner. Set by `DaemonLifecycle` via the AppDelegate.
    var captureMode: CaptureMode = .capturing

    enum CaptureMode: Equatable {
        case capturing
        case readOnly(holder: String)
    }

    let store: Store
    private let repository: EntryRepository
    private let recentLimit: Int
    /// Monotonic token so stale async results don't overwrite newer ones.
    private var generation: Int = 0

    init(store: Store, recentLimit: Int = 200) {
        self.store = store
        self.repository = EntryRepository(store: store)
        self.recentLimit = recentLimit
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
        isSearching = !q.isEmpty
        do {
            if q.isEmpty {
                let fetched = try repository.recent(limit: recentLimit)
                guard gen == generation else { return }
                rows = fetched
                snippetsById = [:]
            } else {
                let results = try repository.search(query: q, limit: recentLimit)
                guard gen == generation else { return }
                rows = results.map(\.row)
                snippetsById = Dictionary(uniqueKeysWithValues: results.map { ($0.row.entry.id!, $0.snippet) })
            }
            selectedIndex = rows.isEmpty ? 0 : min(selectedIndex, rows.count - 1)
        } catch {
            Log.cli.error("popup refresh failed: \(String(describing: error), privacy: .public)")
            rows = []
            snippetsById = [:]
            selectedIndex = 0
        }
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
}
