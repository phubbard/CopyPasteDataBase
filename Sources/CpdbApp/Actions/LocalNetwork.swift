import AppKit

/// Local Network privacy permission helper.
///
/// macOS gates URLSession requests to RFC1918 / link-local addresses
/// behind a Privacy & Security toggle. Unlike Accessibility, there's
/// **no public API** to query the current grant state — the only
/// signal is the request hanging or failing. So we don't try to detect
/// "granted"; we just provide UI to (a) deep-link into the right
/// settings pane and (b) explain why cpdb might ask.
///
/// The link backfiller is the practical reason this matters: pages on
/// a corporate VPN or intranet resolve to private IPs, and macOS
/// bounces those requests through this permission.
enum LocalNetwork {
    /// Deep link to the Local Network row of Privacy & Security. As of
    /// macOS 14 the pane URL is the same x-apple.systempreferences
    /// scheme used for Accessibility, just with a different anchor.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
        NSWorkspace.shared.open(url)
    }
}
