import Foundation

/// File-system shim that backs ``OversizeAction/spillToFile``.
///
/// Two responsibilities:
///
/// 1. **Spill**: write a tool result's oversize content to a uniquely
///    named file under `<caches>/ManifoldKit/tool-spills/` and return
///    its URL. On iOS the file is created with
///    `NSFileProtectionCompleteUntilFirstUserAuthentication` so it is
///    readable while the device is unlocked at least once after boot.
/// 2. **Reap**: sweep the spill directory and remove files older than
///    a configurable cutoff (default 7 days).
///
/// ## Open-question decisions
///
/// - **Reaper wiring**: ``InferenceService.init`` schedules
///   `cleanOldSpills(maxAge:)` as a fire-and-forget detached `Task` so
///   startup never blocks on disk IO. Hosts that want manual control
///   can call ``cleanOldSpills(maxAge:directory:)`` directly.
/// - **Sandbox volatility**: caches-directory contents may be evicted
///   by the OS under disk pressure. That is acceptable: the worst-case
///   outcome is that the model retries the tool when it can't read the
///   file back. Hosts that need durable spills should write to
///   `Application Support` themselves and pair the file-reading tool
///   with their own retention policy.
/// - **Gating on a registered file-reading tool**: the reaper does not
///   gate spill writes on the presence of a tool that can read them
///   back. That is the host application's responsibility — emitting a
///   pointer to an unreadable file is a host configuration error, not
///   a library invariant.
package enum ToolSpillReaper {

    // MARK: - Spill

    /// Writes `content` to a new file under `directory` and returns the
    /// file URL. The default `directory` is the standard tool-spills
    /// path under the system caches directory.
    ///
    /// Throws on any IO failure (directory creation, write, or attribute
    /// set). The registry catches and logs these so a failed spill
    /// degrades to truncation rather than crashing the chat loop.
    @discardableResult
    package static func spill(
        content: String,
        directory: URL? = nil
    ) throws -> URL {
        let dir = try directory ?? defaultDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent(spillFilename())
        try content.data(using: .utf8)?.write(to: url, options: .atomic)

        // iOS: protect at the lowest level that lets background tools
        // read the file back. macOS ignores the attribute.
        #if os(iOS) || os(visionOS)
        try (url as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
        #endif

        return url
    }

    /// The default spill directory: `<caches>/ManifoldKit/tool-spills/`.
    /// Tests can override via ``setDefaultDirectoryOverride(_:)`` to keep
    /// writes out of `~/Library/Caches`.
    package static func defaultDirectory() throws -> URL {
        if let override = directoryOverride {
            return override
        }
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return caches
            .appendingPathComponent("ManifoldKit", isDirectory: true)
            .appendingPathComponent("tool-spills", isDirectory: true)
    }

    // Test-only override for the default spill directory. Using a lock for
    // Sendable safety; the override is read on every spill so a stale value
    // would leak writes to the real caches directory in CI.
    private static let overrideLock = NSLock()
    nonisolated(unsafe) private static var _directoryOverride: URL?
    private static var directoryOverride: URL? {
        overrideLock.lock(); defer { overrideLock.unlock() }
        return _directoryOverride
    }

    /// Test-only: redirect ``defaultDirectory()`` to `url`. Pass `nil` to
    /// restore the real caches path. Marked `package` so production hosts
    /// can't accidentally reroute spills.
    package static func setDefaultDirectoryOverride(_ url: URL?) {
        overrideLock.lock(); defer { overrideLock.unlock() }
        _directoryOverride = url
    }

    private static func spillFilename() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Replace ':' so the path is portable across filesystems that
        // disallow colons in filenames.
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "tool-spill-\(timestamp)-\(UUID().uuidString).txt"
    }

    // MARK: - Reap

    /// Removes spill files whose modification date is older than
    /// `maxAge` ago.
    ///
    /// - Parameters:
    ///   - maxAge: Cutoff age. Files modified before `Date().addingTimeInterval(-maxAge)`
    ///     are deleted. Defaults to 7 days.
    ///   - directory: Spill directory. Defaults to ``defaultDirectory()``.
    ///
    /// IO errors during enumeration or deletion are logged at warning
    /// level and swallowed — a stale-file sweep is opportunistic. Hosts
    /// that need stronger guarantees can implement their own policy.
    package static func cleanOldSpills(
        maxAge: TimeInterval = 7 * 24 * 60 * 60,
        directory: URL? = nil
    ) {
        let dir: URL
        do {
            dir = try directory ?? defaultDirectory()
        } catch {
            Log.inference.warning("tool-spill reaper: caches lookup failed (\(String(describing: error), privacy: .public))")
            return
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Log.inference.warning("tool-spill reaper: enumerate failed (\(String(describing: error), privacy: .public))")
            return
        }

        for url in contents {
            let modified: Date?
            do {
                modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            } catch {
                continue
            }
            guard let modified, modified < cutoff else { continue }
            do {
                try fm.removeItem(at: url)
            } catch {
                Log.inference.warning("tool-spill reaper: remove \(url.lastPathComponent, privacy: .public) failed (\(String(describing: error), privacy: .public))")
            }
        }
    }
}
