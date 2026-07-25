import Foundation

/// Session-scoped agent persona — a named system prompt plus an optional
/// allowlist of tool names the agent may invoke during its turns.
///
/// `AgentDefinition` is intentionally a value type re-exported through
/// `ManifoldInference`: it carries no persistence machinery and can flow
/// through any layer that already imports the inference module. Agents are
/// aggregated on a `ChatSession` (added in V9 schema migration, Wave 1B) and
/// the active one drives system-prompt re-derivation per turn in
/// `ConversationTurnExecutor`.
///
/// Named `AgentDefinition` (not the bare `Agent`) to avoid colliding with
/// `ManifoldSchemaV9.Agent`, the SwiftData `@Model` row this type maps
/// to/from (see `PersistedAgent`) — the two are distinguishable by name
/// without module-qualification.
public struct AgentDefinition: Sendable, Identifiable, Equatable, Hashable, Codable {
    public let id: UUID
    public let name: String
    public let systemPrompt: String
    public let description: String
    /// When non-nil, the executor intersects the advertised tool list with
    /// these names while this agent is active. `nil` means "no restriction".
    public let allowedToolNames: [String]?

    public init(
        id: UUID = UUID(),
        name: String,
        systemPrompt: String,
        description: String,
        allowedToolNames: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.description = description
        self.allowedToolNames = allowedToolNames
    }
}

/// Describes a pending hand-off from the current agent to another agent in
/// the same session. Emitted by handoff detection and consumed by the turn
/// executor to swap `ChatSession.activeAgentID` and inject a boundary
/// message into the next turn's structured history.
public struct AgentHandoff: Sendable, Equatable {
    public let targetAgentID: UUID
    public let payload: String?
    /// The `transfer_to_<name>` tool call that triggered this handoff.
    ///
    /// Carried so the turn executor can persist the call (and a synthetic
    /// success result) onto the assistant message even though the handoff
    /// short-circuits normal tool dispatch — otherwise a turn whose only
    /// product is a handoff has no content parts, gets classified `.empty`,
    /// and is silently dropped, losing the agent switch's visible outcome
    /// and starving `HandoffChipView`'s adjacency lookup of a "from" message
    /// (#2378).
    public let sourceCall: ToolCall

    public init(targetAgentID: UUID, payload: String? = nil, sourceCall: ToolCall) {
        self.targetAgentID = targetAgentID
        self.payload = payload
        self.sourceCall = sourceCall
    }
}

/// Result of inspecting a tool call: either a regular tool invocation that
/// should be dispatched through the normal registry, or a synthesised
/// `transfer_to_<name>` call that the turn loop intercepts to swap agents.
public enum HandoffDetectionResult: Sendable, Equatable {
    case regular(ToolCall)
    case handoff(AgentHandoff)
}
