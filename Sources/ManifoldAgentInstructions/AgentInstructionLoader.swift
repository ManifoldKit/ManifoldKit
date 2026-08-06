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
/// a one-time warning.
public struct AgentInstructionLoader: Sendable {

    /// The cross-tool-standard filename; matches the Linux Foundation spec.
    public static let defaultFileName = "AGENTS.md"

    /// Files larger than this are skipped (logged, not read). `AGENTS.md`
    /// files are expected to be small; an oversized file is more likely a
    /// planted or corrupted artifact than genuine instructions, and reading
    /// it whole would otherwise block the calling thread on an unbounded
    /// read with no signal to the caller.
    public static let maxFileSizeBytes = 64 * 1024

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
            "ManifoldAgentInstructions: AgentInstructionLoader.discover() is macOS-only in v1; returning empty array"
        )
        return []
        #endif
    }

    #if os(macOS)
    private func _discover(from currentDirectory: URL, stoppingAt stopDirectory: URL?) -> [AgentInstruction] {
        let fm = FileManager.default
        // Resolve symlinks on both sides for reliable equality.
        let stop = (stopDirectory ?? fm.homeDirectoryForCurrentUser)
            .resolvingSymlinksInPath().standardizedFileURL

        let leaf = currentDirectory.resolvingSymlinksInPath().standardizedFileURL

        // Guard: if currentDirectory is not under stopDirectory the walk would
        // proceed toward the filesystem root without ever matching stop.
        // Treat this as an empty result and log so the caller can correct the
        // anchor — silently returning everything above stop is worse than
        // returning nothing.
        //
        // Path-COMPONENT containment, not string-prefix: `leaf.path.hasPrefix(
        // stop.path)` (the pre-#2434-review shape) treats `/a/proj-secrets` as
        // "under" `/a/proj` because the raw characters match, even though
        // `proj-secrets` is a sibling directory, not a descendant. That let a
        // `stoppingAt` boundary a host believed was containing be silently
        // bypassed, after which the walk below never matches `stop` and reads
        // every `AGENTS.md` up to the filesystem root — confirmed against the
        // real loader (#2434 review finding 2). Comparing `pathComponents`
        // arrays closes it: a sibling can never be a component-wise prefix of
        // its sibling.
        let stopComponents = stop.pathComponents
        let leafComponents = leaf.pathComponents
        guard leafComponents.count >= stopComponents.count,
              Array(leafComponents.prefix(stopComponents.count)) == stopComponents else {
            Log.inference.warning(
                "ManifoldAgentInstructions: currentDirectory '\(leaf.path, privacy: .public)' is not under stopDirectory '\(stop.path, privacy: .public)'; returning empty"
            )
            return []
        }

        // Accumulate the walk path leaf → root, then reverse for root-to-leaf delivery.
        var walkPath: [URL] = []
        var cursor = leaf
        var reachedStop = false
        while true {
            walkPath.append(cursor)
            if cursor == stop {
                reachedStop = true
                break
            }
            let parent = cursor.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            // Guard against the filesystem root creating an infinite loop.
            if parent.path == cursor.path { break }
            cursor = parent
        }
        // Fail closed: the containment guard above should make this
        // unreachable, but a walk that exits at the filesystem root without
        // ever matching `stop` is not trustworthy on its own — defense in
        // depth against a TOCTOU race (a directory swapped mid-walk) rather
        // than silently returning an unbounded set of ancestor directories.
        guard reachedStop else {
            Log.inference.warning(
                "ManifoldAgentInstructions: walk from '\(leaf.path, privacy: .public)' reached the filesystem root without matching stopDirectory '\(stop.path, privacy: .public)'; returning empty (fail closed)"
            )
            return []
        }

        var results: [AgentInstruction] = []
        for dir in walkPath.reversed() {
            let candidate = dir.appendingPathComponent(Self.defaultFileName)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }

            // Reject an `AGENTS.md` that is (or sits behind) a symlink
            // resolving outside `dir`. `fileExists`/`String(contentsOf:)`
            // both follow symlinks transparently, so a planted
            // `AGENTS.md -> ~/.ssh/id_rsa` in an untrusted cloned repo would
            // otherwise be read and merged into the system preamble —
            // confirmed against the real loader (#2434 review finding 3).
            // Opening an untrusted repo is exactly the scenario this module
            // exists for, so this check is load-bearing, not defensive
            // filler.
            let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedCandidate.deletingLastPathComponent().path == dir.path else {
                Log.inference.warning(
                    "ManifoldAgentInstructions: skipping '\(candidate.path, privacy: .public)' — resolves outside its directory (symlink escape)"
                )
                continue
            }

            let fileAttributes: [FileAttributeKey: Any]
            do {
                fileAttributes = try fm.attributesOfItem(atPath: resolvedCandidate.path)
            } catch {
                Log.inference.warning(
                    "ManifoldAgentInstructions: cannot stat \(resolvedCandidate.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            if let fileSize = fileAttributes[.size] as? Int, fileSize > Self.maxFileSizeBytes {
                Log.inference.warning(
                    "ManifoldAgentInstructions: skipping \(resolvedCandidate.path, privacy: .public) — \(fileSize) bytes exceeds the \(Self.maxFileSizeBytes)-byte cap"
                )
                continue
            }

            let content: String
            do {
                content = try String(contentsOf: resolvedCandidate, encoding: .utf8)
            } catch {
                Log.inference.warning(
                    "ManifoldAgentInstructions: cannot read \(resolvedCandidate.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
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
