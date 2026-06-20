import Foundation
import ManifoldInference

/// Errors thrown while resolving a skill's L3 referenced files.
///
/// L3 ("progressive disclosure") is the Anthropic Skills tier where the body
/// names companion files (`reference.md`, `examples/foo.md`) that are read
/// **on demand** rather than eagerly inlined on every invocation. Resolution
/// is confined to the skill's own directory — a malicious or buggy reference
/// must never read outside it.
public enum SkillReferenceError: Error, Equatable, Sendable {
    /// The relative path escaped the skill directory (`..` segment, absolute
    /// path, or a symlink/normalised path that resolves outside the dir).
    case pathEscapesSkillDirectory(String)
    /// The reference is not declared in the skill's `references:` frontmatter
    /// list. Disclosure is allow-listed: the body can only pull files the
    /// author explicitly published.
    case undeclaredReference(String)
    /// The declared file could not be read (missing on disk, permissions, …).
    case unreadable(String)
}

/// Resolves a skill's declared L3 referenced files, confined to the skill's
/// own directory.
///
/// Mirrors the loader's `seenNamesInPath` confinement discipline: every
/// resolved path is normalised and checked to still live under
/// `skillDirectory` before any read. Absolute paths and `..` escapes are
/// rejected up front; the post-normalisation prefix check is the backstop for
/// anything that slips through (symlinks, redundant separators).
enum SkillReferenceResolver {

    /// Reads `relativePath` from `skillDirectory`, rejecting anything that is
    /// not an allow-listed (`declared`) file confined to the directory.
    ///
    /// - Parameters:
    ///   - relativePath: A path relative to the skill directory, as it appears
    ///     in the skill's `references:` frontmatter list.
    ///   - declared: The skill's declared reference list (the allow-list).
    ///   - skillDirectory: The directory containing the skill's `SKILL.md`.
    /// - Returns: The file contents as a UTF-8 string.
    static func read(
        relativePath: String,
        declared: [String],
        in skillDirectory: URL
    ) throws -> String {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)

        // Allow-list check first — the body may only disclose files the
        // author published. This also means an attacker-controlled body
        // cannot widen the surface beyond the frontmatter.
        guard declared.contains(trimmed) else {
            throw SkillReferenceError.undeclaredReference(trimmed)
        }

        // Reject obvious escapes before touching the filesystem.
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.split(separator: "/").contains("..")
        else {
            throw SkillReferenceError.pathEscapesSkillDirectory(trimmed)
        }

        let base = skillDirectory.standardizedFileURL
        let candidate = base.appendingPathComponent(trimmed).standardizedFileURL

        // Backstop: after normalisation the path must still be inside the
        // skill directory. Compare path components so `…/skill-foo` does not
        // satisfy the prefix of `…/skill-foobar`.
        if !isContained(candidate, in: base) {
            throw SkillReferenceError.pathEscapesSkillDirectory(trimmed)
        }

        // Symlink backstop: `standardizedFileURL` collapses `.`/`..` and
        // redundant separators but does NOT follow symlinks. A declared file
        // that is itself a symlink (or sits under a symlinked subdirectory)
        // could still resolve outside the skill directory and leak an
        // arbitrary file (`/etc/passwd`, `~/.ssh/id_rsa`). Resolve symlinks on
        // BOTH sides — the skill directory may live under a symlinked root
        // such as macOS's `/tmp` → `/private/tmp` — and re-check containment.
        let resolvedBase = base.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        if !isContained(resolvedCandidate, in: resolvedBase) {
            throw SkillReferenceError.pathEscapesSkillDirectory(trimmed)
        }

        do {
            return try String(contentsOf: resolvedCandidate, encoding: .utf8)
        } catch {
            Log.inference.warning(
                "ManifoldSkills: cannot read referenced file \(trimmed, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw SkillReferenceError.unreadable(trimmed)
        }
    }

    /// Whether `candidate` lives strictly under `base`, comparing whole path
    /// components so `…/skill-foo` does not satisfy the prefix of
    /// `…/skill-foobar`. Both URLs must already be standardized.
    private static func isContained(_ candidate: URL, in base: URL) -> Bool {
        let baseComponents = base.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count > baseComponents.count
            && Array(candidateComponents.prefix(baseComponents.count)) == baseComponents
    }
}
