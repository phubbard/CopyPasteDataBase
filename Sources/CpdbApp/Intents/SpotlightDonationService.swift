#if os(macOS)
import Foundation
import CoreSpotlight
import CpdbShared

/// UserDefaults-backed prefs for the Spotlight donation feature.
/// Default OFF — clipboard contents can be sensitive, so donating
/// them into system-wide search is opt-in only (Preferences ›
/// "Show clips in Spotlight").
enum SpotlightPrefs {
    static let enabledKey = "cpdb.spotlight.enabled"
    private static let highWaterMarkKey = "cpdb.spotlight.highWaterMarkId"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Highest entry id already donated. A cheap, migration-free stand-
    /// in for a per-row "donated" flag (this branch may not add schema
    /// columns) — entries are inserted with ever-increasing rowids, so
    /// "id > high-water mark" is exactly "donated since last pass" for
    /// the `.inserted` case. A `.bumped` re-capture of already-donated
    /// content is a rare miss (title/preview essentially unchanged) and
    /// self-heals next time the surrounding text does change and lands
    /// as a fresh row.
    static var highWaterMarkId: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: highWaterMarkKey)) }
        set { UserDefaults.standard.set(newValue, forKey: highWaterMarkKey) }
    }
}

/// One donated Spotlight item, decoupled from `CSSearchableItem` so
/// the mapping from an `EntryRow` can be unit-tested without touching
/// a real `CSSearchableIndex`.
struct SpotlightDonationPayload: Equatable {
    let entryId: Int64
    let title: String
    let contentText: String
    let date: Date
    let deepLink: URL?
}

/// Donates text/link entries into Spotlight (System Search) so they
/// surface alongside Finder/Mail/etc results, domain "clips". Opt-in
/// via `SpotlightPrefs.enabled`.
///
/// Batches on `.cpdbLocalEntryIngested` — the same notification
/// `AppDelegate` already wakes the CloudKit push loop and the link/
/// image backfill sweeps on — rather than donating synchronously
/// inside the capture path. Progress is tracked with a high-water-mark
/// id (see `SpotlightPrefs`) instead of a persisted per-row flag, since
/// this branch isn't adding schema columns.
@MainActor
final class SpotlightDonationService {
    static let shared = SpotlightDonationService()
    // `nonisolated`: plain `String` constants, referenced from the
    // `nonisolated` pure builders below and from tests — isolating
    // them to `MainActor` (the class's default) would force every
    // caller through an actor hop for no reason.
    nonisolated static let domainIdentifier = "clips"
    private nonisolated static let uniqueIdPrefix = "clip-"

    private var store: Store?
    private var observer: NSObjectProtocol?

    private init() {}

    /// Call once from `AppDelegate`, after the store is ready. Installs
    /// the capture-wake observer regardless of the current preference
    /// (so flipping the toggle on later doesn't need a relaunch) and
    /// runs one catch-up pass immediately.
    func start(store: Store) {
        self.store = store
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .cpdbLocalEntryIngested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.donatePendingIfEnabled() }
        }
        Task { await donatePendingIfEnabled() }
    }

    /// Preferences toggle handler. Turning on kicks off an immediate
    /// catch-up pass over existing history; turning off removes every
    /// donated item and resets the high-water mark, so a later re-
    /// enable starts clean instead of silently skipping everything
    /// captured before the toggle flipped back on.
    func setEnabled(_ enabled: Bool) {
        SpotlightPrefs.enabled = enabled
        if enabled {
            Task { await donatePendingIfEnabled() }
        } else {
            Task { await undonateAll() }
        }
    }

    /// Donate any text/link entries newer than the high-water mark.
    /// No-ops (cheaply) when the preference is off or nothing is new.
    func donatePendingIfEnabled() async {
        guard SpotlightPrefs.enabled, let store else { return }
        let repo = EntryRepository(store: store)
        let highWater = SpotlightPrefs.highWaterMarkId
        guard let rows = try? repo.recent(limit: 200, kinds: [.text, .link]) else { return }
        let pending = rows.filter { ($0.entry.id ?? 0) > highWater }
        guard !pending.isEmpty else { return }
        let items = pending.compactMap(Self.payload(for:)).map(Self.searchableItem(for:))
        do {
            try await CSSearchableIndex.default().indexSearchableItems(items)
            if let maxId = pending.compactMap(\.entry.id).max() {
                SpotlightPrefs.highWaterMarkId = max(highWater, maxId)
            }
            Log.cli.info("spotlight: donated \(items.count, privacy: .public) item(s)")
        } catch {
            Log.cli.error("spotlight donation failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Remove every item cpdb has donated (domain "clips") and reset
    /// the high-water mark. Called when the user turns the preference
    /// off.
    func undonateAll() async {
        do {
            try await CSSearchableIndex.default()
                .deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier])
            SpotlightPrefs.highWaterMarkId = 0
            Log.cli.info("spotlight: cleared all donated items")
        } catch {
            Log.cli.error("spotlight un-donate failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Recovers the entry id from a donated item's
    /// `uniqueIdentifier`, for the `CSSearchableItemActionType`
    /// continuation path in `AppDelegate`. `nonisolated` — pure string
    /// parsing, no actor-isolated state — so it's callable (and
    /// testable) without a `MainActor` hop.
    nonisolated static func entryId(fromUniqueIdentifier id: String) -> Int64? {
        guard id.hasPrefix(uniqueIdPrefix) else { return nil }
        return Int64(id.dropFirst(uniqueIdPrefix.count))
    }

    // MARK: - Pure builders (testable seam — no CSSearchableIndex involved)
    //
    // `nonisolated`: these touch no actor-isolated state (just the
    // `EntryRow`/`SpotlightDonationPayload` arguments and the
    // `uniqueIdPrefix`/`domainIdentifier` constants), so they're
    // callable synchronously from anywhere, including the unit tests
    // that exercise this mapping without a real `CSSearchableIndex`.

    nonisolated static func payload(for row: EntryRepository.EntryRow) -> SpotlightDonationPayload? {
        guard let id = row.entry.id else { return nil }
        return SpotlightDonationPayload(
            entryId: id,
            title: ClipIntentSupport.displayTitle(for: row.entry, maxLength: 80),
            contentText: row.entry.textPreview ?? row.entry.title ?? "",
            date: Date(timeIntervalSince1970: row.entry.capturedAt),
            deepLink: ClipDeepLink.url(forEntryId: id)
        )
    }

    nonisolated static func searchableItem(for payload: SpotlightDonationPayload) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = payload.title
        attrs.contentDescription = payload.contentText
        attrs.contentCreationDate = payload.date
        // Non-file contentURL: tapping the result in System Search
        // opens this URL, which our `CFBundleURLTypes` registration
        // routes to `AppDelegate.application(_:open:)` →
        // `PopupController.showAndSelect(entryId:)`.
        attrs.contentURL = payload.deepLink
        let item = CSSearchableItem(
            uniqueIdentifier: "\(uniqueIdPrefix)\(payload.entryId)",
            domainIdentifier: Self.domainIdentifier,
            attributeSet: attrs
        )
        item.expirationDate = .distantFuture
        return item
    }
}
#endif
