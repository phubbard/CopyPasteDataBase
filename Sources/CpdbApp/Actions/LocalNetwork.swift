import AppKit
import Network

/// Local Network privacy permission helper.
///
/// macOS gates URLSession requests to RFC1918 / link-local addresses
/// behind a Privacy & Security toggle. Apple doesn't expose an API
/// to query the grant state directly, but we can probe it indirectly
/// via `NWBrowser`: starting a Bonjour browse against a Local
/// Network-class service either reaches `.ready` (granted) or
/// transitions to `.failed` with a permission error (denied). The
/// probe is what powers the green-checkmark / orange-warning row in
/// the Preferences "Permissions" section.
enum LocalNetwork {
    /// Deep link to the Local Network row of Privacy & Security. As of
    /// macOS 14 the pane URL is the same x-apple.systempreferences
    /// scheme used for Accessibility, just with a different anchor.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
        NSWorkspace.shared.open(url)
    }

    /// Tri-state result of a permission probe. `.granted` /
    /// `.denied` are confident verdicts from `NWBrowser`'s state
    /// handler. `.unknown` covers the "haven't probed yet" /
    /// "probe still in flight" / "browser timed out" case so the UI
    /// can render a neutral indicator instead of a false-negative.
    enum Status: Equatable {
        case granted
        case denied
        case unknown
    }

    /// Run a one-shot Local Network probe. Spawns an `NWBrowser` for
    /// the universal `_bonjour._tcp` service type with peer-to-peer
    /// enabled (which forces the OS to consult the Local Network
    /// permission). Resolves with the first conclusive state
    /// transition, or `.unknown` after `timeout`. The browser is
    /// always cancelled before return — no leaks.
    static func probe(timeout: TimeInterval = 1.5) async -> Status {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_bonjour._tcp", domain: nil), using: params)
        let queue = DispatchQueue(label: "net.phfactor.cpdb.local-network-probe")

        return await withCheckedContinuation { (cont: CheckedContinuation<Status, Never>) in
            // Atomic single-resume guard: NWBrowser's state handler
            // can fire multiple times; the timeout race adds another
            // potential resumer. Resume exactly once.
            let resumed = NSLock()
            nonisolated(unsafe) var didResume = false
            func finish(_ status: Status) {
                resumed.lock()
                let already = didResume
                if !already { didResume = true }
                resumed.unlock()
                if !already {
                    browser.cancel()
                    cont.resume(returning: status)
                }
            }

            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.granted)
                case .failed(let err):
                    // The OS surfaces denied permission as either
                    // -65555 (kDNSServiceErr_NoAuth) or a generic
                    // .posix(.EPERM). Treat any failure conservatively
                    // as "denied" — the user is going to see the
                    // re-prompt anyway when something tries to act.
                    _ = err
                    finish(.denied)
                case .waiting(let err):
                    // .waiting can mean "no Bonjour services on this
                    // network" (granted but quiet) OR "permission
                    // denied" — same NWError shapes. We've seen the
                    // browser stay in .waiting indefinitely on a
                    // Wi-Fi-less host, so timeout-handle this rather
                    // than guessing.
                    _ = err
                case .cancelled, .setup:
                    break
                @unknown default:
                    break
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.unknown)
            }
        }
    }
}
