import Foundation

/// CloudKit schema for cpdb v2.0 sync.
///
/// Single source of truth for zone name, record type names, and field
/// keys. Using these constants everywhere means a typo fails to compile
/// rather than silently dropping data on the wire.
///
/// Record shape:
///
/// - `Entry` — one per captured clipboard event. Scalars + denormalised
///   source-app/device metadata + thumbnail `CKAsset`s. Flavors are
///   separate child records.
/// - `Flavor` — one per pasteboard UTI on an entry. The `data` field is a
///   `CKAsset` regardless of size (we upload everything, not just spilled
///   blobs, so the record shape is uniform).
/// - `ActionRequest` — ephemeral "please paste entry X on device Y"
///   notifications written by the iOS companion and consumed+deleted by
///   the target Mac.
public enum CKSchema {
    /// Custom zone inside the Private Database. Using a named zone (not
    /// the default zone) lets us use zone-wide change tokens and zone-
    /// level subscriptions for efficient incremental pulls.
    public static let zoneName = "cpdb-v2"

    public enum RecordType {
        public static let entry         = "Entry"
        public static let flavor        = "Flavor"
        public static let actionRequest = "ActionRequest"
    }

    public enum EntryField {
        public static let uuid               = "entryUUID"        // Data (16 bytes)
        public static let createdAt          = "createdAt"        // Double (unix seconds)
        public static let capturedAt         = "capturedAt"       // Double
        public static let kind               = "kind"             // String (EntryKind.rawValue)
        public static let title              = "title"            // String?
        public static let textPreview        = "textPreview"      // String?
        public static let contentHash        = "contentHash"      // Data (32 bytes, SHA-256)
        public static let totalSize          = "totalSize"        // Int64
        public static let deletedAt          = "deletedAt"        // Double? — tombstone
        public static let ocrText            = "ocrText"          // String?
        public static let imageTags          = "imageTags"        // String? (comma-separated)
        public static let analyzedAt         = "analyzedAt"       // Double?
        public static let sourceAppBundleId  = "sourceAppBundleId" // String?
        public static let sourceAppName      = "sourceAppName"    // String?
        public static let deviceIdentifier   = "deviceIdentifier" // String (never nil on write)
        public static let deviceName         = "deviceName"       // String
        public static let thumbSmall         = "thumbSmall"       // CKAsset?
        public static let thumbLarge         = "thumbLarge"       // CKAsset?
        // v2.6: per-entry pin state. Stored as Int64 (0 / 1) on the
        // wire — CKRecord doesn't have a native Bool type. Older
        // clients that don't know about this field treat it as
        // missing → unpinned, which is the safe default.
        public static let pinned             = "pinned"           // Int64 (0 or 1)
        // v2.6.2: tier-2 eviction marker. Non-nil = device has
        // discarded body bytes per its retention policy. Other
        // devices honour this on pull (don't re-hydrate the bodies
        // they may still hold) so eviction is per-device but
        // tombstone-like across the fleet.
        public static let bodyEvictedAt      = "bodyEvictedAt"    // Double?
        // v2.7: background-fetched link metadata for kind=link
        // entries. linkTitle is the page / video title; linkFetchedAt
        // is the sentinel ("any device has tried"). Both round-trip
        // so once one device fetches, siblings get the title for
        // free.
        public static let linkTitle          = "linkTitle"        // String?
        public static let linkFetchedAt      = "linkFetchedAt"    // Double?
    }

    public enum FlavorField {
        public static let entryRef = "entryRef"  // CKReference → Entry
        public static let uti      = "uti"       // String
        public static let size     = "size"      // Int64
        public static let data     = "data"      // CKAsset
    }

    public enum ActionRequestField {
        public static let targetDeviceIdentifier = "targetDeviceIdentifier" // String
        public static let kind                   = "kind"                   // String ("paste")
        public static let entryRef               = "entryRef"               // CKReference → Entry
        public static let requestedAt            = "requestedAt"            // Double
    }

    public enum ActionKind {
        public static let paste = "paste"
    }
}
