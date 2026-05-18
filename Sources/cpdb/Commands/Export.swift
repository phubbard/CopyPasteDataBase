#if os(macOS)
import ArgumentParser
import CpdbCore
import CpdbShared
import Foundation

/// `cpdb export --format {md,csv,html}` — dump the live clipboard
/// history to a portable document. Metadata + text only; flavor
/// bytes and thumbnails are not exported (a clipboard archive is
/// a reading/searching artifact, not a restore image — use
/// CloudKit / the relay for that).
///
/// All rendering + the query live in `HistoryExporter` (CpdbShared)
/// so the Preferences "Export…" button and this command produce
/// byte-identical documents.
struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export clipboard history as Markdown, CSV, or HTML."
    )

    @Option(name: .long, help: "Output format: md | csv | html.")
    var format: HistoryExporter.Format = .md

    @Option(name: .long, help: "Write to this path instead of stdout.")
    var output: String?

    @Option(name: .long, help: "Max entries to export (newest first). Default: all.")
    var limit: Int = Int.max

    @Flag(name: .long, help: "Include entries whose flavor bodies were evicted (metadata still present).")
    var includeEvicted: Bool = true

    func run() throws {
        let store = try Store.open()
        let (document, count) = try HistoryExporter.export(
            from: store,
            format: format,
            limit: limit,
            includeEvicted: includeEvicted
        )
        if let output = output {
            let path = (output as NSString).expandingTildeInPath
            try document.write(toFile: path, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("exported \(count) entries → \(path)\n".utf8))
        } else {
            print(document)
        }
    }
}

// ArgumentParser bridge for the shared enum — keeps the CLI flag
// (`--format md`) working without HistoryExporter depending on
// ArgumentParser.
extension HistoryExporter.Format: ExpressibleByArgument {}
#endif
