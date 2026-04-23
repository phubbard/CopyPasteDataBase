#if os(iOS)

import SwiftUI
import CpdbShared
#if canImport(UIKit)
import UIKit
#endif

/// iOS companion app entry point.
///
/// Single-scene SwiftUI app: a search view at the root, pushes a
/// detail view when you tap a row. All data comes from the local
/// SQLite store, populated by the same `CloudKitSyncer` the Mac uses.
/// This app never captures clipboard content — it's strictly a
/// search + view client of the shared CloudKit zone.
@main
struct CpdbiOSApp: App {
    /// Single source of truth for the app's data layer. Created at
    /// launch, held for the lifetime of the process. Environment-
    /// injected so views can reach into it without prop drilling.
    @State private var container = AppContainer()

    /// Scene lifecycle — we watch for .active transitions so the app
    /// pulls from iCloud every time the user returns to it. Silent
    /// push handles the instant case, BGAppRefreshTask handles the
    /// long-idle case; this one catches everything in between (quick
    /// app-switch, unlock, returning-from-share-sheet) where the
    /// other two might not have fired.
    @Environment(\.scenePhase) private var scenePhase

    /// UIKit bridge. The only reason we need an AppDelegate on an
    /// otherwise pure-SwiftUI app is APNs: silent-push delivery goes
    /// through `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`,
    /// which is UIKit-only. Keeping it minimal — just the push hooks
    /// and the registration call.
    @UIApplicationDelegateAdaptor(iOSAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            SearchView()
                .environment(container)
                .task {
                    // Kick off sync on first appearance. Safe to await
                    // inside .task — it's attached to the scene and
                    // cancelled if the scene goes away.
                    await container.bootstrap()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Pull every time the scene becomes active. Bootstrap's
            // first pull runs via .task above, so this would double-
            // fire on cold launch — cheap (GRDB + CloudKit both
            // no-op when nothing changed) but we skip it anyway by
            // gating on `container.store != nil` so it only runs
            // AFTER bootstrap has opened the DB and wired the
            // syncer. That also dodges a race where .task is still
            // resolving when scenePhase first flips to .active.
            guard phase == .active, container.store != nil else { return }
            Task { await container.pullNow() }
        }
    }
}

/// Minimal UIKit delegate wired in via `@UIApplicationDelegateAdaptor`.
/// Handles two things:
///
/// 1. **APNs registration.** We ask iOS for a device token so the
///    CKDatabaseSubscription on the Mac side can wake us when the
///    zone changes. `aps-environment=development` in
///    `cpdb.entitlements` grants the capability; no user prompt is
///    needed for silent pushes (only for user-facing alerts).
///
/// 2. **Silent push delivery.** Zone-change notifications arrive
///    here. We don't parse the CKNotification payload — any push
///    addressed to our bundle means "something changed, come look".
///    We kick `AppContainer.pullNow()` and the UI re-queries.
///
/// The container is reached via `AppContainer.shared`, a weak static
/// set during `bootstrap()`. If a silent push somehow races ahead of
/// bootstrap (unlikely — APNs tokens take a second to provision, by
/// which point the scene has run its `.task`), we log and no-op.
@MainActor
final class iOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // BGTaskScheduler identifiers must be registered BEFORE
        // `didFinishLaunching` returns, per Apple's contract. Doing
        // this later (say, from `bootstrap()`) crashes with
        // "launch handler not registered". So the handler lives on
        // AppContainer as a static.
        AppContainer.registerBackgroundTasks()
        // Silent push is a no-UI capability — safe to register
        // unconditionally without asking the user.
        application.registerForRemoteNotifications()
        return true
    }

    /// Whenever we move to the background, ask iOS for another
    /// BGAppRefreshTask slot. Required: iOS only grants the next
    /// slot if we ask — the OS never auto-renews.
    func applicationDidEnterBackground(_ application: UIApplication) {
        AppContainer.shared?.scheduleBackgroundRefresh()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[cpdb] apns: registered, token prefix=\(tokenHex.prefix(12))…")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Usually "no valid aps-environment entitlement" during
        // misconfigured builds, or simulator limitations. Log and
        // soldier on — the 5-minute periodic pull still works.
        print("[cpdb] apns: registration failed: \(error)")
    }

    /// Silent push entry point. iOS hands us a completion handler
    /// with a background-execution budget (~30 s) that we must call
    /// before it expires, or it gets stingier about waking us next
    /// time. Run the pull, then signal completion.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler:
            @escaping (UIBackgroundFetchResult) -> Void
    ) {
        print("[cpdb] apns: silent push received, pulling…")
        Task { @MainActor in
            guard let container = AppContainer.shared else {
                print("[cpdb] apns: no container yet, skipping")
                completionHandler(.noData)
                return
            }
            let before = container.lastPull?.inserted ?? 0
            await container.pullNow()
            let after = container.lastPull?.inserted ?? 0
            completionHandler(after > before ? .newData : .noData)
        }
    }
}

#else

/// Non-iOS stub so `swift build` on macOS doesn't fail linking the
/// CpdbiOS executable target. This target is only meaningful when
/// built for iOS (via xcodebuild or Xcode with an iOS destination).
/// Building it for the Mac host produces this trivial binary that
/// prints a hint and exits — nothing in the Mac app or CLI calls it.
@main
enum CpdbiOSStub {
    static func main() {
        print("CpdbiOS is an iOS-only target. Build with Xcode and an iOS destination.")
    }
}

#endif
