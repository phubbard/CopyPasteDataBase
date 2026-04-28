#if os(macOS)
import ArgumentParser
import CpdbCore
import CpdbShared
import Foundation

/// `cpdb fixture …` — manage test fixtures: snapshots of the live
/// data directory you can experiment against without risking the
/// real DB + blobs.
///
/// Workflow:
///
///   cpdb fixture snapshot                    # copy live data to a fresh fixture
///   cpdb fixture list                        # show snapshots + sizes
///   eval $(cpdb fixture env <name>)          # set CPDB_SUPPORT_DIR for the shell
///   cpdb evict --before-days 30 --dry-run    # all subsequent cpdb cmds run against fixture
///   cpdb fixture delete <name>               # clean up
///
/// Internals: every fixture is a directory under `cpdb-fixtures/`
/// next to the live support directory. We use `/usr/bin/ditto` for
/// the copy — preserves xattrs + symlinks + the WAL file shape so
/// SQLite opens cleanly. The tool drives every cpdb subcommand at
/// the fixture by setting `CPDB_SUPPORT_DIR` in the environment;
/// `Paths.supportDirectory` honours the override.
struct Fixture: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fixture",
        abstract: "Manage snapshot fixtures of the live cpdb data directory.",
        subcommands: [
            Snapshot.self,
            List.self,
            Env.self,
            Delete.self,
            Path.self,
        ]
    )

    /// Repository for snapshots. Lives next to the real support
    /// directory so it shares the same volume (matters for the
    /// hard-link/clone path inside ditto, which only works
    /// intra-volume).
    static var fixturesRoot: URL {
        // Resolve against the LIVE support directory ignoring any
        // CPDB_SUPPORT_DIR override — fixtures live next to the
        // real data, not inside another fixture.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("\(Paths.bundleId)-fixtures", isDirectory: true)
    }

    static func fixturePath(named name: String) -> URL {
        fixturesRoot.appendingPathComponent(name, isDirectory: true)
    }

    /// `cpdb fixture snapshot` — copy live data to a fixture.
    struct Snapshot: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy the live data directory into a new fixture."
        )

        @Option(
            name: .long,
            help: "Fixture name. Defaults to a timestamp."
        )
        var name: String = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        func run() throws {
            try FileManager.default.createDirectory(
                at: Fixture.fixturesRoot,
                withIntermediateDirectories: true
            )
            let dest = Fixture.fixturePath(named: name)
            if FileManager.default.fileExists(atPath: dest.path) {
                throw FixtureError.exists(name)
            }
            // Resolve the live source directly (NOT through Paths
            // honoring the env var, since we always want to snapshot
            // the real data).
            let liveSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent(Paths.bundleId, isDirectory: true)
            guard FileManager.default.fileExists(atPath: liveSupport.path) else {
                throw FixtureError.noLiveData
            }
            // Use ditto. Preserves xattrs + the SQLite -wal/-shm file
            // shape that bare `cp -R` can mangle. Some SQLite states
            // also need a checkpoint — best to ask the user to quit
            // the daemon first; we warn but don't enforce.
            print("snapshotting \(liveSupport.path) → \(dest.path)")
            print("  (tip: quit cpdb.app first for a fully consistent SQLite snapshot)")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = [liveSupport.path, dest.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                throw FixtureError.dittoFailed(ditto.terminationStatus)
            }
            print("done. fixture name: \(name)")
            print("activate with:  eval $(cpdb fixture env \(name))")
        }
    }

    /// `cpdb fixture list` — print fixtures with sizes.
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List existing fixtures with sizes."
        )

        func run() throws {
            let fm = FileManager.default
            guard fm.fileExists(atPath: Fixture.fixturesRoot.path) else {
                print("(no fixtures)")
                return
            }
            let names = try fm.contentsOfDirectory(atPath: Fixture.fixturesRoot.path).sorted()
            if names.isEmpty {
                print("(no fixtures)")
                return
            }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            for name in names {
                let path = Fixture.fixturePath(named: name)
                let size = directorySize(at: path)
                print("  \(name)  \(formatter.string(fromByteCount: size))")
            }
        }

        private func directorySize(at url: URL) -> Int64 {
            var total: Int64 = 0
            if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileURL as URL in e {
                    total += Int64(
                        (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    )
                }
            }
            return total
        }
    }

    /// `cpdb fixture env <name>` — print a shell-eval'able export.
    struct Env: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print `export CPDB_SUPPORT_DIR=…` for shell eval."
        )

        @Argument(help: "Fixture name.")
        var name: String

        func run() throws {
            let path = Fixture.fixturePath(named: name)
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw FixtureError.notFound(name)
            }
            // Quote-safe even with spaces in the path.
            let escaped = path.path.replacingOccurrences(of: "'", with: "'\\''")
            print("export CPDB_SUPPORT_DIR='\(escaped)'")
        }
    }

    /// `cpdb fixture path <name>` — print just the path.
    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the absolute path to a fixture."
        )

        @Argument(help: "Fixture name.")
        var name: String

        func run() throws {
            let p = Fixture.fixturePath(named: name)
            guard FileManager.default.fileExists(atPath: p.path) else {
                throw FixtureError.notFound(name)
            }
            print(p.path)
        }
    }

    /// `cpdb fixture delete <name>` — remove a fixture and its data.
    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a fixture and all its data."
        )

        @Argument(help: "Fixture name.")
        var name: String

        @Flag(name: .long, help: "Skip confirmation prompt.")
        var force: Bool = false

        func run() throws {
            let p = Fixture.fixturePath(named: name)
            guard FileManager.default.fileExists(atPath: p.path) else {
                throw FixtureError.notFound(name)
            }
            if !force {
                print("delete fixture \(name)? [y/N] ", terminator: "")
                if let answer = readLine(), answer.lowercased().hasPrefix("y") {
                    // proceed
                } else {
                    print("aborted")
                    return
                }
            }
            try FileManager.default.removeItem(at: p)
            print("deleted \(name)")
        }
    }

    enum FixtureError: Error, CustomStringConvertible {
        case noLiveData
        case exists(String)
        case notFound(String)
        case dittoFailed(Int32)

        var description: String {
            switch self {
            case .noLiveData:
                return "no live cpdb data directory found at the standard path"
            case .exists(let name):
                return "fixture '\(name)' already exists. Pick another name or delete the old one."
            case .notFound(let name):
                return "no fixture named '\(name)'. Run `cpdb fixture list` to see what's there."
            case .dittoFailed(let code):
                return "ditto failed with exit code \(code)"
            }
        }
    }
}
#endif
