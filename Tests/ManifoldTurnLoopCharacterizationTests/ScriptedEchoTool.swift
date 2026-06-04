import Foundation
import ManifoldInference

// MARK: - ScriptedEchoTool

/// Minimal ``ToolExecutor`` that returns a fixed scripted response.
///
/// Registered directly in ``ToolRegistry`` for the tool round-trip
/// characterization test. Using the registry dispatch path (not
/// ``SessionToolSource``) keeps the golden stable across the #1606
/// dead-path bug fix — a SessionToolSource-based golden would change
/// intentionally when that fix lands.
struct ScriptedEchoTool: ToolExecutor, @unchecked Sendable {

    let toolName: String
    let response: String

    var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: "Scripted echo tool — returns a fixed response.",
            parameters: .object([:])
        )
    }

    var supportsConcurrentDispatch: Bool { false }
    var requiresApproval: Bool { false }

    func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        ToolResult(callId: "", content: response)
    }
}
