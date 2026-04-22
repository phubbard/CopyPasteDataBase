import Foundation
import GRDB
import CpdbCore
import CpdbShared

/// Pretty-printing helpers shared across commands.
enum Output {
    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func printListRow(_ row: Row) {
        let id: Int64 = row["id"]
        let ts: Double = row["created_at"]
        let kind: String = row["kind"]
        let title: String? = row["title"]
        let preview: String? = row["text_preview"]
        let size: Int64 = row["total_size"]
        let app: String? = row["app_name"]

        let when = timestampFormatter.string(from: Date(timeIntervalSince1970: ts))
        let display = shortDisplay(title: title, preview: preview, maxLen: 80)
        let appStr = app.map { " [\($0)]" } ?? ""
        print("\(idPad(id))  \(when)  \(kindPad(kind))  \(bytesPad(size))\(appStr)  \(display)")
    }

    static func printSearchHit(row: Row, snippet: String) {
        let id: Int64 = row["id"]
        let ts: Double = row["created_at"]
        let kind: String = row["kind"]
        let app: String? = row["app_name"]
        let when = timestampFormatter.string(from: Date(timeIntervalSince1970: ts))
        let appStr = app.map { " [\($0)]" } ?? ""
        let clean = snippet
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        print("\(idPad(id))  \(when)  \(kindPad(kind))\(appStr)  \(clean)")
    }

    static func printEntryDetail(entry: Entry, app: AppRecord?, flavors: [Row]) {
        let when = timestampFormatter.string(from: Date(timeIntervalSince1970: entry.createdAt))
        print("id          : \(entry.id ?? -1)")
        print("kind        : \(entry.kind.rawValue)")
        print("created_at  : \(when)")
        print("total_size  : \(bytes(entry.totalSize))")
        print("source app  : \(app.map { "\($0.name) (\($0.bundleId))" } ?? "unknown")")
        if let title = entry.title, !title.isEmpty {
            print("title       : \(title)")
        }
        if let preview = entry.textPreview, !preview.isEmpty {
            let singleLine = preview.replacingOccurrences(of: "\n", with: "⏎")
            print("preview     : \(String(singleLine.prefix(200)))")
        }
        print("flavors     :")
        for row in flavors {
            let uti: String = row["uti"]
            let size: Int64 = row["size"]
            let spilled: Int64 = row["spilled"]
            let loc = spilled != 0 ? "spill" : "inline"
            print("  - \(uti.padding(toLength: 40, withPad: " ", startingAt: 0))  \(bytesPad(size))  \(loc)")
        }
    }

    // MARK: - helpers

    static func shortDisplay(title: String?, preview: String?, maxLen: Int) -> String {
        let raw = title?.isEmpty == false ? title : preview
        let s = (raw ?? "").replacingOccurrences(of: "\n", with: "⏎")
        if s.count > maxLen { return String(s.prefix(maxLen - 1)) + "…" }
        return s
    }

    static func idPad(_ id: Int64) -> String {
        String(id).leftPadded(to: 6)
    }

    static func kindPad(_ kind: String) -> String {
        kind.padding(toLength: 5, withPad: " ", startingAt: 0)
    }

    static func bytesPad(_ n: Int64) -> String {
        bytes(n).leftPadded(to: 8)
    }

    static func bytes(_ n: Int64) -> String {
        if n < 1024 { return "\(n)B" }
        if n < 1024 * 1024 { return String(format: "%.1fK", Double(n) / 1024) }
        if n < 1024 * 1024 * 1024 { return String(format: "%.1fM", Double(n) / (1024 * 1024)) }
        return String(format: "%.2fG", Double(n) / (1024 * 1024 * 1024))
    }

    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let sz = (try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize {
                total += Int64(sz)
            }
        }
        return total
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        if count >= length { return self }
        return String(repeating: " ", count: length - count) + self
    }
}
