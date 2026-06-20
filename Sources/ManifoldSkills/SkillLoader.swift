import Foundation
import ManifoldInference

/// Filesystem scanner that materialises `Skill` values from `SKILL.md` files.
///
/// **macOS-only in v1.** iOS skill discovery requires entitlement / app-group
/// design that hasn't shipped yet — on iOS `discover()` returns `[]` and logs
/// a one-time warning so app authors notice.
public struct SkillLoader: Sendable {

    public let searchPaths: [URL]

    /// Default Claude-Code-compatible search paths in priority order
    /// (last wins on duplicate skill names).
    ///
    /// Resolved lazily — iOS sandboxed builds with no `$HOME` would otherwise
    /// crash at module init. The actual filesystem probe is gated by
    /// `#if os(macOS)` inside `discover()`.
    public static var defaultClaudeCodePaths: [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let pwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        return [
            home.appendingPathComponent(".config/agents/skills", isDirectory: true),
            home.appendingPathComponent(".agents/skills", isDirectory: true),
            home.appendingPathComponent(".claude/skills", isDirectory: true),
            pwd.appendingPathComponent(".agents/skills", isDirectory: true),
            pwd.appendingPathComponent(".claude/skills", isDirectory: true),
        ]
    }

    public init(searchPaths: [URL] = SkillLoader.defaultClaudeCodePaths) {
        self.searchPaths = searchPaths
    }

    /// Discovers all skills across the configured search paths.
    ///
    /// **Last-wins**: a skill name discovered in a later path overrides one
    /// from an earlier path. This matches Claude Code's project-overrides-user
    /// behaviour: `$PWD/.claude/skills/foo` beats `~/.claude/skills/foo`.
    ///
    /// Returns `[]` on non-macOS platforms (no skills loaded, warning logged
    /// once at module level — see TODO at file scope).
    public func discover() -> [Skill] {
        #if os(macOS)
        var byName: [String: Skill] = [:]
        for root in searchPaths {
            for skill in scan(root: root) {
                byName[skill.name] = skill
            }
        }
        return byName.values.sorted { $0.name < $1.name }
        #else
        Log.inference.warning("ManifoldSkills: discover() is macOS-only in v1; returning empty registry")
        return []
        #endif
    }

    #if os(macOS)
    /// Scans a single search-path root for `<sub>/SKILL.md` files.
    private func scan(root: URL) -> [Skill] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        } catch {
            Log.inference.warning("ManifoldSkills: failed to scan \(root.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }

        var skills: [Skill] = []
        var seenNamesInPath: Set<String> = []
        for entry in entries {
            var entryIsDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &entryIsDir), entryIsDir.boolValue else { continue }
            let candidate = entry.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: candidate.path) else { continue }
            guard let skill = loadSkill(at: candidate) else { continue }
            if seenNamesInPath.contains(skill.name) {
                Log.inference.warning("ManifoldSkills: duplicate skill name '\(skill.name, privacy: .public)' within \(root.path, privacy: .public); using first occurrence")
                continue
            }
            seenNamesInPath.insert(skill.name)
            skills.append(skill)
        }
        return skills
    }

    /// Reads + parses a single `SKILL.md`. Returns `nil` on any parse or IO
    /// error (and logs a warning so authoring mistakes are visible). Never
    /// uses `try?` — every error path is explicit.
    private func loadSkill(at url: URL) -> Skill? {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            Log.inference.warning("ManifoldSkills: cannot read \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let parsed = SkillFrontmatterParser.parse(contents) else {
            Log.inference.warning("ManifoldSkills: malformed frontmatter in \(url.path, privacy: .public); skipping")
            return nil
        }

        guard case let .string(name)? = parsed.fields["name"], !name.isEmpty else {
            Log.inference.warning("ManifoldSkills: missing required 'name' in \(url.path, privacy: .public); skipping")
            return nil
        }
        guard case let .string(description)? = parsed.fields["description"], !description.isEmpty else {
            Log.inference.warning("ManifoldSkills: missing required 'description' in \(url.path, privacy: .public); skipping")
            return nil
        }

        let aliases: [String]
        switch parsed.fields["aliases"] {
        case .list(let items): aliases = items
        case .string(let single) where !single.isEmpty: aliases = [single]
        default: aliases = []
        }

        // Distinguish "key absent" (no restriction → nil) from "key present
        // with empty list" (deny-all → []). The frontmatter parser only
        // returns a key entry when it appears in the document.
        let allowedTools: [String]?
        if let value = parsed.fields["allowed-tools"] {
            switch value {
            case .list(let items): allowedTools = items
            case .string(let single) where !single.isEmpty: allowedTools = [single]
            case .string: allowedTools = []
            }
        } else {
            allowedTools = nil
        }

        let model = stringField(parsed.fields, "model")
        let whenToUse = stringField(parsed.fields, "when-to-use")
        let argumentHint = stringField(parsed.fields, "argument-hint")

        // L3 progressive disclosure: the author's published-references
        // allow-list. Recorded here but never read at discovery — the win is
        // resolving on demand, not eagerly inlining the whole tree.
        let references: [String]
        switch parsed.fields["references"] {
        case .list(let items): references = items
        case .string(let single) where !single.isEmpty: references = [single]
        default: references = []
        }

        return Skill(
            name: name,
            description: description,
            aliases: aliases,
            allowedTools: allowedTools,
            model: model,
            whenToUse: whenToUse,
            argumentHint: argumentHint,
            promptTemplate: parsed.body,
            references: references,
            sourcePath: url
        )
    }

    private func stringField(_ fields: [String: SkillFrontmatterValue], _ key: String) -> String? {
        if case let .string(value)? = fields[key], !value.isEmpty {
            return value
        }
        return nil
    }
    #endif
}
