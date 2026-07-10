import Foundation

/// A filesystem-discovered skill: a `SKILL.md` file with YAML frontmatter and
/// a prompt-template body.
///
/// Compatible with the Claude Code skill layout (`<root>/<skill-name>/SKILL.md`)
/// so existing user skill libraries work as-is on first launch.
///
/// Named `SkillDefinition` (not the bare `Skill`) — a bare generic public
/// name under the umbrella, matched to ``AgentDefinition``'s suffix per the
/// wave-2 mechanical rename batch (N5).
public struct SkillDefinition: Sendable, Equatable, Codable, Identifiable {
    public var id: String { name }

    /// Canonical skill name (frontmatter `name:`); also the registry key.
    public let name: String

    /// One-line summary surfaced in the skill picker.
    public let description: String

    /// Alternate identifiers that resolve to this skill in the registry.
    public let aliases: [String]

    /// Optional allow-list of tool names the skill needs. `nil` means "no
    /// restriction"; an empty array means "deny all" (skill is prompt-only).
    public let allowedTools: [String]?

    /// Skill-author hint for which model class to use. Parsed but ignored in v1.
    public let model: String?

    /// Free-form guidance about when the model should choose this skill.
    /// Surfaces in the `invoke_skill` tool description so the model can route.
    public let whenToUse: String?

    /// Free-form argument hint surfaced as the `args` parameter description.
    public let argumentHint: String?

    /// Body of `SKILL.md` after the YAML frontmatter — the prompt that gets
    /// injected on dispatch.
    public let promptTemplate: String

    /// L3 progressive-disclosure manifest: relative paths (under the skill's
    /// own directory) the author published via the `references:` frontmatter
    /// list. These are **not** read at discovery or injected on every
    /// dispatch — `resolveReference(_:)` reads one on demand, so the body can
    /// point the model at a 4 KB `reference.md` without spending that budget
    /// on every invocation.
    public let references: [String]

    /// Source file path. Kept for debugging and last-wins precedence display.
    public let sourcePath: URL

    /// Directory containing this skill's `SKILL.md` — the confinement root for
    /// L3 reference resolution.
    public var skillDirectory: URL { sourcePath.deletingLastPathComponent() }

    public init(
        name: String,
        description: String,
        aliases: [String] = [],
        allowedTools: [String]? = nil,
        model: String? = nil,
        whenToUse: String? = nil,
        argumentHint: String? = nil,
        promptTemplate: String,
        references: [String] = [],
        sourcePath: URL
    ) {
        self.name = name
        self.description = description
        self.aliases = aliases
        self.allowedTools = allowedTools
        self.model = model
        self.whenToUse = whenToUse
        self.argumentHint = argumentHint
        self.promptTemplate = promptTemplate
        self.references = references
        self.sourcePath = sourcePath
    }

    /// Reads one declared L3 reference on demand, confined to the skill's own
    /// directory.
    ///
    /// Throws `SkillReferenceError` for undeclared paths, directory escapes
    /// (`..`, absolute, or post-normalisation), or unreadable files — never
    /// `try?`-swallowed, so authoring mistakes stay visible.
    public func resolveReference(_ relativePath: String) throws -> String {
        try SkillReferenceResolver.read(
            relativePath: relativePath,
            declared: references,
            in: skillDirectory
        )
    }
}
