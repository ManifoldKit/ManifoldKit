import Foundation

/// Public accessor for the `manifold-tools` fixture tree bundled with the
/// `ManifoldTools` target (`a.txt`, `shopping-list.txt`, `readmes/`, `notes/`,
/// …) — the sandbox ``ReadFileTool``, ``ListDirTool``, and
/// ``SampleRepoSearchTool`` read from by default.
///
/// This ships as a `.copy` resource on `ManifoldTools` (see `Package.swift`)
/// so the fixture tree resolves via `Bundle.module` regardless of the process
/// working directory — `swift run`, `swift test`, an installed
/// `manifold-tools` binary, or a companion package (manifold-mlx /
/// manifold-llama, #1749) that depends on this target all see the single
/// canonical copy. Previously this content lived only at the repo-relative
/// `Tests/Fixtures/manifold-tools/`, resolved by callers concatenating it onto
/// the current working directory — the same CWD-relative gotcha
/// ``ScenarioLoader`` had (fixed in #2042) — which forced both companion
/// repos to hand-vendor their own copy.
public enum ToolFixtures {

    /// Resolves the bundled fixture tree from the package resource bundle
    /// (`Bundle.module`). Independent of the working directory.
    ///
    /// If the resource bundle somehow lacks the `manifold-tools` directory (a
    /// packaging regression), this returns the path where the tree *should*
    /// live inside the bundle — a non-existent location. Callers that then
    /// hit a missing-file error will name the bundle path, not a silently
    /// empty CWD-relative directory. We deliberately do NOT fall back to a
    /// CWD-relative source path — that would mask a packaging regression
    /// whenever the process happens to run from the package root.
    public static func bundledRoot() -> URL {
        if let bundled = Bundle.module.url(forResource: "manifold-tools", withExtension: nil) {
            return bundled
        }
        return Bundle.module.bundleURL.appendingPathComponent("manifold-tools", isDirectory: true)
    }
}
