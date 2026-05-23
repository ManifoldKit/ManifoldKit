import Foundation

/// A filesystem-discovered skill: a `SKILL.md` file with YAML frontmatter and
/// a prompt-template body.
///
/// Compatible with the Claude Code skill layout (`<root>/<skill-name>/SKILL.md`)
/// so existing user skill libraries work as-is on first launch.
public struct Skill: Sendable, Equatable, Codable, Identifiable {
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

    /// Source file path. Kept for debugging and last-wins precedence display.
    public let sourcePath: URL

    public init(
        name: String,
        description: String,
        aliases: [String] = [],
        allowedTools: [String]? = nil,
        model: String? = nil,
        whenToUse: String? = nil,
        argumentHint: String? = nil,
        promptTemplate: String,
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
        self.sourcePath = sourcePath
    }
}
