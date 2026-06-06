import Foundation

/// Session-scoped agent persona — a named system prompt plus an optional
/// allowlist of tool names the agent may invoke during its turns.
///
/// `Agent` is intentionally a value type in `ManifoldInference`: it carries no
/// persistence machinery and can flow through any layer that already imports
/// the inference module. Agents are aggregated on a `ChatSession` (added
/// in V9 schema migration, Wave 1B) and the active one drives system-prompt
/// re-derivation per turn in `ConversationTurnExecutor`.
public struct Agent: Sendable, Identifiable, Equatable, Hashable, Codable {
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

    public init(targetAgentID: UUID, payload: String? = nil) {
        self.targetAgentID = targetAgentID
        self.payload = payload
    }
}

/// Result of inspecting a tool call: either a regular tool invocation that
/// should be dispatched through the normal registry, or a synthesised
/// `transfer_to_<name>` call that the turn loop intercepts to swap agents.
public enum HandoffDetectionResult: Sendable, Equatable {
    case regular(ToolCall)
    case handoff(AgentHandoff)
}
