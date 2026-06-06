import Foundation

/// Outcome of a pre-tool-use hook. Either passes the call through
/// (optionally with sanitized arguments) or blocks it.
///
/// The block path is surfaced to the dispatch loop, which synthesises a
/// typed ``ToolResult`` with ``ToolResult/ErrorKind/permissionDenied`` and
/// feeds it back to the model so the conversation can continue.
///
/// Wave 2C contract: hosts must obtain ``PreToolUseHook`` closures via the
/// Runtime-side ``PreToolUseHookAdapter`` which enforces the sanitize-only
/// invariant on ``proceed(arguments:)`` (same set of top-level JSON keys
/// as the original). Direct construction here is also allowed for hosts
/// that don't use ``HookRegistry``.
public enum PreToolUseOutcome: Sendable, Equatable {
    /// Continue dispatch using `arguments` (possibly sanitized from the
    /// model-emitted original).
    case proceed(arguments: String)
    /// Cancel the dispatch. The loop emits a ``ToolResult`` with
    /// ``ToolResult/ErrorKind/permissionDenied`` so the model receives a
    /// typed denial and the turn loop continues.
    case block(reason: String?)
}

/// Closure shape the Inference layer can call before dispatching a tool
/// call. Lives in ``ManifoldInference`` (pure value/closure shape, no
/// Runtime dependency); the Runtime wires its ``HookRegistry`` to this
/// surface via ``PreToolUseHookAdapter`` to honour the cross-layer
/// dependency rule (mirrors W2B's ``HandoffDetector`` plumbing).
public typealias PreToolUseHook = @Sendable (
    _ toolName: String,
    _ arguments: String,
    _ requestGroupID: UUID?
) async -> PreToolUseOutcome
