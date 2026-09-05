# The Hook System

Synchronous mutation/block points in the turn loop, distinct from the observational ``ConversationEvent`` surface.

## When to use

``HookRegistry`` lets a host take a decision at two well-defined points in the turn loop:

- ``HookEvent/preToolUse`` — fires before each tool call dispatches. Hooks may **sanitize** the arguments or **block** the call.
- ``HookEvent/preCompact`` — fires before history compression runs. In v1 hooks are **observational** here; `block: true` is ignored and compression always proceeds.
- ``HookEvent/postGeneration`` — fires after a generation turn completes successfully, carrying the same completed-turn payload as ``GenerationHook/postGeneration(_:)`` via ``HookInput/completedTurn``. Also observational; `block: true` is ignored (the turn has already committed).

For pure observability (token deltas, message-persisted events, etc.) use ``ConversationEvent`` — it ships without the back-pressure / timeout machinery hook handlers carry.

### Hooks do not overlap with MCP approvals

`ManifoldMCP` owns its own approval flow via `MCPApprovalPolicy` and `MCPPersistentToolApprovalStore`. Hooks do **not** participate in MCP approvals and layering a `preToolUse` hook on top of an MCP-approved tool does not double-prompt the user. Per-host policy gating belongs on MCP; per-call sanitisation belongs in hooks.

## Registering hooks

```swift,no-build
import Foundation
import ManifoldRuntime

let registry = HookRegistry()

await registry.register(.preToolUse) { input in
    // ... return a HookOutput
    return .passthrough
}

let runtime = ConversationRuntime(
    messageStore: messageStore,
    inferenceService: inferenceService,
    hookRegistry: registry
)
```

Hooks for an event run **in registration order**. The chain short-circuits on the first handler returning `block: true`. ``HookOutput/updatedInput`` from one handler is threaded into the next handler's ``HookInput/toolArguments`` so a chain of sanitisers can layer narrowing transforms.

A handler that exceeds the registry's `timeout` (default `.seconds(5)`) receives a cancellation request. The registry still awaits that direct handler before it continues with ``HookOutput/passthrough``; Swift cancellation is cooperative, so a handler that ignores it keeps the invocation pending until it returns. A late `block: true` result is ignored after the handler returns, preserving timeout-as-passthrough semantics without claiming a hard deadline. The clock is injectable for deterministic timeout tests:

```swift,no-build
import Foundation
import ManifoldRuntime

let testRegistry = HookRegistry(
    clock: ContinuousClock(),
    timeout: .milliseconds(50)
)
```

## Sanitize-only invariant on `preToolUse`

``HookOutput/updatedInput`` is **sanitize-only, not redirect**. A hook may narrow `read_file("./foo")` → `read_file("/sandbox/foo")` but must not rewrite the call's logical target. To refuse a call, set `block: true`.

The v1 invariant is **structural**: ``PreToolUseHookAdapter`` requires the sanitized JSON to have the same set of top-level keys as the original. A handler that changes the key shape has its `updatedInput` **dropped** (the original arguments are forwarded to dispatch) and a warning is logged. Tighter logical-target checks (matching specific `path`/`url`/`id` values) are deferred to v2 when host-specific tool schemas are available.

### Example: redacting a credentials field

```swift,no-build
import Foundation
import ManifoldRuntime

await registry.register(.preToolUse) { input in
    guard
        input.toolName == "post_message",
        let raw = input.toolArguments,
        let data = raw.data(using: .utf8),
        var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return .passthrough
    }

    // Keep the top-level keys intact (sanitize-only); just redact the value.
    if json["api_key"] != nil {
        json["api_key"] = "[REDACTED]"
    }

    guard
        let sanitized = try? JSONSerialization.data(withJSONObject: json),
        let updated = String(data: sanitized, encoding: .utf8)
    else {
        return .passthrough
    }
    return HookOutput(updatedInput: updated)
}
```

### Example: blocking a tool call outright

```swift,no-build
import ManifoldRuntime

await registry.register(.preToolUse) { input in
    if input.toolName == "delete_file" {
        return HookOutput(block: true, denyReason: "Destructive ops are off in this session.")
    }
    return .passthrough
}
```

`block: true` short-circuits the chain — later handlers do not run — and the dispatch loop returns a typed denial result to the model rather than calling the tool.

## `preCompact` — observational in v1

The `.preCompact` hook fires at the ``CompressionPolicy`` invocation in ``ConversationTurnExecutor``. v1 surfaces it for telemetry only: the registry runs handlers and emits ``ConversationEvent/hookFired(event:sessionID:)``, but `HookOutput.block` is **ignored** and compression always proceeds.

```swift,no-build
import ManifoldRuntime

await registry.register(.preCompact) { input in
    // Observational: log + measure. block: true is ignored in v1.
    print("preCompact firing for session \(input.sessionID)")
    return .passthrough
}
```

A future revision may let hooks transform the compression-bound context. For now, treat `preCompact` as a structured logging hook.

## `postGeneration` — the unified counterpart to `GenerationHook`

``ConversationRuntime`` has always offered post-turn observability through the separate ``GenerationHook`` protocol (the `generationHooks` init parameter). ``HookEvent/postGeneration`` (B.2) exposes the same completed-turn data through the registry, so a host standardised on the registry seam (`preToolUse`/`preCompact`) doesn't need to adopt a second protocol just for post-turn work:

```swift,no-build
import ManifoldRuntime

await registry.register(.postGeneration) { input in
    guard let turn = input.completedTurn else { return .passthrough }
    print("Turn finished for session \(turn.sessionID): \(turn.assistantMessage.content)")
    return .passthrough
}
```

Like `preCompact`, `postGeneration` is observational — `HookOutput.block` is ignored, since the turn has already committed and there is no mutation channel. It fires under the exact same conditions as `GenerationHook.postGeneration(_:)` — not on cancellation, a stream error, or an empty-response turn — and both seams can be registered simultaneously without double-firing anything (`generationHooks` and the registry are independent lists).

``SummarisationHook`` — the rolling-summarisation `GenerationHook` — exposes ``SummarisationHook/makeHookHandler()`` so its trigger can be registered on the unified seam instead of threaded through `generationHooks`:

```swift,no-build
import ManifoldRuntime

let summarisationHook = SummarisationHook(
    messageStore: store,
    backend: summarisationBackend,
    contextSizeProvider: { 8192 }
)
await registry.register(.postGeneration, handler: summarisationHook.makeHookHandler())

let runtime = ConversationRuntime(
    messageStore: store,
    inferenceService: inferenceService,
    hookRegistry: registry
)
```

`GenerationHook`/`CompletedTurn` remain public and fully supported — they retire only after downstream consumers migrate to the registry seam.

## Telemetry

Every invocation of every registered hook emits ``ConversationEvent/hookFired(event:sessionID:)`` regardless of outcome (passthrough, mutate, or block). Subscribe to ``ConversationRuntime/events`` if a host UI needs to surface hook activity.
