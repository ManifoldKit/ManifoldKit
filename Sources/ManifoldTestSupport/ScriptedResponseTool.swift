import Foundation
import ManifoldInference

// MARK: - ScriptedResponseTool

/// Minimal ``ToolExecutor`` that returns a fixed scripted response regardless
/// of arguments.
///
/// Registered directly in a ``ToolRegistry`` to drive Glass Box tool round-trip
/// scenarios (``RuntimeScenario`` with non-empty `toolExecutors`). It is the
/// reusable, public twin of the characterization suite's private
/// `ScriptedEchoTool` — kept here so scenario authors can express a tool turn
/// without wiring a real executor.
///
/// `requiresApproval` defaults to `false`, so the dispatch loop auto-approves
/// the call and emits `.toolCallApproved` on the genuine-approval path.
public struct ScriptedResponseTool: ToolExecutor, @unchecked Sendable {

    public let toolName: String
    public let response: String

    public init(toolName: String, response: String) {
        self.toolName = toolName
        self.response = response
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: "Scripted tool — returns a fixed response.",
            parameters: .object([:])
        )
    }

    public func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        // callId is stamped by ToolRegistry from the incoming ToolCall.
        ToolResult(callId: "", content: response)
    }
}
