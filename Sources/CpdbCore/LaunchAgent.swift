import Foundation
import CpdbShared

/// Helpers for writing / removing the user's LaunchAgent plist.
///
/// We deliberately do NOT call `launchctl bootstrap` ourselves — the user
/// runs that explicitly after inspection. The Install step prints the exact
/// command.
public enum LaunchAgent {
    public static let label = "\(Paths.bundleId).daemon"

    public static func install() throws {
        let plistURL = Paths.launchAgentPlistURL
        let parent = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let executable = currentExecutableURL().path
        let stdout = Paths.logsDirectory.appendingPathComponent("stdout.log").path
        let stderr = Paths.logsDirectory.appendingPathComponent("stderr.log").path
        try FileManager.default.createDirectory(at: Paths.logsDirectory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "daemon", "--launchd"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": stdout,
            "StandardErrorPath": stderr,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)

        Log.stderr("Wrote \(plistURL.path)")
        Log.stderr("To load:   launchctl bootstrap gui/$(id -u) \(plistURL.path)")
        Log.stderr("To unload: launchctl bootout gui/$(id -u)/\(label)")
        Log.stderr("(cpdb does not load the agent for you. Run the command above when you're ready.)")
    }

    public static func uninstall() throws {
        let plistURL = Paths.launchAgentPlistURL
        let fm = FileManager.default
        if fm.fileExists(atPath: plistURL.path) {
            try fm.removeItem(at: plistURL)
            Log.stderr("Removed \(plistURL.path)")
        } else {
            Log.stderr("No LaunchAgent plist at \(plistURL.path)")
        }
        Log.stderr("To stop a running daemon: launchctl bootout gui/$(id -u)/\(label)")
    }

    /// Resolve the path to the currently running `cpdb` binary.
    /// Uses `CommandLine.arguments[0]` made absolute.
    public static func currentExecutableURL() -> URL {
        var arg0 = CommandLine.arguments.first ?? "cpdb"
        if !arg0.hasPrefix("/") {
            // Resolve relative/PATH-lookup using FileManager + search path heuristics.
            if FileManager.default.fileExists(atPath: arg0) {
                arg0 = (FileManager.default.currentDirectoryPath as NSString)
                    .appendingPathComponent(arg0)
            } else {
                // Try PATH lookup via /usr/bin/which — best-effort.
                let proc = Process()
                proc.launchPath = "/usr/bin/which"
                proc.arguments = [arg0]
                let pipe = Pipe()
                proc.standardOutput = pipe
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    if let out = String(
                        data: pipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    )?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !out.isEmpty {
                        arg0 = out
                    }
                } catch {
                    // fall through — LaunchAgent will fail to resolve the path; user can edit.
                }
            }
        }
        return URL(fileURLWithPath: arg0).standardizedFileURL
    }
}
