import Foundation

/// Synchronous hook events distinct from the observational `ConversationEvent`
/// surface. These fire at decision points in the turn loop where a host may
/// mutate or block the operation.
public enum HookEvent: String, Sendable, Equatable, CaseIterable {
    /// Fires before a tool call dispatches. Hooks may sanitize the
    /// arguments (via `HookOutput.updatedInput`) or block the call entirely
    /// (via `HookOutput.block`). Sanitize-only contract — see `HookOutput` docs.
    case preToolUse

    /// Fires before history compression runs. Hooks may inspect or transform
    /// the compression-bound context. Cannot block compression (it always
    /// proceeds with whatever the hook chain produces).
    case preCompact

    /// Fires after a generation turn completes successfully — the unified
    /// registry counterpart to ``GenerationHook/postGeneration(_:)``. Carries
    /// the completed turn via ``HookInput/completedTurn``. Not fired on
    /// cancellation, a stream error, or an empty-response turn (same contract
    /// as `GenerationHook`). Observational like `.preCompact`: `block` is not
    /// honoured — the turn has already committed and there is no mutation
    /// channel.
    case postGeneration
}
