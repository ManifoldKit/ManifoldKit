import Foundation

/// A single `AGENTS.md` file discovered by ``AgentInstructionLoader``.
///
/// `AGENTS.md` (Linux Foundation cross-tool standard, 60k+ repos) is a
/// plain-markdown ambient instruction file read by agent tools at session
/// start. Unlike `SKILL.md`, it carries no YAML frontmatter — the full file
/// content is the instruction body.
public struct AgentInstruction: Sendable, Equatable {
    /// The directory containing the `AGENTS.md` file.
    public let directory: URL

    /// Markdown content of the `AGENTS.md` file.
    public let content: String

    /// Absolute path to the `AGENTS.md` file.
    public var sourcePath: URL {
        directory.appendingPathComponent(AgentInstructionLoader.defaultFileName)
    }

    public init(directory: URL, content: String) {
        self.directory = directory
        self.content = content
    }
}
