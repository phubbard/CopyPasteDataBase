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

    /// Called from CpdbiOSApp.task on first launch. Idempotent — if
    /// already bootstrapped, no-op.
    func bootstrap() async {
        guard store == nil else { return }
        do {
            let store = try Store.open()
            self.store = store
            let deviceID = await Self.iosDeviceIdentifier()
            let deviceName = await Self.iosDeviceName()
            let client = LiveCloudKitClient(containerIdentifier: "iCloud.\(Paths.bundleId)")
            let syncer = CloudKitSyncer(
                store: store,
                client: client,
                device: .init(identifier: deviceID, name: deviceName)
            )
            self.syncer = syncer
            try await syncer.ensureSubscription()
            await pullNow()
        } catch {
            lastError = "\(error)"
        }
    }

    /// Force a pull. Called on pull-to-refresh and from the toolbar.
    func pullNow() async {
        guard let syncer = syncer else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            lastPull = try await syncer.pullRemoteChanges()
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
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
