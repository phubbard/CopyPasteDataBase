import Foundation
import Network

/// Process-wide network-reachability signal backed by `NWPathMonitor`.
///
/// The link-metadata backfill checks `Reachability.shared.isOnline`
/// before firing a batch — when the OS reports no internet (no Wi-Fi,
/// airplane mode, captive portal denying egress) we skip the work
/// entirely rather than attempt URL fetches that would just time out
/// and burn retry-count budget on rows that are otherwise healthy.
///
/// Posts `Notification.Name.cpdbReachabilityChanged` whenever the
/// path's `.satisfied` status flips, with a `userInfo[isOnline]: Bool`
/// payload. The AppDelegate observes this to fire an immediate
/// backfill catch-up batch when the network comes back.
///
/// Singleton because we want one monitor per process — `NWPathMonitor`
/// is cheap but creating one per fetch would be wasteful, and the
/// path state is naturally global anyway.
public final class Reachability: @unchecked Sendable {
    public static let shared = Reachability()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "net.phfactor.cpdb.reachability")
    private let lock = NSLock()
    private var _isOnline: Bool = true   // optimistic until we hear otherwise

    /// True when the OS reports an active interface that can reach
    /// the internet. False when offline (no Wi-Fi, airplane mode,
    /// VPN handshaking, etc). Defaults to true on first call —
    /// prevents a startup race where the first backfill fires before
    /// the monitor has reported its initial state and gets falsely
    /// blocked.
    public var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isOnline
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let online = path.status == .satisfied
            let changed: Bool = {
                self.lock.lock()
                defer { self.lock.unlock() }
                if self._isOnline == online { return false }
                self._isOnline = online
                return true
            }()
            if changed {
                Log.cli.info("reachability: \(online ? "online" : "offline", privacy: .public)")
                NotificationCenter.default.post(
                    name: .cpdbReachabilityChanged,
                    object: nil,
                    userInfo: ["isOnline": online]
                )
            }
        }
        monitor.start(queue: queue)
    }
}

public extension Notification.Name {
    /// Posted by `Reachability` whenever the OS-reported online
    /// status flips. `userInfo["isOnline"]` is a Bool with the new
    /// state. Observe to drive offline-edge pause / online-edge
    /// catch-up behaviors.
    static let cpdbReachabilityChanged = Notification.Name("cpdb.reachabilityChanged")
}
