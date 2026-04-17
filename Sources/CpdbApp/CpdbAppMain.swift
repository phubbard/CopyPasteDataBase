import AppKit
import SwiftUI

/// Entry point for `cpdb.app`.
///
/// Intentionally bare AppKit bootstrap — we don't use SwiftUI's `App`
/// protocol because a menu-bar app has no window scenes and the `App`
/// lifecycle gets in the way. `AppDelegate` owns everything.
@main
enum CpdbAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar apps are "accessory" apps — no Dock icon, no menu bar menu
        // unless we put one there. LSUIElement in Info.plist is the canonical
        // way, but we also set this at runtime so `swift run CpdbApp` works
        // the same as launching from Finder.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
