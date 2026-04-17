import ArgumentParser
import CpdbCore
import Foundation

@main
struct CpdbCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cpdb",
        abstract: "A local-first clipboard history for macOS.",
        discussion: """
        cpdb captures every clipboard event to a local SQLite database so you
        can search and restore earlier copies. It's a from-scratch replacement
        for the Paste app (com.wiheads.paste), and it can import an existing
        Paste database.
        """,
        version: CpdbVersion.current,
        subcommands: [
            Daemon.self,
            ImportCommand.self,
            ListCommand.self,
            SearchCommand.self,
            Show.self,
            CopyCommand.self,
            Stats.self,
            RegenerateThumbnails.self,
            AnalyzeImages.self,
            ForgetSourceApp.self,
            Gc.self,
        ],
        defaultSubcommand: ListCommand.self
    )
}
