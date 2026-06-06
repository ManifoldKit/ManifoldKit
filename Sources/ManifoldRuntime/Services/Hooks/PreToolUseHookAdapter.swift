import Foundation
import ManifoldInference

/// Fans a ``HookRegistry`` into the closure shape ``GenerationToolDispatchLoop``
/// expects, while enforcing the **sanitize-only** invariant on the
/// `preToolUse` hook contract.
///
/// ## Sanitize-only invariant (v1, structural)
///
/// `HookOutput.updatedInput` may **narrow or scrub** field values in the
/// tool call's JSON arguments (e.g. constrain `path: "./foo"` → `"/sandbox/foo"`)
/// but must reference the same logical target as the original. v1 enforces
/// this structurally: the candidate JSON must have the **same set of
/// top-level keys** as the original. Hooks that change the key shape are
/// treated as redirect attempts — the redirect is dropped (original
/// arguments forwarded to dispatch) and a warning is logged.
///
/// Tighter logical-target checks (e.g. matching specific `path`/`url`/`id`
/// values) are deferred to v2 when host-specific tool schemas are available.
/// To refuse a tool call outright, hooks must use `block: true`.
///
/// ## Telemetry
///
/// Every adapter invocation emits ``ConversationEvent/hookFired(event:sessionID:)``
/// for observability, regardless of outcome.
public enum PreToolUseHookAdapter {
    /// Wraps a ``HookRegistry`` into the closure shape the Inference layer
    /// can call. The returned closure is `@Sendable` and safe to install via
    /// ``InferenceService/setPreToolUseHook(_:)``.
    ///
    /// - Parameters:
    ///   - registry: The runtime-owned hook registry. Handlers registered
    ///     for ``HookEvent/preToolUse`` are invoked in order; the chain
    ///     short-circuits on the first `block: true` (matches
    ///     ``HookRegistry/run(_:)`` semantics).
    ///   - eventEmitter: Receives ``ConversationEvent/hookFired(event:sessionID:)``
    ///     on every invocation. Defaults to a no-op for unit tests.
    public static func make(
        registry: HookRegistry,
        eventEmitter: @Sendable @escaping (ConversationEvent) -> Void = { _ in }
    ) -> @Sendable (
        _ toolName: String,
        _ arguments: String,
        _ requestGroupID: UUID?
    ) async -> PreToolUseOutcome {
        return { toolName, arguments, requestGroupID in
            let sid = requestGroupID ?? UUID()
            let input = HookInput(
                event: .preToolUse,
                sessionID: sid,
                toolName: toolName,
                toolArguments: arguments
            )
            let output = await registry.run(input)

            // Telemetry first — emit regardless of outcome so observers can
            // tally hook firings even when the handler chain was empty
            // (passthrough). Skipping the emit when output == .passthrough
            // would hide the no-op case which is itself useful signal.
            eventEmitter(.hookFired(event: "preToolUse", sessionID: sid))

            if output.block {
                return .block(reason: output.denyReason)
            }
            guard let candidate = output.updatedInput else {
                return .proceed(arguments: arguments)
            }
            if sameLogicalTarget(arguments, candidate) {
                return .proceed(arguments: candidate)
            }
            // Redirect attempt — keys changed shape. Drop the redirect and
            // proceed with the original arguments. Hosts that want to refuse
            // a call must use `block: true`.
            Log.inference.warning(
                "PreToolUseHookAdapter: hook updatedInput changed top-level JSON keys for tool '\(toolName, privacy: .public)'; dropping redirect (sanitize-only contract). Use block:true to refuse."
            )
            return .proceed(arguments: arguments)
        }
    }

    /// Structural same-target check: parse both JSON strings and compare
    /// the set of top-level keys. Returns `true` only when both parse as
    /// JSON objects and the key sets match exactly. Non-object payloads or
    /// parse failures are treated as a redirect (returns `false`) — safer
    /// to drop than to forward a malformed sanitization.
    ///
    /// This is intentionally minimal. v2 may add per-tool schema-aware
    /// checks (e.g. "the `path` value must be a prefix of the original");
    /// the structural invariant catches the obvious bug of swapping a
    /// `path: "./foo"` call for a `url: "..."` call.
    static func sameLogicalTarget(_ original: String, _ candidate: String) -> Bool {
        guard let originalData = original.data(using: .utf8),
              let candidateData = candidate.data(using: .utf8) else {
            return false
        }
        do {
            let originalParsed = try JSONSerialization.jsonObject(with: originalData)
            let candidateParsed = try JSONSerialization.jsonObject(with: candidateData)
            guard let originalDict = originalParsed as? [String: Any],
                  let candidateDict = candidateParsed as? [String: Any] else {
                return false
            }
            return Set(originalDict.keys) == Set(candidateDict.keys)
        } catch {
            // Parse failure → can't prove same-target → reject the sanitize.
            return false
        }
    }
}
