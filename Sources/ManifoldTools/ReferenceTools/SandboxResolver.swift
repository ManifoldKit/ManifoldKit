import Foundation

/// Shared path-resolution helper for filesystem tools.
///
/// Standardises a relative `path` against a `root` directory and rejects the
/// call when the result escapes the root — even via `..` components or
/// symlinks. Used by ``ReadFileTool``, ``ListDirTool``, and the demo's
/// `WriteFileTool` so all filesystem reference tools share the same
/// containment guarantee.
public enum SandboxResolver {

    /// Returns `nil` when `path` escapes `root`. Otherwise returns the
    /// fully-resolved absolute URL inside the sandbox.
    public static func resolve(path: String, inside root: URL) -> URL? {
        let standardizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()

        // Reject absolute paths outright — they can't be inside a relative
        // sandbox root by definition (even when they happen to share the
        // same prefix, the intent is clearly to escape).
        if path.hasPrefix("/") {
            return nil
        }

        let candidate = standardizedRoot
            .appendingPathComponent(path)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let rootPath = standardizedRoot.path
        let candidatePath = candidate.path

        // Allow `candidate == root` (list_dir on ".") and anything below it.
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        return candidate
    }
}
