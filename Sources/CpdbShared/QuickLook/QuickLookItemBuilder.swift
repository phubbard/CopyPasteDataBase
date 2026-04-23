import Foundation
import GRDB

/// Builds a file URL that `QLPreviewPanel` can render for a given entry.
///
/// For text and image kinds this writes an ephemeral file under the cpdb
/// caches directory — callers own the lifecycle (delete when done) because
/// `QLPreviewPanel` doesn't manage it.
///
/// For `kind=file` we return the original file URL directly when the file
/// still exists, so QL renders PDFs, Keynote docs, etc. in full fidelity
/// without us having to copy bytes around.
///
/// Returns nil for kinds we don't preview in v1 (link, color, other) and
/// for file entries whose original file is missing and have no image fallback.
public struct QuickLookItemBuilder {
    public let store: Store
    public let blobs: BlobStore
    public let tempDir: URL

    /// UTI → file extension for the image kinds we generate previews for.
    /// Priority order mirrors `PasteboardSnapshot.imageFlavorData`.
    private static let imageFlavors: [(uti: String, ext: String)] = [
        ("public.png",   "png"),
        ("public.jpeg",  "jpg"),
        ("public.tiff",  "tiff"),
        ("public.heic",  "heic"),
        ("public.heif",  "heif"),
        ("public.image", "bin"),
    ]

    public init(store: Store, blobs: BlobStore = BlobStore(), tempDir: URL? = nil) {
        self.store = store
        self.blobs = blobs
        self.tempDir = tempDir ?? Self.defaultTempDir
    }

    /// `~/Library/Caches/<bundleId>/quicklook` — created lazily on first
    /// write. Caches is the canonical OS-sweepable ephemeral location.
    /// Orphan files from the pre-rename path (`local.cpdb.app`) can just
    /// age out of macOS's caches sweeper; no migration needed.
    public static var defaultTempDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches
            .appendingPathComponent(Paths.bundleId, isDirectory: true)
            .appendingPathComponent("quicklook", isDirectory: true)
    }

    public enum BuildError: Error, CustomStringConvertible {
        case entryNotFound(Int64)
        public var description: String {
            switch self {
            case .entryNotFound(let id): return "no entry with id \(id)"
            }
        }
    }

    /// Produce a URL to hand to QL, or nil if we can't preview this entry.
    /// Throws only on genuine failures (entry missing, I/O); "no preview
    /// for this kind" is an expected nil result, not an error.
    public func build(entryId: Int64) throws -> URL? {
        guard let entry = try store.dbQueue.read({ db in
            try Entry.fetchOne(db, key: entryId)
        }) else {
            throw BuildError.entryNotFound(entryId)
        }

        switch entry.kind {
        case .text, .other:
            return try buildText(for: entry)
        case .image:
            return try buildImage(for: entry)
        case .file:
            return try buildFile(for: entry)
        case .link, .color:
            return nil
        }
    }

    // MARK: - Per-kind

    private func buildText(for entry: Entry) throws -> URL? {
        guard let id = entry.id else { return nil }
        let utis = ["public.utf8-plain-text", "public.plain-text"]
        guard let bytes = try loadFirstFlavor(entryId: id, utis: utis), !bytes.isEmpty else {
            return nil
        }
        return try writeTempFile(bytes: bytes, ext: "txt", hint: entry.title)
    }

    private func buildImage(for entry: Entry) throws -> URL? {
        guard let id = entry.id else { return nil }
        for (uti, ext) in Self.imageFlavors {
            if let bytes = try loadFirstFlavor(entryId: id, utis: [uti]) {
                return try writeTempFile(bytes: bytes, ext: ext, hint: entry.title)
            }
        }
        return nil
    }

    private func buildFile(for entry: Entry) throws -> URL? {
        guard let id = entry.id else { return nil }
        if let url = try loadFileURL(entryId: id),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // Fall back to any image flavor the pasteboard might have carried
        // alongside the file-url — CleanShot-style captures have both.
        return try buildImage(for: entry)
    }

    // MARK: - Flavor loading

    private func loadFirstFlavor(entryId: Int64, utis: [String]) throws -> Data? {
        try store.dbQueue.read { db in
            for uti in utis {
                if let row = try Row.fetchOne(
                    db,
                    sql: "SELECT data, blob_key FROM entry_flavors WHERE entry_id = ? AND uti = ?",
                    arguments: [entryId, uti]
                ) {
                    return try blobs.load(
                        inline: row["data"] as Data?,
                        blobKey: row["blob_key"] as String?
                    )
                }
            }
            return nil
        }
    }

    private func loadFileURL(entryId: Int64) throws -> URL? {
        guard let bytes = try loadFirstFlavor(entryId: entryId, utis: ["public.file-url"]) else {
            return nil
        }
        guard let str = String(data: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return URL(string: str)
    }

    // MARK: - Writing

    private func writeTempFile(bytes: Data, ext: String, hint: String?) throws -> URL {
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        let safeHint = sanitisedFilename(hint)
        let filename: String = safeHint.isEmpty
            ? "\(UUID().uuidString).\(ext)"
            : "\(safeHint)-\(UUID().uuidString.prefix(8)).\(ext)"
        let url = tempDir.appendingPathComponent(filename)
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// Strip anything that would confuse Finder / QL out of a filename hint.
    private func sanitisedFilename(_ hint: String?) -> String {
        guard let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hint.isEmpty else { return "" }
        var chars = hint.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            if c == "/" || c == ":" || c == "\\" || c == "\n" || c == "\r" || c == "\0" {
                return "_"
            }
            return c
        }
        if chars.count > 40 {
            chars = Array(chars.prefix(40))
        }
        return String(chars)
    }
}
