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

    /// Highest entry id already checked by the tombstone-reconciliation
    /// sweep (see `SpotlightDonationService.reconcileTombstones`).
    /// Bounds that query the same way `highWaterMarkId` bounds donation.
    private static let reconciledTombstoneKey = "cpdb.spotlight.reconciledTombstoneId"
    static var reconciledTombstoneId: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: reconciledTombstoneKey)) }
        set { UserDefaults.standard.set(newValue, forKey: reconciledTombstoneKey) }
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
    private var tombstoneObserver: NSObjectProtocol?

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
            Task { @MainActor [weak self] in
                await self?.donatePendingIfEnabled()
                await self?.reconcileTombstones()
            }
        }
        // Immediate removal/re-donation for user-initiated deletes,
        // undo, and redo (all funnel through `EntryRepository.tombstone`/
        // `.restore`) — don't leave a just-deleted clip searchable until
        // the next capture-driven pass happens to run.
        tombstoneObserver = NotificationCenter.default.addObserver(
            forName: .cpdbEntryTombstoneChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["entryId"] as? Int64,
                  let deleted = note.userInfo?["deleted"] as? Bool
            else { return }
            Task { @MainActor [weak self] in await self?.handleTombstoneChange(entryId: id, deleted: deleted) }
        }
        Task {
            await donatePendingIfEnabled()
            await reconcileTombstones()
        }
    }

    /// Preferences toggle handler. Turning on kicks off an immediate
    /// catch-up pass over existing history; turning off removes every
    /// donated item and resets the high-water mark, so a later re-
    /// enable starts clean instead of silently skipping everything
    /// captured before the toggle flipped back on.
    func setEnabled(_ enabled: Bool) {
        SpotlightPrefs.enabled = enabled
        if enabled {
            Task {
                await donatePendingIfEnabled()
                await reconcileTombstones()
            }
        } else {
            Task { await undonateAll() }
        }
    }

    /// Reacts to `.cpdbEntryTombstoneChanged` — removes a just-deleted
    /// entry's donated item immediately, or re-donates it if the
    /// delete was undone (a no-op unless the current text/preview still
    /// maps to a payload; `donatePendingIfEnabled`'s next pass would
    /// otherwise skip it forever since its id is already below the
    /// high-water mark).
    private func handleTombstoneChange(entryId: Int64, deleted: Bool) async {
        guard SpotlightPrefs.enabled else { return }
        let identifier = "\(Self.uniqueIdPrefix)\(entryId)"
        do {
            if deleted {
                try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [identifier])
            } else if let store, let entry = try? EntryRepository(store: store).fetch(id: entryId),
                      let payload = Self.payload(for: EntryRepository.EntryRow(entry: entry)) {
                try await CSSearchableIndex.default().indexSearchableItems([Self.searchableItem(for: payload)])
            }
        } catch {
            Log.cli.error("spotlight tombstone-change sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Catches donated items whose entry was tombstoned by a path other
    /// than `EntryRepository.tombstone(id:)` — chiefly a CloudKit pull
    /// applying a sibling device's delete via a raw SQL write, which
    /// `.cpdbEntryTombstoneChanged` never sees. Piggybacks on the same
    /// triggers as `donatePendingIfEnabled` (capture-wake notification,
    /// enable toggle, app launch) rather than its own timer.
    func reconcileTombstones() async {
        guard SpotlightPrefs.enabled, let store else { return }
        let repo = EntryRepository(store: store)
        let since = SpotlightPrefs.reconciledTombstoneId
        guard let ids = try? repo.tombstonedIds(sinceId: since, kinds: [.text, .link], limit: 500),
              !ids.isEmpty
        else { return }
        let identifiers = ids.map { "\(Self.uniqueIdPrefix)\($0)" }
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers)
            SpotlightPrefs.reconciledTombstoneId = max(since, ids.max() ?? since)
            Log.cli.info("spotlight: reconciled \(identifiers.count, privacy: .public) tombstoned item(s)")
        } catch {
            Log.cli.error("spotlight reconciliation failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Caps how many `-emit-const-values`-sized pages (`pageSize` each)
    /// a single call walks. A years-old imported archive can be tens
    /// of thousands of rows; without a cap, the very first
    /// capture-triggered call after enabling the preference would
    /// block on indexing the entire thing in one synchronous sweep.
    /// Capping just means catch-up spans a few more trigger firings
    /// (captures happen often) rather than fewer, larger ones — the
    /// high-water mark still advances every page, so no progress is
    /// lost between calls.
    private static let maxPagesPerCall = 10
    private static let pageSize = 200

    /// Donate any live text/link entries newer than the high-water
    /// mark, oldest-first, paging until caught up (or `maxPagesPerCall`
    /// is hit). Ascending id order rather than `recent`'s pinned/
    /// newest-first — pin status has nothing to do with "worth
    /// finding in Spotlight", and letting it reorder this walk is what
    /// let pinned entries crowd unpinned ones out of a fixed-size
    /// window before this paged. No-ops (cheaply) when the preference
    /// is off or nothing is new.
    func donatePendingIfEnabled() async {
        guard SpotlightPrefs.enabled, let store else { return }
        let repo = EntryRepository(store: store)
        var highWater = SpotlightPrefs.highWaterMarkId
        var totalDonated = 0
        do {
            for _ in 0..<Self.maxPagesPerCall {
                let pending = try repo.liveEntries(sinceId: highWater, kinds: [.text, .link], limit: Self.pageSize)
                guard !pending.isEmpty else { break }
                let items = pending.compactMap(Self.payload(for:)).map(Self.searchableItem(for:))
                try await CSSearchableIndex.default().indexSearchableItems(items)
                highWater = pending.compactMap(\.entry.id).max() ?? highWater
                SpotlightPrefs.highWaterMarkId = highWater
                totalDonated += items.count
                guard pending.count == Self.pageSize else { break }
            }
            if totalDonated > 0 {
                Log.cli.info("spotlight: donated \(totalDonated, privacy: .public) item(s)")
            }
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
            SpotlightPrefs.reconciledTombstoneId = 0
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
