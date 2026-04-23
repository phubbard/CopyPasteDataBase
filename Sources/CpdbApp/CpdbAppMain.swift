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
        // Repoint SPM resource bundle lookups BEFORE anything else.
        // SPM's generated `Bundle.module` accessor looks for each
        // resource bundle at `Bundle.main.bundleURL.appendingPathComponent(name + ".bundle")`
        // — the top level of the .app. codesign refuses to seal
        // anything there, so the Makefile ships bundles inside
        // Contents/Resources/ instead. We create symlinks at the top
        // level at launch time, pointing at the real bundles.
        //
        // Why this is safe: macOS verifies the code signature at
        // process launch. Modifying non-code files inside our own
        // bundle post-launch doesn't re-trigger verification.
        // symlinks aren't in the signed seal (codesign wouldn't have
        // accepted them at sign time), so adding them now doesn't
        // invalidate anything.
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
