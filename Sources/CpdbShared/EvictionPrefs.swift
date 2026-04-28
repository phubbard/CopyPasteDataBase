import Foundation

/// User preferences for tier-2 eviction policies.
///
/// Two independent policies, both defaulting OFF — the user opts in
/// per their library's needs:
///
///   - **Time-window** (v2.6.2): "discard bodies older than N days."
///     Predictable, calendar-time mental model.
///   - **Size-budget** (v2.6.3): "keep total under N GB; evict LRU
///     when over." Self-balancing, capped.
///
/// Both policies:
///   - Operate only on flavor body bytes (entry_flavors + on-disk
///     blobs). Metadata + thumbnails are forever.
///   - Skip pinned and tombstoned rows.
///   - Mark evicted entries with `body_evicted_at` so siblings'
///     CloudKit pulls don't re-hydrate the bytes.
public enum EvictionPrefs {

    // MARK: - Time-window policy

    public static let timeWindowEnabledKey = "cpdb.eviction.timeWindow.enabled"
    public static let timeWindowDaysKey    = "cpdb.eviction.timeWindow.days"

    public static let timeWindowDaysDefault = 90
    public static let timeWindowDaysMin     = 7
    public static let timeWindowDaysMax     = 3650   // ~10 years

    public static var timeWindowEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: timeWindowEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: timeWindowEnabledKey) }
    }

    /// Clamped to the [min, max] range so a malformed plist edit
    /// can't poison the eviction loop.
    public static var timeWindowDays: Int {
        get {
            let raw = UserDefaults.standard.object(forKey: timeWindowDaysKey) as? Int
                ?? timeWindowDaysDefault
            return max(timeWindowDaysMin, min(timeWindowDaysMax, raw))
        }
        set {
            UserDefaults.standard.set(
                max(timeWindowDaysMin, min(timeWindowDaysMax, newValue)),
                forKey: timeWindowDaysKey
            )
        }
    }

    // MARK: - Last-run bookkeeping

    /// The daemon runs the time-window policy once per day. Wall-
    /// clock timestamp of the last successful run, used to skip
    /// repeat work within the same day.
    public static let timeWindowLastRunKey = "cpdb.eviction.timeWindow.lastRunAt"

    public static var timeWindowLastRunAt: Date? {
        get {
            let raw = UserDefaults.standard.double(forKey: timeWindowLastRunKey)
            return raw == 0 ? nil : Date(timeIntervalSince1970: raw)
        }
        set {
            UserDefaults.standard.set(
                newValue?.timeIntervalSince1970 ?? 0,
                forKey: timeWindowLastRunKey
            )
        }
    }
}
