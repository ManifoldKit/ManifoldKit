import Foundation
import ManifoldInference

/// A per-session contributor of tool definitions and tool dispatch.
///
/// Implementations participate in `ConversationTurnExecutor`'s per-turn
/// re-evaluation of advertised tools. The protocol lives in `ManifoldRuntime`
/// (not `ManifoldInference`) because its only input is a `ChatSessionRecord`
/// and its only caller is the runtime turn executor — keeping it here
/// preserves the rule that `ManifoldInference` (and the four backend family
/// targets that depend on it) stays free of session/persistence machinery.
///
/// `SessionToolSource` returns `ToolDefinition` / `ToolResult` from
/// `ManifoldInference` without itself living there.
public protocol SessionToolSource: Sendable {
    /// Tools this source contributes for the given session.
    func toolDefinitions(for session: ChatSessionRecord) async -> [ToolDefinition]

    /// Optional allowlist intersected with the registry. `nil` means "no
    /// restriction"; a non-nil set is intersected with the executor's
    /// advertised tool list. Used by Skills (allowed-tools enforcement) to
    /// strongly contain the model's tool surface while a skill is active.
    func allowedToolNames(for session: ChatSessionRecord) async -> Set<String>?

    /// Dispatch when a tool from this source is called.
    func resolve(
        toolName: String,
        arguments: String,
        session: ChatSessionRecord
    ) async throws -> ToolResult
}

public extension SessionToolSource {
    /// Default no-op for sources that contribute tools but don't restrict the
    /// advertised list.
    func allowedToolNames(for session: ChatSessionRecord) async -> Set<String>? { nil }
}
