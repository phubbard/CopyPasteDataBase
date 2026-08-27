#if os(macOS)
import Foundation

/// Parses/builds `cpdb://clip/<id>` deep links.
///
/// This is the click-through URL attached to Spotlight donations (see
/// `SpotlightDonationService.searchableItem(for:)`, which sets it as
/// `CSSearchableItemAttributeSet.contentURL`) and registered as a
/// custom URL scheme in `Info.plist` (`CFBundleURLTypes`) so macOS
/// routes it to `AppDelegate.application(_:open:)`.
///
/// Kept as pure parsing logic — no AppKit, no Spotlight — so it's
/// testable without driving a real URL-open event or a real
/// `CSSearchableIndex`.
enum ClipDeepLink {
    static let scheme = "cpdb"
    private static let clipHost = "clip"

    /// Extracts the entry id from a `cpdb://clip/<id>` URL. Returns
    /// nil for any other scheme/host/path shape, or a non-numeric id
    /// component.
    static func entryId(from url: URL) -> Int64? {
        guard url.scheme?.lowercased() == scheme, url.host == clipHost else { return nil }
        // `cpdb://clip/42` → host="clip", path="/42". Foundation's
        // URL parser is lenient about the double-slash after the
        // scheme for a custom scheme, so path is the reliable part
        // rather than pathComponents (which can vary in whether it
        // includes a leading "/").
        let idString = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Int64(idString)
    }

    /// The deep link for a given entry id, to attach to a donated
    /// Spotlight item or hand to a `ClipEntity`.
    static func url(forEntryId id: Int64) -> URL? {
        URL(string: "\(scheme)://\(clipHost)/\(id)")
    }
}
#endif
