#if os(iOS)

import SwiftUI
import CpdbShared

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
