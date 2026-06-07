import XCTest

/// Recurrence guard for issue #1695 (action B1): every `Sources/…` path
/// referenced from a Markdown doc link or a workflow `paths:` filter must
/// exist on disk.
///
/// ## Why this matters
///
/// The `ManifoldInference → ManifoldModelCatalog` file move (`ManifoldKitError.swift`)
/// was never tracked through the docs, leaving three reader-facing broken
/// links (`README.md`, `docs/QUICKSTART.md`) and a self-disarming snippet
/// gate whose own `paths:` filter pointed at a file that no longer exists.
/// A broken doc link wastes a reader's trust; a broken `paths:` filter is
/// worse — the gate silently stops firing for the very files it was meant to
/// protect, with no error anywhere. Both classes are pure consequences of an
/// untracked rename, and both are mechanically detectable, so they should be
/// caught at the smallest signal rather than by a human noticing later.
///
/// ## What this test enforces
///
/// Two reference surfaces are walked from the repo root:
///
/// 1. **Markdown** (`README.md`, `docs/**/*.md`) — every Markdown *link
///    target* (`](…)`) that contains `Sources/` is resolved relative to the
///    linking file's directory and must exist. Prose and inline-code mentions
///    are intentionally out of scope: only navigable links are an actionable
///    contract. (Module-name shorthand like `` `Sources/ManifoldUI` `` in
///    prose is documentation, not a path promise.)
/// 2. **Workflow YAML** (`.github/workflows/*.yml`) — every `Sources/…` token
///    (the `paths:` / `paths-ignore:` filter entries) is resolved relative to
///    the repo root and must exist.
///
/// Glob entries (`Sources/ManifoldUI/**`) are validated by their longest
/// literal directory prefix: `Sources/ManifoldUI/**` requires `Sources/ManifoldUI/`
/// to exist. A literal file reference must exist as a file or directory.
///
/// ## Allowlist
///
/// `knownBrokenReferences` carries references this PR cannot responsibly fix
/// in-place. Each entry has a reason and should be removed the moment its
/// owner lands the corresponding fix. DO NOT add an entry to silence a freshly
/// introduced broken link — fix the link instead. The allowlist exists only
/// for cross-PR ownership boundaries and genuinely-deleted targets.
final class DocSourcePathReferenceAuditTest: XCTestCase {

    /// References that resolve to a missing path but are *not* this PR's to
    /// fix. Keyed on the raw reference token (anchors stripped). Tighten or
    /// delete as each owner lands their fix.
    private static let knownBrokenReferences: Set<String> = [
        // The general "Security Model" DocC article was deleted in the
        // ManifoldCore → ManifoldRuntime rename with no 1:1 replacement;
        // THREAT_MODEL.md still links it. Needs a doc-owner decision on the
        // replacement target — out of scope for this hygiene PR.
        "../Sources/ManifoldCore/ManifoldCore.docc/Articles/SecurityModel.md",

        // The following live under .github/workflows/, which a sibling PR
        // owns — this PR must not touch workflow files. They are stale
        // `paths:` filter entries left by file moves and should be corrected
        // there (ManifoldKitError → ManifoldModelCatalog,
        // APIProvider → ManifoldHardware, ManifoldBackends → the umbrella's
        // real source dir).
        "Sources/ManifoldInference/ManifoldKitError.swift",
        "Sources/ManifoldInference/Models/APIProvider.swift",
        "Sources/ManifoldBackends/**",
        "Sources/ManifoldServerBackends/**",
    ]

    func test_everySourcesPathReferencedFromDocsAndWorkflowsExists() throws {
        let repoRoot = try Self.locateRepoRoot()

        var violations: [String] = []
        violations.append(contentsOf: try Self.auditMarkdown(repoRoot: repoRoot))
        violations.append(contentsOf: try Self.auditWorkflows(repoRoot: repoRoot))

        if !violations.isEmpty {
            let formatted = violations.map { "  \($0)" }.joined(separator: "\n")
            XCTFail("""
                Doc / workflow references point at `Sources/…` paths that do not
                exist on disk. This is almost always an untracked file move (see
                issue #1695). Fix the link / `paths:` entry to the file's current
                location, or — only for cross-PR ownership boundaries — add it to
                `knownBrokenReferences` in this test with a reason.

                Offenders (referencing file → missing path [original reference]):
                \(formatted)
                """)
        }
    }

    // MARK: - Surfaces

    private static func auditMarkdown(repoRoot: URL) throws -> [String] {
        var docs: [URL] = [repoRoot.appendingPathComponent("README.md")]
        let docsDir = repoRoot.appendingPathComponent("docs")
        if let enumerator = FileManager.default.enumerator(
            at: docsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "md" {
                docs.append(url)
            }
        }

        var violations: [String] = []
        for fileURL in docs {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let base = fileURL.deletingLastPathComponent()
            for target in linkTargets(in: content) where target.contains("Sources/") {
                let ref = String(target.split(separator: "#").first ?? "")
                if ref.isEmpty { continue }
                if knownBrokenReferences.contains(ref) { continue }
                if let missing = missingPath(forReference: ref, base: base, repoRoot: repoRoot) {
                    violations.append("\(relativePath(fileURL, under: repoRoot)) → \(missing)  [\(target)]")
                }
            }
        }
        return violations
    }

    private static func auditWorkflows(repoRoot: URL) throws -> [String] {
        let workflowsDir = repoRoot.appendingPathComponent(".github/workflows")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: workflowsDir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var violations: [String] = []
        for fileURL in entries where fileURL.pathExtension == "yml" || fileURL.pathExtension == "yaml" {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for token in sourcesTokens(in: content) {
                if knownBrokenReferences.contains(token) { continue }
                // Workflow `paths:` filters are repo-root-relative.
                if let missing = missingPath(forReference: token, base: repoRoot, repoRoot: repoRoot) {
                    violations.append("\(relativePath(fileURL, under: repoRoot)) → \(missing)  [\(token)]")
                }
            }
        }
        return violations
    }

    // MARK: - Resolution

    /// Returns the repo-root-relative missing path if `ref` (possibly a glob)
    /// does not resolve to an existing file/directory; `nil` if it exists.
    private static func missingPath(forReference ref: String, base: URL, repoRoot: URL) -> String? {
        let checkPath: String
        if let starIndex = ref.firstIndex(of: "*") {
            // Glob: validate the longest literal directory prefix.
            let literalPrefix = String(ref[ref.startIndex..<starIndex])
            checkPath = literalPrefix.hasSuffix("/")
                ? String(literalPrefix.dropLast())
                : (literalPrefix as NSString).deletingLastPathComponent
        } else {
            checkPath = ref
        }
        guard !checkPath.isEmpty else { return nil }

        let resolved = URL(fileURLWithPath: checkPath, relativeTo: base).standardizedFileURL
        if FileManager.default.fileExists(atPath: resolved.path) { return nil }
        return relativePath(resolved, under: repoRoot)
    }

    // MARK: - Extraction

    /// Markdown inline-link targets — the `TARGET` in `](TARGET)`.
    private static func linkTargets(in content: String) -> [String] {
        matches(of: #"\]\(([^)\s]+)\)"#, in: content)
    }

    /// `Sources/…` path tokens (workflow `paths:` entries, with surrounding
    /// quotes/whitespace already excluded), trailing punctuation trimmed so
    /// shell-snippet / prose artifacts (`Sources/ManifoldUI/;`) resolve to the
    /// real directory instead of a phantom path.
    private static func sourcesTokens(in content: String) -> [String] {
        let raw = matches(of: #"((?:\.\./)*Sources/[^\s'"]+)"#, in: content)
        var trimmed = Set<String>()
        for token in raw {
            var t = token
            while let last = t.last, ";:,".contains(last) { t.removeLast() }
            if !t.isEmpty { trimmed.insert(t) }
        }
        return Array(trimmed)
    }

    /// Returns the first capture group of every match of `pattern` in `text`.
    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    // MARK: - Repo-root discovery

    private static func locateRepoRoot(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "DocSourcePathReferenceAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Package.swift from #filePath",
        ])
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return path
    }
}
