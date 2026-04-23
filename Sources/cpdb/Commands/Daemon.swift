#if os(macOS)
import ArgumentParser
import CpdbCore
import CpdbShared
import Foundation
import AppKit

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run the clipboard capture daemon in the foreground."
    )

    @Flag(name: .long, help: "Suppress stderr progress output (for launchd).")
    var launchd: Bool = false

    @Flag(name: .long, help: "Install a LaunchAgent plist for auto-start.")
    var install: Bool = false

    @Flag(name: .long, help: "Remove the LaunchAgent plist.")
    var uninstall: Bool = false

    func run() throws {
        if install {
            try LaunchAgent.install()
            return
        }
        if uninstall {
            try LaunchAgent.uninstall()
            return
        }

        let store = try Store.open()
        let deviceId = try DeviceIdentity.ensureLocalDevice(in: store)

        let lock = DaemonLock(owner: .cli)
        do {
            try lock.acquire()
        } catch let error as DaemonLock.LockError {
            Log.stderr("error: \(error)")
            Log.stderr("(stop the other process before starting a new daemon)")
            throw ExitCode.failure
        }
        // Release the lock when the process exits normally. Abnormal exits
        // (SIGKILL, crash) leave a stale file — flock cleanup by the kernel
        // is still correct, so the next process probes will see it as stale.
        defer { lock.release() }

        let ingestor = Ingestor(store: store)
        let watcher = PasteboardWatcher(ingestor: ingestor, deviceId: deviceId)

        if !launchd {
            Log.stderr("cpdb daemon starting (device #\(deviceId), db \(Paths.databaseURL.path))")
        }

        watcher.start()

        // Keep the process alive. NSWorkspace / NSPasteboard behavior is most
        // reliable with a main run loop spun up on the main thread.
        RunLoop.main.run()
    }
}
#endif
