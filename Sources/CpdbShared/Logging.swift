import Foundation
import os

/// Tiny logging facade.
///
/// We use `os.Logger` for structured system logging (visible in Console.app
/// under subsystem `local.cpdb`) and mirror human-readable lines to stderr so
/// they show up when the daemon runs in the foreground.
public enum Log {
    public static let subsystem = Paths.bundleId

    public static let daemon  = Logger(subsystem: subsystem, category: "daemon")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let store   = Logger(subsystem: subsystem, category: "store")
    public static let importer = Logger(subsystem: subsystem, category: "importer")
    public static let cli     = Logger(subsystem: subsystem, category: "cli")

    /// Print a line to stderr. Use for user-facing progress in CLI commands.
    public static func stderr(_ message: @autoclosure () -> String) {
        let line = message() + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
