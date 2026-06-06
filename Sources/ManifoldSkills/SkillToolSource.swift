// v2: skill scope persistence — needs SessionStore mutator wired through
// ConversationRuntime so `activeSkillName` actually flips on the session
// record. v1 ships the closure injection point and a read-only path.

import Foundation
import ManifoldInference
import ManifoldRuntime

/// A `SessionToolSource` that advertises a single `invoke_skill` dispatch
/// tool fanning into prompt-template injection from discovered `Skill`s.
///
/// **Concurrency**: mirrors `MCPToolSource` — `@unchecked Sendable` outer +
/// actor-backed storage. The registry is an actor; the source itself is
/// stateless beyond the registry handle and a small `@MainActor` cache that
/// we don't actually need until W3 wires the picker (so kept minimal here).
public final class SkillToolSource: SessionToolSource, @unchecked Sendable {

    /// Tool name fixed by design — the model is taught to call this single
    /// dispatcher rather than skill-specific tools, per plan §Skill
    /// dispatcher shape.
    public static let invokeSkillToolName = "invoke_skill"

    /// Cap aligned with OpenAI's tool-description char budget so the
    /// JSON-Schema enum doesn't blow past the per-tool truncation limit.
    /// >6 skills: warn + alphabetically truncate.
    public static let maxAdvertisedSkills = 6

    private let registry: SkillRegistry
    private let storage: SkillToolSourceStorage
    private let setActiveSkill: (@Sendable (UUID, String?) async -> Void)?

    /// Initializes a skill tool source.
    ///
    /// - Parameter setActiveSkill: Optional closure hosts can wire to flip
    ///   `ChatSession.activeSkillName` on the record. v1 leaves this nil-able
    ///   so the V9 schema can land independently (W1B). The source also
    ///   tracks active skill per-session in-memory so `allowedToolNames(for:)`
    ///   can enforce containment without depending on V9.
    public init(
        registry: SkillRegistry,
        setActiveSkill: (@Sendable (UUID, String?) async -> Void)? = nil
    ) {
        self.registry = registry
        self.storage = SkillToolSourceStorage()
        self.setActiveSkill = setActiveSkill
    }

    /// Test seam: marks a skill as active for `sessionID` so the
    /// `allowedToolNames(for:)` containment path is exercisable without
    /// driving an end-to-end resolve. Production code reaches the same state
    /// via `resolve(...)`.
    public func markActive(skillName: String?, for sessionID: UUID) async {
        await storage.setActive(skillName: skillName, for: sessionID)
    }

    // MARK: SessionToolSource

    public func toolDefinitions(for session: ChatSession) async -> [ToolDefinition] {
        let allSkills = await registry.all()
        guard !allSkills.isEmpty else { return [] }

        let exposed = Array(allSkills.prefix(Self.maxAdvertisedSkills))
        if allSkills.count > Self.maxAdvertisedSkills {
            Log.inference.warning(
                "ManifoldSkills: capping at \(Self.maxAdvertisedSkills) of \(allSkills.count) skills"
            )
        }

        // when-to-use goes in the TOOL description (not the parameter
        // description) — OpenAI truncates parameter docs aggressively but
        // gives the tool description a much larger budget.
        var description = "Invoke a discovered skill by name. Available skills:\n"
        for skill in exposed {
            description += "- \(skill.name): \(skill.description)"
            if let whenToUse = skill.whenToUse {
                description += " (use when: \(whenToUse))"
            }
            description += "\n"
        }

        let argsDescription: String
        if let firstHint = exposed.compactMap(\.argumentHint).first {
            argsDescription = "Skill arguments. \(firstHint)"
        } else {
            argsDescription = "Skill arguments (free-form string; the skill template decides the shape)."
        }

        let parameters: JSONSchemaValue = .object([
            "type": .string("object"),
            "properties": .object([
                "skill_name": .object([
                    "type": .string("string"),
                    "description": .string("Name of the skill to invoke."),
                    "enum": .array(exposed.map { .string($0.name) }),
                ]),
                "args": .object([
                    "type": .string("string"),
                    "description": .string(argsDescription),
                ]),
            ]),
            "required": .array([.string("skill_name")]),
        ])

        // Reference `session` so the type signature stays per-session even
        // though v1 does not yet vary advertised tools by session shape.
        // (W2C / V9 schema will gate on `session.activeSkillName`.)
        _ = session.id

        return [
            ToolDefinition(
                name: Self.invokeSkillToolName,
                description: description,
                parameters: parameters
            )
        ]
    }

    public func allowedToolNames(for session: ChatSession) async -> Set<String>? {
        guard let activeName = await storage.activeSkill(for: session.id),
              let skill = await registry.skill(named: activeName)
        else {
            return nil
        }
        // `allowedTools == nil` on the skill means no restriction. An empty
        // array is the deny-all signal (skill is prompt-only) and we
        // surface it verbatim — strong containment beats accidentally
        // re-enabling the dispatcher.
        guard let allowed = skill.allowedTools else { return nil }
        return Set(allowed)
    }

    public func resolve(
        toolName: String,
        arguments: String,
        session: ChatSession
    ) async throws -> ToolResult {
        guard toolName == Self.invokeSkillToolName else {
            throw SkillDispatchError.unknownTool(toolName)
        }

        let parsed = try Self.parseInvokeArguments(arguments)
        guard let skill = await registry.skill(named: parsed.skillName) else {
            throw SkillDispatchError.unknownSkill(parsed.skillName)
        }

        // Side-effect side: track in-memory active skill so
        // `allowedToolNames(for:)` enforces containment on the next turn,
        // then fan out to the host's persistence closure (if wired) so
        // future versions can rehydrate scope from the session record.
        await storage.setActive(skillName: skill.name, for: session.id)
        if let setActiveSkill {
            await setActiveSkill(session.id, skill.name)
        }

        let renderedBody: String
        if let args = parsed.args, !args.isEmpty {
            renderedBody = "[skill: \(skill.name)] args: \(args)\n\n\(skill.promptTemplate)"
        } else {
            renderedBody = "[skill: \(skill.name)]\n\n\(skill.promptTemplate)"
        }

        // Synthetic call-id: dispatch is internal to this turn and never
        // crosses backend boundaries that would assign one. The format
        // mirrors what MCPToolSource produces for the same reason.
        let callId = "skill-\(skill.name)-\(UUID().uuidString.prefix(8))"
        return ToolResult(callId: String(callId), content: renderedBody)
    }

    // MARK: - Argument parsing

    internal struct InvokeArguments: Sendable, Equatable {
        let skillName: String
        let args: String?
    }

    /// Parses the JSON `{"skill_name": "...", "args": "..."}` payload the
    /// model emits. Uses `do/catch` instead of `try?` per CLAUDE.md.
    internal static func parseInvokeArguments(_ raw: String) throws -> InvokeArguments {
        let data = Data(raw.utf8)
        let object: [String: Any]
        do {
            let parsed = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dict = parsed as? [String: Any] else {
                throw SkillDispatchError.malformedArguments("not a JSON object")
            }
            object = dict
        } catch let error as SkillDispatchError {
            throw error
        } catch {
            throw SkillDispatchError.malformedArguments(error.localizedDescription)
        }
        guard let skillName = object["skill_name"] as? String, !skillName.isEmpty else {
            throw SkillDispatchError.malformedArguments("missing 'skill_name'")
        }
        let args = object["args"] as? String
        return InvokeArguments(skillName: skillName, args: args)
    }
}

/// Errors thrown by `SkillToolSource.resolve(...)`.
public enum SkillDispatchError: Error, Equatable, Sendable {
    case unknownTool(String)
    case unknownSkill(String)
    case malformedArguments(String)
}

/// Actor-isolated per-session active-skill table.
///
/// Stays a private implementation detail so the eventual V9 wire-in can move
/// this state to `ChatSession.activeSkillName` without source-breaking
/// the public `SkillToolSource` shape.
private actor SkillToolSourceStorage {
    private var activeBySessionID: [UUID: String] = [:]

    func setActive(skillName: String?, for sessionID: UUID) {
        if let name = skillName {
            activeBySessionID[sessionID] = name
        } else {
            activeBySessionID.removeValue(forKey: sessionID)
        }
    }

    func activeSkill(for sessionID: UUID) -> String? {
        activeBySessionID[sessionID]
    }
}
