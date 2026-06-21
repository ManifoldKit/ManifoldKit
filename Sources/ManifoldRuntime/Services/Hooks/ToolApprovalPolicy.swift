import Foundation
import ManifoldInference

/// Declarative policy that decides, for a single run, how a host's
/// tool-approval prompt is consulted before a model-emitted tool call
/// executes.
///
/// This is **Part 1** of sticky tool-approval (#1923): a run-scoped,
/// in-memory gate layered over the existing ``PreToolUseHook`` seam. It does
/// not persist anything — durable async interrupt/resume (Part 2) is
/// iceboxed pending the effect cache, so no `RunStore`/SwiftData column is
/// involved here.
///
/// The policy is consumed by ``ToolApprovalHook/make(policy:approve:)``,
/// which produces a ``PreToolUseHook`` closure ready to install via
/// ``InferenceService/setPreToolUseHook(_:)`` (through the runtime's
/// ``HookRegistry``/adapter, or directly).
public enum ToolApprovalPolicy: Sendable, Equatable {

    /// Prompt the host for **every** tool call. The host `approve` closure is
    /// invoked on each call; a `false` return blocks the call (typed
    /// permission-denied result reaches the model, loop continues).
    case alwaysAsk

    /// Auto-approve every tool call without ever prompting the host. The
    /// `approve` closure is never invoked.
    case alwaysApprove

    /// Prompt once per listed tool, then remember the approval for the rest
    /// of the run. The first approval of a tool in `toolNames` consults the
    /// host; subsequent calls to that same tool auto-proceed without
    /// re-prompting. Tools **not** in the set fall back to `.alwaysAsk`
    /// behaviour (prompt every time).
    ///
    /// The "remember" state is run-scoped and in-memory — held by a
    /// ``ToolApprovalStickyCache`` created per run. It is deliberately not
    /// persisted (that is Part 2).
    case approveForRun(toolNames: Set<String>)
}

// MARK: - Sticky cache

/// Run-scoped, in-memory record of which tools have already been approved
/// under ``ToolApprovalPolicy/approveForRun(toolNames:)``.
///
/// One instance lives for the lifetime of a single run (or whatever scope the
/// host chooses to bound it to). It is an `actor` so the sticky set can be
/// read/written safely from the concurrent dispatch loop without a lock.
/// Nothing here touches SwiftData — persistence is a Part-2 concern.
public actor ToolApprovalStickyCache {

    private var approved: Set<String> = []

    public init() {}

    /// Whether `toolName` has already been approved this run.
    func isApproved(_ toolName: String) -> Bool {
        approved.contains(toolName)
    }

    /// Record `toolName` as approved for the remainder of the run.
    func recordApproval(_ toolName: String) {
        approved.insert(toolName)
    }

    /// Test/host hook: snapshot of the currently-approved tools.
    public func approvedTools() -> Set<String> {
        approved
    }
}

// MARK: - Hook factory

/// Builds a ``PreToolUseHook`` closure that enforces a
/// ``ToolApprovalPolicy`` against a host-supplied approval prompt.
///
/// The host `approve` closure **is** the argument-preview surface: it
/// receives the same `(toolName, arguments)` the model emitted, so the host
/// can render the pending call (e.g. in an approval sheet) and return the
/// user's decision. No new plumbing is introduced — the existing
/// model-emitted arguments are threaded straight through.
///
/// Decline maps to ``PreToolUseOutcome/block(reason:)``, which the dispatch
/// loop turns into a typed ``ToolResult/ErrorKind/permissionDenied`` result
/// fed back to the model so the turn loop continues (it does **not** abort).
public enum ToolApprovalHook {

    /// Host-supplied approval prompt. Receives the model-emitted tool name and
    /// raw JSON arguments; returns `true` to proceed, `false` to decline.
    public typealias ApprovePrompt = @Sendable (
        _ toolName: String,
        _ arguments: String
    ) async -> Bool

    /// Default denial message surfaced to the model when the host declines.
    static let declinedReason = "Tool call declined by the user."

    /// Creates the ``PreToolUseHook`` for `policy`.
    ///
    /// - Parameters:
    ///   - policy: How to consult the host for approval.
    ///   - cache: Run-scoped sticky cache. Required for
    ///     ``ToolApprovalPolicy/approveForRun(toolNames:)`` to remember
    ///     approvals; ignored by the other cases. A fresh cache per run keeps
    ///     stickiness run-scoped. Defaults to a new cache.
    ///   - approve: Host approval prompt (the arg-preview surface).
    /// - Returns: A `@Sendable` ``PreToolUseHook`` closure.
    public static func make(
        policy: ToolApprovalPolicy,
        cache: ToolApprovalStickyCache = ToolApprovalStickyCache(),
        approve: @escaping ApprovePrompt
    ) -> PreToolUseHook {
        return { toolName, arguments, _ in
            switch policy {
            case .alwaysApprove:
                // Never consult the host — auto-proceed with the unmodified
                // model-emitted arguments.
                return .proceed(arguments: arguments)

            case .alwaysAsk:
                return await consult(
                    toolName: toolName,
                    arguments: arguments,
                    approve: approve
                )

            case .approveForRun(let toolNames):
                // Sticky only for tools the host opted in. A tool already
                // approved this run skips the prompt entirely.
                if toolNames.contains(toolName) {
                    if await cache.isApproved(toolName) {
                        return .proceed(arguments: arguments)
                    }
                    let outcome = await consult(
                        toolName: toolName,
                        arguments: arguments,
                        approve: approve
                    )
                    // Only remember an *approval*; a decline must re-prompt
                    // next time so the user keeps the chance to allow it.
                    if case .proceed = outcome {
                        await cache.recordApproval(toolName)
                    }
                    return outcome
                }
                // Unlisted tools always prompt.
                return await consult(
                    toolName: toolName,
                    arguments: arguments,
                    approve: approve
                )
            }
        }
    }

    /// Single consult of the host prompt → ``PreToolUseOutcome``.
    private static func consult(
        toolName: String,
        arguments: String,
        approve: ApprovePrompt
    ) async -> PreToolUseOutcome {
        let allowed = await approve(toolName, arguments)
        return allowed
            ? .proceed(arguments: arguments)
            : .block(reason: declinedReason)
    }
}
