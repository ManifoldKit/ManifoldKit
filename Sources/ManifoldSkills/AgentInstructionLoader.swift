import Foundation
import ManifoldInference

/// Discovers `AGENTS.md` ambient instruction files by walking upward from a
/// session directory to a configurable stop point.
///
/// Results are returned in **root-to-leaf order** (furthest ancestor first,
/// `currentDirectory` last) so that the most-specific instructions appear last
/// when merged and carry higher LLM recency weight — the "closest-wins"
/// semantic used by every major agent tool that reads the format.
///
/// **macOS-only in v1.** On other platforms `discover()` returns `[]` and logs
/// a one-time warning (same contract as ``SkillLoader``).
public struct AgentInstructionLoader: Sendable {

    /// The cross-tool-standard filename; matches the Linux Foundation spec.
    public static let defaultFileName = "AGENTS.md"

    public init() {}

    // MARK: - Discovery

    /// Walks upward from `currentDirectory` to `stopDirectory` (inclusive) and
    /// returns every `AGENTS.md` found along the path.
    ///
    /// Files are ordered **root-to-leaf**: the ancestor-most file first, the
    /// file in `currentDirectory` last. Callers that want only the single
    /// closest instruction can take `.last`.
    ///
    /// - Parameters:
    ///   - currentDirectory: Starting point; typically the session's working
    ///     directory or git root.
    ///   - stopDirectory: Walk stops here (inclusive). Defaults to the current
    ///     user's home directory so the loader never escapes into system paths.
    ///     Pass an explicit URL to anchor to a project root.
    public func discover(
        from currentDirectory: URL,
        stoppingAt stopDirectory: URL? = nil
    ) -> [AgentInstruction] {
        #if os(macOS)
        return _discover(from: currentDirectory, stoppingAt: stopDirectory)
        #else
        Log.inference.warning(
            "ManifoldSkills: AgentInstructionLoader.discover() is macOS-only in v1; returning empty array"
        )
        return []
        #endif
    }

    #if os(macOS)
    private func _discover(from currentDirectory: URL, stoppingAt stopDirectory: URL?) -> [AgentInstruction] {
        let fm = FileManager.default
        let stop = stopDirectory?.standardizedFileURL
            ?? fm.homeDirectoryForCurrentUser.standardizedFileURL

        // Accumulate the walk path leaf → root, then reverse for root-to-leaf delivery.
        var walkPath: [URL] = []
        var cursor = currentDirectory.standardizedFileURL
        while true {
            walkPath.append(cursor)
            if cursor == stop { break }
            let parent = cursor.deletingLastPathComponent().standardizedFileURL
            // Guard against the filesystem root creating an infinite loop.
            if parent.path == cursor.path { break }
            cursor = parent
        }

        var results: [AgentInstruction] = []
        for dir in walkPath.reversed() {
            let candidate = dir.appendingPathComponent(Self.defaultFileName)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            let content: String
            do {
                content = try String(contentsOf: candidate, encoding: .utf8)
            } catch {
                Log.inference.warning(
                    "ManifoldSkills: cannot read \(candidate.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            results.append(AgentInstruction(directory: dir, content: content))
        }
        return results
    }
    #endif

    // MARK: - Merging

    /// Merges instructions into a single string in the order given (root-to-leaf
    /// from ``discover(from:stoppingAt:)``). Sections are separated by `---` so
    /// the LLM can distinguish instruction scopes.
    ///
    /// Returns `nil` when `instructions` is empty.
    public func merged(_ instructions: [AgentInstruction]) -> String? {
        guard !instructions.isEmpty else { return nil }
        return instructions.map(\.content).joined(separator: "\n\n---\n\n")
    }

    /// Convenience: discovers and merges in one call.
    public func loadMerged(
        from currentDirectory: URL,
        stoppingAt stopDirectory: URL? = nil
    ) -> String? {
        merged(discover(from: currentDirectory, stoppingAt: stopDirectory))
    }
}
