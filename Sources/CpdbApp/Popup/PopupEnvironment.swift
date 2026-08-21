import SwiftUI
import CpdbShared

/// Threads the popup's `Store` handle down through the SwiftUI environment
/// so per-card views (`ImageCard`, `LinkCard`) can read thumbnails without
/// each opening their own `DatabaseQueue` via `Store.open()` on every
/// render. Set once in `PopupController.configure` where `PopupRootView`
/// is instantiated; `PopupState` already owns the canonical `Store`, this
/// just makes it reachable from views that don't hold `PopupState`
/// directly.
private struct CpdbStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: Store? = nil
}

extension EnvironmentValues {
    var cpdbStore: Store? {
        get { self[CpdbStoreEnvironmentKey.self] }
        set { self[CpdbStoreEnvironmentKey.self] = newValue }
    }
}

/// Mirrors `PopupState.liveRefreshToken` into the environment so
/// `ImageCard`/`LinkCard` — which only receive their `EntryRepository.EntryRow`,
/// not the `PopupState` itself — can fold it into their `.task(id:)` key
/// and pick up thumbnails that arrive after a card's first render. Set
/// once per body evaluation in `PopupRootView` (which already holds
/// `state`).
private struct PopupLiveRefreshTokenEnvironmentKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    var popupLiveRefreshToken: Int {
        get { self[PopupLiveRefreshTokenEnvironmentKey.self] }
        set { self[PopupLiveRefreshTokenEnvironmentKey.self] = newValue }
    }
}
