# Migration: conversation history moves onto `GenerationRuntimeHints.history` (#2312)

**Applies to:** anyone implementing a custom `InferenceBackend`, or code that
installed conversation history on a backend before calling `generate(…)`.

## Why

Under `manifold-server --parallel > 1`, one cached backend instance is shared
across concurrent requests. History used to be installed on that **instance
state** — `setStructuredHistory` / `setConversationHistory` /
`setToolAwareHistory` — in a step separate from `generate(…)`. Request B's
install could overwrite request A's before A consumed it, so a client could
receive **another client's answer** (a cross-client data leak). No lock fixes a
set-then-use protocol on shared state.

History now travels **per-call** on `GenerationRuntimeHints.history`, consumed
on the `generate(…)` call stack while the request body is built. There is no
shared mutable window to race on.

## What was removed

| Removed | Replacement |
|---------|-------------|
| `protocol ConversationHistoryReceiver` + `setConversationHistory(_:)` | `hints.history` (read `[StructuredMessage].flattenedHistory` for the `(role, content)` shape) |
| `protocol StructuredHistoryReceiver` + `setStructuredHistory(_:)` | `hints.history` (already `[StructuredMessage]`) |
| `protocol ToolCallingHistoryReceiver` + `setToolAwareHistory(_:)` | `hints.history` (read `[StructuredMessage].toolAwareHistory` for the tool-aware wire shape) |
| `SSECloudBackend.conversationHistory` / `.setConversationHistory` | `hints.history` |
| `ClaudeBackend.structuredHistory`, and the `setStructuredHistory` / `setToolAwareHistory` on the built-in cloud backends | `hints.history` |
| `ConversationHistoryReceiverContractMixin` / `StructuredHistoryReceiverContractMixin` (ManifoldBackendTestKit) | assert history behaviour via the request body or the backend's recorded hints |

## What was added (ManifoldContract)

- `GenerationRuntimeHints.history: [StructuredMessage]` — the per-request
  conversation history (default `[]`).
- Projections on `[StructuredMessage]`:
  - `.flattenedHistory -> [(role: String, content: String)]`
  - `.toolAwareHistory -> [ToolAwareHistoryEntry]`
  - `.containsToolParts -> Bool`
  - `.containsImages -> Bool`

## Migrating a custom backend

**Before** — history installed on instance state, read in `buildRequest`:

```swift
final class MyBackend: InferenceBackend, StructuredHistoryReceiver {
    private var history: [StructuredMessage] = []
    func setStructuredHistory(_ messages: [StructuredMessage]) { history = messages }

    func generate(prompt: String, systemPrompt: String?,
                  config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        let body = encode(history)   // reads shared instance state — racy under a shared instance
        …
    }
}
```

**After** — drop the conformance and read `hints.history`:

```swift
final class MyBackend: InferenceBackend {
    func generate(prompt: String, systemPrompt: String?,
                  config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        let body = encode(hints.history)          // per-call, on the stack
        // tool-aware wire shape:  hints.history.toolAwareHistory
        // flat (role, content):   hints.history.flattenedHistory
        …
    }
}
```

## `SSECloudBackend` subclasses

`buildRequest(prompt:systemPrompt:config:)` gained a trailing
`hints: GenerationRuntimeHints` parameter, and the
`CloudAdapterRouting.buildRequest` closure gained a trailing
`GenerationRuntimeHints` argument. Override the new shape and read
`hints.history` (and `hints.jsonMode` / `hints.structuredOutput`) from the
parameter rather than from `activeHints`. `activeHints` remains only for the
asynchronous stream-parse path (e.g. Ollama thinking markers).

## Companion backends

`manifold-mlx` / `manifold-llama` consume the pre-rendered prompt string and did
not adopt the receiver protocols, so no source change is required beyond a
rebuild against this version.
