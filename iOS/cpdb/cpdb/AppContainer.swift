#if os(iOS)
import Foundation
import Observation
import CpdbShared

/// Long-lived singleton wiring the iOS app's data layer.
///
/// Opens the shared `Store`, builds a `CloudKitSyncer`, and exposes a
/// couple of convenience methods to the views (pull-now, status). The
/// Mac app splits these responsibilities across `AppDelegate` +
/// `DaemonLifecycle`; on iOS there's no daemon, so everything lives
/// in this single container.
///
/// `@Observable` so SwiftUI views re-render when `syncReport` changes.
/// Views read the counts without holding a separate @State copy.
@Observable
@MainActor
final class AppContainer {
    private(set) var store: Store?
    private var syncer: CloudKitSyncer?

    /// Latest sync state for the progress indicator in SearchView's
    /// toolbar. Nil until the first pull completes.
    private(set) var lastPull: CloudKitSyncer.PullReport?
    private(set) var isSyncing: Bool = false
    private(set) var lastError: String?

    /// Running cumulative totals during an in-flight pull — published
    /// per page via the syncer's progress callback so SearchView can
    /// render a live counter. Nil between pulls.
    private(set) var pullProgress: CloudKitSyncer.PullReport?
    /// Wall-clock start of the current pull. Used with `pullProgress`
    /// to compute elapsed time and an overall rate.
    private(set) var pullStartedAt: Date?

    /// Called from CpdbiOSApp.task on first launch. Idempotent — if
    /// already bootstrapped, no-op.
    func bootstrap() async {
        guard store == nil else { return }
        print("[cpdb] bootstrap: starting")
        do {
            let store = try Store.open()
            self.store = store
            print("[cpdb] bootstrap: store open at \(Paths.databaseURL.path)")
            let deviceID = await Self.iosDeviceIdentifier()
            let deviceName = await Self.iosDeviceName()
            print("[cpdb] bootstrap: device id=\(deviceID) name=\(deviceName)")
            let client = LiveCloudKitClient(containerIdentifier: "iCloud.\(Paths.bundleId)")
            let syncer = CloudKitSyncer(
                store: store,
                client: client,
                device: .init(identifier: deviceID, name: deviceName)
            )
            self.syncer = syncer
            print("[cpdb] bootstrap: ensuring zone subscription…")
            try await syncer.ensureSubscription()
            print("[cpdb] bootstrap: subscription OK, pulling…")
            await pullNow()
            print("[cpdb] bootstrap: complete")
        } catch {
            lastError = "\(error)"
            Self.logError("bootstrap", error)
        }
    }

    /// Force a pull. Called on pull-to-refresh and from the toolbar.
    func pullNow() async {
        guard let syncer = syncer else { return }
        isSyncing = true
        pullStartedAt = Date()
        pullProgress = CloudKitSyncer.PullReport(
            inserted: 0, updated: 0, tombstoned: 0, skipped: 0, moreComing: true
        )
        defer {
            isSyncing = false
            pullProgress = nil
            pullStartedAt = nil
        }
        do {
            let report = try await syncer.pullRemoteChanges { [weak self] page in
                // Called after every page of the pull. Hop back to the
                // main actor to update @Observable state — the progress
                // callback closure runs on the syncer's actor context.
                Task { @MainActor in
                    self?.pullProgress = page
                }
            }
            lastPull = report
            lastError = nil
            print("[cpdb] pull: inserted=\(report.inserted) updated=\(report.updated) tombstoned=\(report.tombstoned) skipped=\(report.skipped)")
        } catch {
            lastError = "\(error)"
            Self.logError("pull", error)
        }
    }

    /// Dump a full error description to stdout so the Xcode console
    /// shows it verbatim. CloudKit errors hide their actual cause
    /// behind layered userInfo dicts — we walk the
    /// `NSUnderlyingErrorKey` chain and print every domain/code/reason
    /// we can find. Output is plain `print()` (not `os_log`) so it's
    /// easy to select + copy from the Xcode console.
    private static func logError(_ context: String, _ error: any Error) {
        print("================ [cpdb] \(context) FAILED ================")
        print("error: \(error)")
        var current: NSError = error as NSError
        var depth = 0
        while true {
            print("--- level \(depth) ---")
            print("  domain: \(current.domain)")
            print("  code:   \(current.code)")
            print("  desc:   \(current.localizedDescription)")
            if let reason = current.localizedFailureReason {
                print("  reason: \(reason)")
            }
            if let suggestion = current.localizedRecoverySuggestion {
                print("  suggestion: \(suggestion)")
            }
            if !current.userInfo.isEmpty {
                print("  userInfo keys: \(Array(current.userInfo.keys).sorted())")
                for key in current.userInfo.keys.sorted() where key != NSUnderlyingErrorKey {
                    print("    \(key) = \(String(describing: current.userInfo[key]).prefix(500))")
                }
            }
            guard let under = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = under
            depth += 1
            if depth > 6 { break }
        }
        print("==========================================================")
    }

    // MARK: - Device identity

    /// iOS's equivalent of the Mac's IOPlatformUUID. Uses
    /// UIDevice.identifierForVendor when available — stable within a
    /// vendor's apps on the same device. Falls back to a
    /// UserDefaults-stored UUID if the vendor identifier isn't
    /// available (rare).
    private static func iosDeviceIdentifier() async -> String {
        #if canImport(UIKit)
        if let id = await MainActor.run(body: { UIDevice.current.identifierForVendor?.uuidString }) {
            return id
        }
        #endif
        let key = "cpdb.ios.deviceIdentifier"
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    /// Human-readable device name. Shown on the Mac in entry detail
    /// ("captured on Paul's iPhone"). iOS 16+ restricts
    /// `UIDevice.current.name` to the app name unless you have the
    /// appropriate entitlement, so the actual device name is only
    /// available via identifierForVendor or model descriptor.
    private static func iosDeviceName() async -> String {
        #if canImport(UIKit)
        return await MainActor.run { UIDevice.current.name }
        #else
        return "iOS device"
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif
#endif
