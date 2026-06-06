import os

/// Centralised logging with per-subsystem categories.
///
/// Uses `os.Logger` so messages appear in Console.app and Instruments.
/// Usage: `Log.inference.info("Model loaded in \(elapsed)s")`
public enum Log {
    private static var subsystem: String {
        ManifoldConfiguration.shared.logSubsystem
    }

    public static var inference: Logger { Logger(subsystem: subsystem, category: "inference") }
    public static var persistence: Logger { Logger(subsystem: subsystem, category: "persistence") }
    public static var prompt: Logger { Logger(subsystem: subsystem, category: "prompt") }
    public static var ui: Logger { Logger(subsystem: subsystem, category: "ui") }
    public static var network: Logger { Logger(subsystem: subsystem, category: "network") }
    public static var download: Logger { Logger(subsystem: subsystem, category: "download") }
    public static var security: Logger { Logger(subsystem: subsystem, category: "security") }
    public static var quickStart: Logger { Logger(subsystem: subsystem, category: "quickStart") }
}
