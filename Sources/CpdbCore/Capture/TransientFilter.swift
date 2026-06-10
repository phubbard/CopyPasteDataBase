#if os(macOS)
import Foundation
import AppKit
import CpdbShared

/// Implements the community `nspasteboard.org` convention: clipboard managers
/// must skip items that carry any of these "don't store me" marker UTIs.
///
/// Password managers (1Password, Dashlane, Bitwarden), temporary-clipboard
/// tools, and Universal Clipboard all rely on this. Honoring it is table
/// stakes for a user-trustable clipboard history tool.
public enum TransientFilter {
    /// Single source of truth lives in CpdbShared (`TransientGuard`) so the
    /// Ingestor enforces the same set for every capture path (macOS, iOS,
    /// importers). This watcher-side check is the fast path: it inspects
    /// `NSPasteboardItem.types` BEFORE copying any flavor bytes, which is
    /// strictly better than rejecting a fully-decoded snapshot — but it is
    /// no longer the only line of defense.
    public static var skipUTIs: Set<String> { TransientGuard.concealedUTIs }

    /// Returns true if any item in the array carries a skip marker.
    public static func shouldSkip(_ items: [NSPasteboardItem]) -> Bool {
        for item in items {
            for type in item.types {
                if skipUTIs.contains(type.rawValue) { return true }
            }
        }
        return false
    }
}
#endif
