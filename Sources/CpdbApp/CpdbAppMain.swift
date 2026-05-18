import AppKit
import Foundation
import SwiftUI

/// Entry point for `cpdb.app`.
///
/// Intentionally bare AppKit bootstrap — we don't use SwiftUI's `App`
/// protocol because a menu-bar app has no window scenes and the `App`
/// lifecycle gets in the way. `AppDelegate` owns everything.
@main
enum CpdbAppMain {
    static func main() {
        // SPM's generated `Bundle.module` accessor (this toolchain)
        // hardcodes exactly two lookup paths:
        //   1. Bundle.main.bundleURL/<name>.bundle   ← the .app ROOT
        //   2. an absolute .build/ dev path          ← dead on user machines
        // It does NOT check Contents/Resources/. codesign, conversely,
        // *forbids* any content at the .app root ("unsealed contents
        // present in the bundle root") — verified empirically, even
        // when the symlink is present at sign time. These two
        // constraints are irreconcilable, so the resource bundles
        // ship inside Contents/Resources/ (Apple-correct, sealed) and
        // we create root-level symlinks at launch to satisfy SPM's
        // hardcoded path #1.
        //
        // Honest accounting of the tradeoff (the previous comment
        // here was wrong to call it "safe"):
        //
        //   • This DOES break `codesign --verify --deep --strict`
        //     and `spctl --assess` *once the app has launched* —
        //     the symlinks are unsigned root content.
        //   • It does NOT affect the user-facing flows:
        //       - Fresh install: the notarized DMG contains the
        //         clean bundle (no symlinks). Gatekeeper assesses it
        //         at first launch and passes; it never re-assesses a
        //         launched app, so the post-launch self-symlink is
        //         invisible to it.
        //       - Sparkle update: Sparkle validates the freshly
        //         downloaded DMG (clean) and the host's Designated
        //         Requirement (team-id/identifier, which a structural
        //         root-symlink doesn't alter). Proven across
        //         consecutive hops by the release smoke test.
        //
        // Net: a real but contained defect. Removing the shim is not
        // an option (KeyboardShortcuts' Bundle.module fatalErrors if
        // its bundle is unresolvable). Documented here so the next
        // person doesn't "fix" it by deleting a load-bearing hack.
        installSPMBundleShims()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Link every `Contents/Resources/*.bundle` to the corresponding
    /// `<name>.bundle` at the .app's top level. No-op if links already
    /// exist from a previous launch.
    private static func installSPMBundleShims() {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL
        let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil) else {
            return
        }
        for url in items where url.pathExtension == "bundle" {
            let link = appURL.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: link.path) { continue }
            let target = "Contents/Resources/\(url.lastPathComponent)"
            do {
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            } catch {
                // Non-fatal: if we can't write to /Applications/, the
                // main path lookup will still fail, but that's the
                // current status quo — better to surface any other
                // error via SPM's own fatal message than crash here.
            }
        }
    }
}
