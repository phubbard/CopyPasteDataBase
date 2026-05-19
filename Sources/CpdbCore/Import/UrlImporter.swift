#if os(macOS)
import Foundation
import CpdbShared

/// Bulk-seed the database from a list of URL strings, ingesting each
/// as if it had been copied to the clipboard (so kind=link rows flow
/// through the normal backfill → title + thumbnail enrichment).
///
/// Factored out of the `cpdb import-urls` CLI command so the
/// Preferences "Import…" button and the CLI share one
/// implementation. Pure logic, no I/O of its own beyond the store —
/// the caller supplies the already-read file text.
public enum UrlImporter {

    public struct Result: Sendable {
        public var inserted: Int = 0
        public var bumped: Int = 0
        public var skipped: Int = 0
        /// Per-line ingest threw (e.g. a transient DB-busy after the
        /// 5s timeout). Counted, not fatal — the batch continues so
        /// one bad row can't lose the other N.
        public var failed: Int = 0
        /// (line, reason) for lines that didn't pass the scheme
        /// filter — surfaced so the UI / CLI can show why.
        public var rejected: [(line: String, reason: String)] = []
        /// URLs that passed the filter (post-comment/blank strip).
        public var acceptedCount: Int = 0
    }

    /// Parse raw file text into accepted URLs + rejection reasons.
    /// Blank lines and `#`-comments are dropped; only http(s)/file
    /// schemes are accepted. Separated from `run` so a dry-run /
    /// preview can show the plan without touching the store.
    public static func parse(_ raw: String) -> (accepted: [String], rejected: [(line: String, reason: String)]) {
        let candidates = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        var accepted: [String] = []
        var rejected: [(line: String, reason: String)] = []
        for line in candidates {
            guard let u = URL(string: line), let scheme = u.scheme?.lowercased() else {
                rejected.append((line, "unparseable"))
                continue
            }
            guard scheme == "http" || scheme == "https" || scheme == "file" else {
                rejected.append((line, "scheme '\(scheme)' not http/https/file"))
                continue
            }
            accepted.append(line)
        }
        return (accepted, rejected)
    }

    /// Ingest `raw` file text. `spreadSeconds` spreads `captured_at`
    /// backwards from now (oldest line = oldest) so the import
    /// doesn't collapse into one timestamp and scramble popup order.
    @discardableResult
    public static func run(
        rawText raw: String,
        into store: Store,
        spreadSeconds: Double = 0
    ) throws -> Result {
        let (accepted, rejected) = parse(raw)
        var result = Result()
        result.rejected = rejected
        result.acceptedCount = accepted.count
        guard !accepted.isEmpty else { return result }

        let deviceId = try DeviceIdentity.ensureLocalDevice(in: store)
        let ingestor = Ingestor(store: store)
        let now = Date()
        let step = spreadSeconds / Double(max(accepted.count, 1))

        for (idx, line) in accepted.enumerated() {
            let offset = step * Double(accepted.count - 1 - idx)
            let capturedAt = now.addingTimeInterval(-offset)
            let snapshot = Self.snapshot(for: line, capturedAt: capturedAt)
            // Per-line isolation: a single ingest throwing (transient
            // DB contention, an odd flavor, etc.) must NOT abort the
            // whole import — that's the v2.9.x bug where a SQLITE_BUSY
            // on line 2 silently dropped the remaining 9 URLs.
            do {
                let outcome = try ingestor.ingest(snapshot, sourceApp: .importer, deviceId: deviceId)
                switch outcome {
                case .inserted: result.inserted += 1
                case .bumped:   result.bumped += 1
                case .skipped:  result.skipped += 1
                }
            } catch {
                result.failed += 1
            }
        }
        return result
    }

    /// Synthetic pasteboard snapshot for a URL string: `public.url`
    /// (so the kind classifier resolves `.link`) + `public.utf8-
    /// plain-text` (so search + text_preview behave like a real
    /// browser copy).
    public static func snapshot(for urlString: String, capturedAt: Date) -> PasteboardSnapshot {
        let bytes = Data(urlString.utf8)
        let flavors = [
            CanonicalHash.Flavor(uti: "public.url", data: bytes),
            CanonicalHash.Flavor(uti: "public.utf8-plain-text", data: bytes),
        ]
        return PasteboardSnapshot(
            items: [PasteboardSnapshot.Item(flavors: flavors)],
            capturedAt: capturedAt
        )
    }
}
#endif
