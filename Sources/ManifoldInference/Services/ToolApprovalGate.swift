import Foundation

// MARK: - ToolApprovalDecision

/// The outcome of asking a ``ToolApprovalGate`` whether a specific
/// ``ToolCall`` should be executed.
///
/// Hosts that need more structure than a boolean (e.g. surfacing the denial
/// reason back into the conversation so the model can recover) pair the
/// decision with an optional user-provided ``denied(reason:)`` message.
public enum ToolApprovalDecision: Sendable, Equatable {

    /// The caller authorises the ``ToolCall`` to proceed. The generation
    /// coordinator dispatches the call through the ``ToolRegistry`` as usual.
    case approved

    /// The caller refuses the ``ToolCall``. The generation coordinator
    /// synthesises a ``ToolResult`` with
    /// ``ToolResult/ErrorKind/permissionDenied`` carrying `reason` (or a
    /// default denial string when `nil`) and continues the stream so the
    /// model can acknowledge the refusal.
    case denied(reason: String?)
}

// MARK: - ToolApprovalGate

/// A policy that decides whether a ``ToolCall`` emitted by the model should
/// actually execute.
///
/// Gate is invoked on the *finalized* ``ToolCall`` after streaming arguments
/// have been assembled. See #436 for the streaming-delta contract that
/// precedes this hook — deltas are merged into a single call before the
/// gate sees it, so conformers never receive a partial payload.
///
/// The default conformer is ``AutoApproveGate``, which preserves the
/// pre-gate behaviour of dispatching every call unconditionally. Hosts that
/// need a user-approval sheet, a permission scope check, or an allow-list
/// supply their own conformer via ``InferenceService/init(toolRegistry:toolApprovalGate:)``.
///
/// ## Denial semantics
///
/// When ``approve(_:)`` returns ``ToolApprovalDecision/denied(reason:)`` the
/// generation coordinator does **not** cancel the stream. Instead it emits a
/// synthetic ``GenerationEvent/toolResult(_:)`` with
/// ``ToolResult/ErrorKind/permissionDenied`` so the backend sees a
/// structured failure and the model can recover gracefully on the next turn.
/// This matches how other ``ToolResult/ErrorKind`` values flow through the
/// loop and keeps the denial path symmetric with executor failures.
///
/// ## Concurrency
///
/// The gate is invoked once per ``ToolCall`` from within the generation
/// coordinator's MainActor-isolated dispatch loop. Conformers are free to
/// suspend — e.g. to present a UI sheet and await a user tap — without
/// blocking other generations; the queue drains one request at a time.
public protocol ToolApprovalGate: Sendable {

    /// Decides whether `call` should execute.
    ///
    /// - Parameter call: The finalized ``ToolCall``. `id`, `toolName`, and
    ///   `arguments` are all populated — never a streaming fragment.
    /// - Returns: ``ToolApprovalDecision/approved`` to dispatch through the
    ///   registry, or ``ToolApprovalDecision/denied(reason:)`` to
    ///   short-circuit with a synthesised `permissionDenied` result.
    func approve(_ call: ToolCall) async -> ToolApprovalDecision
}

// MARK: - AutoApproveGate

/// The default ``ToolApprovalGate`` — approves every call without prompting.
///
/// This preserves the behaviour ``InferenceService`` had before the gate
/// protocol existed, so callers who do not opt into per-call approval see
/// no change. UI-layer conformers (landed in PR 3) replace this with a
/// user-driven approval queue.
public struct AutoApproveGate: ToolApprovalGate {

    public init() {}

    public func approve(_ call: ToolCall) async -> ToolApprovalDecision {
        .approved
    }
}
