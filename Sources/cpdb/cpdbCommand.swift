#if os(macOS)
import ArgumentParser
import CpdbCore
import CpdbShared
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
            Sync.self,
            Dedupe.self,
            BackfillTitles.self,
            Storage.self,
            Evict.self,
        ],
        defaultSubcommand: ListCommand.self
    )
}

#else

/// Non-macOS stub. The iOS Xcode project has a local-package
/// dependency on this Swift Package which pulls in every target
/// including this CLI. On iOS the CLI has no meaning, but the
/// executable still needs a `@main` so the linker is happy.
@main
enum CpdbCLIStub {
    static func main() {
        // Never runs on iOS — this target isn't invoked from the
        // iOS app; we only satisfy the link step.
    }
}

#endif
