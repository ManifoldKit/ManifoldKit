import Foundation

/// Immutable input passed to every hook handler. Tool-specific fields are
/// only meaningful for `.preToolUse`; `.preCompact` ignores them.
public struct HookInput: Sendable {
    public let event: HookEvent
    public let sessionID: UUID
    public let toolName: String?
    /// Raw JSON string of the tool call's arguments — the same shape the
    /// model emitted. Hooks may sanitize this via `HookOutput.updatedInput`
    /// but must observe the sanitize-only contract on `HookOutput`.
    public let toolArguments: String?

    public init(
        event: HookEvent,
        sessionID: UUID,
        toolName: String? = nil,
        toolArguments: String? = nil
    ) {
        self.event = event
        self.sessionID = sessionID
        self.toolName = toolName
        self.toolArguments = toolArguments
    }
}
