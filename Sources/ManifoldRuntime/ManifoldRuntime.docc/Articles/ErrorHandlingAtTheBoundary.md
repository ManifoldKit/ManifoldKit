# Error handling at the boundary

What a consumer can actually catch at the four public entry points, and the one-line contract that lets you write a single catch site instead of dozens.

## Overview

ManifoldKit has roughly 50 public `Error`-conforming types, but the overwhelming majority of them never reach a consumer directly — they are caught and folded into a smaller type before crossing a public boundary. This article enumerates the types that *do* escape, at the four surfaces most app code actually calls:

- ``ConversationRuntime/processTurn(_:)`` / ``ConversationRuntime/processTurnWithOutcome(_:)``
- `ChatViewModel.respond(to:)` / `QuickStartResult.respond(_:)` / `QuickStartResult.respond(to:)` (all three forward to `ChatViewModel.sendMessage(_:)`)
- `ManifoldKit.quickStart(configuration:)`
- `InferenceService.enqueue(...)` / `InferenceService.generate(...)` (via the returned `GenerationStream.events`), plus its typed `InferenceService.respond(_:to:config:)` sibling on the same service

Every one of these types conforms to `BackendError` — `LocalizedError & Sendable` plus `var isRetryable: Bool`. That is the whole contract: **catch `BackendError` once, branch on `isRetryable`, and you have handled every escapable failure from every boundary** without switching on a dozen unrelated concrete types.

> Note: This contract is scoped to the four chat-path surfaces above. The media-generation runtimes (`ImageGenerationRuntime` / `VideoGenerationRuntime` / `AudioGenerationRuntime`, whose public event streams surface `ImageGenerationServiceError` / `VideoGenerationServiceError` / `AudioGenerationServiceError`) and `EmbeddingBackend.embed(_:)` (`EmbeddingError`) are separate public boundaries whose error types do not yet conform to `BackendError`.

## The escapable-types table

| Boundary | Type | Escape path | Conformed before this audit? |
|---|---|---|---|
| `InferenceService.enqueue` / `.generate` | `InferenceError` | Thrown directly by backends (`FoundationBackend`, `RouterBackend`, retry/idle-timeout paths) and rethrown raw by `GenerationToolDispatchLoop.run(...)`'s `catch { throw error }`, which `GenerationQueue`'s per-request `Task` feeds into `continuation.finish(throwing:)` for the returned `GenerationStream.events`. | Yes |
| `InferenceService.enqueue` / `.generate` | `CloudBackendError` | Same path — thrown directly by the cloud backends (`ClaudeBackend`, `OpenAIBackend`, `OpenAIResponsesBackend`, `OllamaBackend`) for auth/rate-limit/server/network failures, sanitized through `CloudErrorSanitizer` (message text only — the type is untouched) before the `.serverError` case is constructed. | Yes |
| `InferenceService.enqueue` / `.generate` (mainline — any Ollama/CloudSaaS backend) | `RetryExhaustedError` | `SSEGenerationTaskRunner.openConnection(streamBox:)` (shared cloud infra, `ManifoldCloudCore`) wraps connection attempts in `withRetry(strategy:sleeper:operation:)`; when the strategy's retry budget runs out, `withRetry` throws `RetryExhaustedError`, and the runner's outer `catch` rethrows it raw (`continuation.finish(throwing: error)` — no rewrap into `CloudBackendError`). | No |
| `InferenceService.enqueue` / `.generate` (opt-in — only when the host wires `FallbackBackend`) | `FallbackExhaustedError` | Thrown by `FallbackBackend` when every backend in the chain fails, aggregating each attempt's error in order. | Yes (conforms at its own declaration in `FallbackBackend.swift`, not via the shared extension file) |
| `InferenceService.enqueue` / `.generate` (opt-in — only when the host wires `AnyLanguageModelBackend`) | `AnyLanguageModelBridgeError` | `AnyLanguageModelBackend.generate` (in the separate `ManifoldAnyLanguageModel` product, never re-exported by the `ManifoldKit` umbrella) throws it directly for capability/configuration mismatches. | No |
| `InferenceService.respond(_:to:config:)` (typed structured-output sibling of `enqueue`/`generate`) | `StructuredOutputError` | Thrown directly by the structured-output round-trip (schema encode failure, decode failure, or the bounded reask loop exhausting its budget). | No |
| `ConversationRuntime.processTurn(_:)` / `.processTurnWithOutcome(_:)` | `ConversationError` | Thrown synchronously by `ConversationTurnExecutor` for preconditions (`.messageTooLarge`, `.persistence`, `.noAssistantMessageToRegenerate`, `.messageNotFound`) and delivered via `ConversationEvent.errorRaised(_:)` → `ChatGenerationCoordinator`'s `.failed(error)` turn state for async faults (`.inference`, `.contextAssembly`, `.preTurnCompressionFailed`, `.cancelled`). | No |
| `ChatViewModel.sendMessage(_:)` (and every `respond` overload) | `SendMessageError` | Thrown directly for preconditions (`.noActiveSession`, `.noModelLoaded`), for a content-free turn (`.empty`), or wrapping whatever `ConversationRuntime` surfaced (`.runtime(any Error)` — typically a `ConversationError`). | No |
| `ManifoldKit.quickStart(configuration:)` | `ManifoldKitError` | Every error raised during assembly is reduced through `ManifoldKitError.from(_:)` before the facade rethrows (`QuickStart.swift`); `.noBackendsRegistered` is also thrown directly as a fail-fast diagnostic. This is the one boundary where the escapable set is a single type by construction. | No |

`InferenceError`, `CloudBackendError`, and `FallbackExhaustedError` already conformed to `BackendError` before this audit. The other five (`RetryExhaustedError`, `AnyLanguageModelBridgeError`, `StructuredOutputError`, `ConversationError`, `SendMessageError`, `ManifoldKitError` — six, not five; see the table) gained the conformance as part of this pass, each with a documented `isRetryable` reasoning on its own doc comment. Three of them (`ConversationError`'s four wrapping cases, `SendMessageError.runtime`, `RetryExhaustedError.lastError`) *defer* to a boxed underlying error's own `isRetryable` when it also conforms to `BackendError`, rather than guessing.

## The catch-order recommendation

```swift,no-build
do {
    let reply = try await kit.respond(to: userText)
} catch let backendError as any BackendError {
    if backendError.isRetryable {
        // Transient — show a "retry" affordance using
        // backendError.errorDescription.
    } else {
        // Permanent or precondition — surface errorDescription and stop.
    }
} catch is CancellationError {
    // Cooperative cancellation — not a failure, no error UI.
} catch {
    // Should not happen at a documented boundary (see "the uncontrolled
    // exceptions" below) — treat as non-retryable and log.
}
```

Order matters: `CancellationError` (Swift's own stdlib type) is not folded into `BackendError` — see below — so check it explicitly rather than assuming a `BackendError` catch covers cancellation implicitly. `ConversationError.cancelled` and `SendMessageError` do **not** wrap raw `CancellationError` themselves; they carry their own `.cancelled`/precondition cases that already conform to `BackendError`, so the plain `CancellationError` case only shows up when it propagates untouched through `InferenceService.enqueue`/`.generate`'s stream.

`ConversationRuntime.processTurn(_:)` has a second wrinkle: `ConversationError` reaches consumers two ways, and a single `do/catch` only sees one of them. Precondition failures (`.messageTooLarge`, `.persistence`, `.noAssistantMessageToRegenerate`, `.messageNotFound`) throw synchronously, before a stream handle is ever returned. Generation-time failures (`.inference`, `.contextAssembly`, `.preTurnCompressionFailed`, `.cancelled`) are delivered *after* `processTurn` has already returned successfully, via `ConversationEvent.errorRaised(_:)` on the event stream or `ConversationTurnHandle/outcome`. Catching at the call site handles the first class; observing `.errorRaised` (or awaiting `outcome`) handles the second. Both paths carry a `ConversationError`, so the same `BackendError` branch works in both places.

## The contract: everything else arrives wrapped in one of these

Types that looked like escape candidates but turned out to be caught and wrapped before any of the four boundaries:

- **Tool-call failures** — `MCPError`, `WebSearchRuntimeError`, `SkillDispatchError`/`SkillReferenceError`, `HandoffSourceError`, and any other `ToolExecutor` conformer's thrown error are all caught by `ToolRegistry.dispatch(_:)` and reduced to a `ToolResult` with an `errorKind` (`.permanent`, `.transient`, `.cancelled`, …). They never rethrow past the tool-dispatch loop, so they cannot reach `InferenceService.enqueue`/`.generate` as a thrown error.
- **Turn-preparation plumbing** — `TurnPreparationFailure` and `HistoryShaperValidationError` are both `private` to `ConversationTurnExecutor`. Even though a `HistoryShaperValidationError` value can end up as the underlying payload of `ConversationError.contextAssembly(any Error)`, external code cannot name the private type to pattern-match it — it is only visible as an opaque `any Error` inside the already-conforming `ConversationError`.
- **`RAGError`** from context assembly is folded into `ConversationError.contextAssembly(any Error)` the same way.
- **`EndpointStoreError` / `ModelDiscoveryError`** encountered during `quickStart`'s auto-select and registry-refresh steps are caught, logged, and defaulted — never thrown — so the facade degrades gracefully instead of failing assembly over a non-fatal lookup.
- **`KeychainError`** is string-matched inside `ManifoldKitError.from(_:)` and reduced to `.keychainUnavailable`.
- **Background seed downloads** — `HuggingFaceError` raised during `quickStart(seed:)`'s best-effort model download is logged and skipped, never thrown; the facade launches with no model selected instead.

## The uncontrolled exceptions

Two escapable cases are **not** part of the `BackendError` spine, deliberately:

- **`CancellationError`** (Swift's own stdlib type) is thrown directly by `GenerationQueue` on cancellation and propagates through `InferenceService.enqueue`/`.generate`'s stream. We do not retroactively conform a stdlib type to our protocol — Swift's own `catch is CancellationError` convention already covers it, and every ManifoldKit-owned wrapper (`ConversationError.cancelled`, and the queue's own cancellation bookkeeping) already gives it a dedicated, `BackendError`-conforming case at the layers above the raw stream.
- **Apple's `FoundationModels` framework error** escapes `FoundationBackend` raw: its generation task's `catch { ...; continuation.finish(throwing: error) }` (`FoundationBackend.swift`) forwards whatever `LanguageModelSession` throws unmodified, because catching and reducing an OS framework's error taxonomy to a string (the way `ManifoldKitError.from(_:)` treats `URLError`) was judged not worth the fidelity loss for a backend gated to iOS 26 / macOS 26+ only. Consumers driving `FoundationBackend` directly through `InferenceService.enqueue`/`.generate` should keep a generic `catch` after the `BackendError` case for this reason.
