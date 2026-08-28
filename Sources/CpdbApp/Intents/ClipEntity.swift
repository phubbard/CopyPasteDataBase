#if os(macOS)
import AppIntents
import CoreSpotlight
import CpdbShared

/// `AppEntity.ID` must be `EntityIdentifierConvertible`; the framework
/// ships conformances for `String`/`Int`/`UUID` but not `Int64`, which
/// is what GRDB gives us for a row id. `@retroactive` acknowledges
/// we're conforming a type we don't own to a protocol we don't own —
/// safe here since nothing else in the app (or, plausibly, in
/// AppIntents itself, given the identifier is just a round-tripped
/// string) will ever add a conflicting conformance.
extension Int64: @retroactive EntityIdentifierConvertible {
    public var entityIdentifierString: String { String(self) }
    public static func entityIdentifier(for entityIdentifierString: String) -> Int64? {
        Int64(entityIdentifierString)
    }
}

/// Shortcuts/Siri-facing representation of one clipboard entry.
/// Intentionally a small value snapshot (id + two display strings)
/// rather than holding the full `Entry`/`EntryRow` — Shortcuts persists
/// entities across runs, and we don't want stale flavor bytes or a
/// `Store` reference living in that cache.
struct ClipEntity: AppEntity {
    let id: Int64
    let titleText: String
    let subtitleText: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Clip"
    static var defaultQuery = ClipEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(titleText)", subtitle: "\(subtitleText)")
    }

    init(id: Int64, titleText: String, subtitleText: String) {
        self.id = id
        self.titleText = titleText
        self.subtitleText = subtitleText
    }

    /// Convenience for building from a repository row (has `appName`
    /// for the subtitle). Returns nil for a row with no persisted id
    /// (shouldn't happen for a fetched row, but `Entry.id` is
    /// Optional).
    init?(row: EntryRepository.EntryRow) {
        guard let id = row.entry.id else { return nil }
        self.init(
            id: id,
            titleText: ClipIntentSupport.displayTitle(for: row.entry),
            subtitleText: ClipIntentSupport.subtitle(for: row)
        )
    }
}

/// Backs `ClipEntity.defaultQuery`. Both `entities(for:)` (Shortcuts
/// resolving a previously-picked/donated entity by id) and
/// `suggestedEntities()` (the picker's default list) go through
/// `AppReadiness` so a query fired before the store is open degrades to
/// "no results" instead of crashing.
struct ClipEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [Int64]) async throws -> [ClipEntity] {
        guard let store = await AppReadiness.shared.waitForStore() else { return [] }
        let repo = EntryRepository(store: store)
        return identifiers.compactMap { id -> ClipEntity? in
            guard let entry = try? repo.fetch(id: id) else { return nil }
            return ClipEntity(
                id: id,
                titleText: ClipIntentSupport.displayTitle(for: entry),
                // `fetch(id:)` returns a bare `Entry`, no joined app
                // name — the suggested-entities path (which does have
                // it via `EntryRow`) is the common case; a
                // by-id resolve just omits the app name.
                subtitleText: ClipIntentSupport.subtitle(for: EntryRepository.EntryRow(entry: entry))
            )
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [ClipEntity] {
        guard let store = await AppReadiness.shared.waitForStore() else { return [] }
        let rows = (try? ClipIntentSupport.recentEntries(store: store, limit: 10)) ?? []
        return rows.compactMap(ClipEntity.init(row:))
    }
}

/// Makes `ClipEntity` donatable straight into Spotlight's index (System
/// Search suggests it, deep-links back into the intent). Straightforward
/// at macOS 15+ SDKs — just an attribute-set projection of the two
/// display strings we already have; no extra store round-trip needed.
/// Gated behind `#available` since `IndexedEntity` itself is macOS
/// 15+/iOS 18+ despite the package's macOS 14 floor.
@available(macOS 15.0, *)
extension ClipEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = titleText
        attrs.contentDescription = subtitleText
        return attrs
    }
}
#endif
