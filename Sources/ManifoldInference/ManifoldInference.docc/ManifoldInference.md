# ``ManifoldInference``

Inference orchestration for ManifoldKit — protocols, models, and services that
coordinate model loading, generation, context budgeting, and prompt assembly.

## Overview

`ManifoldInference` contains the inference surface area of ManifoldKit:
``InferenceService`` and the `InferenceBackend` protocol family, generation
events and streams, context window management, prompt templates and assembly,
macro expansion, repetition detection, tokenizers, and the
capability/compatibility API.

`ManifoldInference` is the lowest production layer in ManifoldKit (apart from
`ManifoldTestSupport`). It carries no SwiftData schema, no SwiftUI views, no
ML dependencies, and no concrete inference backends — those live in higher
layers:

- `ManifoldRuntime` adds persistence-agnostic ports and use cases.
- `ManifoldPersistenceSwiftData` adds the shipped SwiftData schema and
  ``ManifoldBootstrap`` entry point.
- `ManifoldBackends` re-exports the concrete MLX, llama.cpp, Foundation, and
  cloud backends. The MLX and llama.cpp families depend on `ManifoldInference`
  directly; the Foundation and cloud families were repointed to `ManifoldContract`
  (the thin protocol kernel) in v0.40+ so they stay free of engine internals and
  SwiftData.

Apps that bring their own persistence and UI can depend on this target alone
to integrate a custom backend or drive a custom chat surface.

For the source-backed operational contract around loading, streaming, memory handling, cancellation, and pinning, see [`docs/RELIABILITY.md`](../../../docs/RELIABILITY.md).

## When to use this module

Import `ManifoldInference` directly when:

- You are writing a custom ``InferenceBackend`` conformer and need the protocol
  shape, ``GenerationConfig``, and ``GenerationStream`` without pulling in any
  backend family or ML dependency.
- You are building a host shell that drives generation directly — enqueue
  messages through ``InferenceService``, drain the ``GenerationStream``, and
  handle ``GenerationEvent`` values in your own turn loop.
- You need the image-generation value types (``ImageGenerationConfig``,
  ``ImageGenerationEvent``, ``ImageModelInfo``) in a non-MLX target — for
  example a catalog UI, a persistence adapter, or a cloud image service.
- You want the conversation record types (``ChatMessageRecord``,
  ``ChatSessionRecord``) without dragging in SwiftData or any UI layer.
- You are writing a backend test and need ``BackendCapabilities`` or the
  ``BackendContractChecks`` conformance harness.

## When not to use this module

- **You want a turn loop with persistence.** ``ConversationRuntime`` in
  `ManifoldRuntime` adds session scoping, message store writes, hooks, and the
  reliable ``ConversationTurnHandle/outcome`` handle on top. Use `ManifoldRuntime`
  when you need any of those.
- **You want the full chat shell.** ``ManifoldBootstrap`` and ``ChatView``/
  ``ChatViewModel`` in `ManifoldUI` configure everything for you. Touch
  `ManifoldInference` only when building outside that shell.
- **You want a concrete backend.** MLX, llama.cpp, Foundation, and cloud
  backends live in their own family targets. This module only declares the
  protocols they conform to.

## Beyond chat

``InferenceService`` is named for its most common use case but is more
general: it is a backend-agnostic request queue that serialises streaming
generation calls through a priority-ordered FIFO, routes them to the loaded
backend, and emits ``GenerationEvent`` values. Any pipeline that fits that
shape — tool-call orchestrators, classification workers, document summarisers,
image-generation runs (``ImageGenerationService``), voice prompt assembly —
can drive ``InferenceService`` directly without touching chat UI.

The same is true of ``InferenceBackend``: backend authors implement this
protocol to add new inference engines (local or remote) without touching any
persistence or UI layer.

## The 3–5 most-used types

### `InferenceBackend` — write a custom backend

Adopt ``InferenceBackend`` to plug a new engine into the framework. The
minimum conformance is four methods; the rest have no-op defaults:

```swift,no-build
import ManifoldInference

final class MyBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded: Bool = false
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities {
        BackendCapabilities(
            maxContextTokens: 4096,
            supportsSystemPrompt: true
        )
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        // Load weights, initialise runtime.
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        GenerationStream { continuation in
            isGenerating = true
            continuation.yield(.token("Hello "))
            continuation.yield(.token("world"))
            continuation.finish()
            isGenerating = false
        }
    }

    func stopGeneration() { /* signal the loop */ }
    func unloadModel() { isModelLoaded = false }
}
```

Register the conformer via `InferenceService.registerBackendFactory` at app
start, or pass it directly to `InferenceService(backend:)` in tests.

### `GenerationConfig` — tune sampling parameters

``GenerationConfig`` is the single value type handed to every generation call.
Most fields default to sensible values and non-honoured fields are silently
ignored by each backend:

```swift,no-build
import ManifoldInference

let config = GenerationConfig(
    temperature: 0.8,
    topP: 0.95,
    maxOutputTokens: 1024,
    // Disable chain-of-thought for a backend that loads a thinking model.
    maxThinkingTokens: 0
)

let (token, stream) = try inferenceService.enqueue(
    messages: [.system("You are a concise assistant."), .user("Summarise this.")],
    config: config
)

for try await event in stream {
    if case .token(let chunk) = event {
        print(chunk, terminator: "")
    }
}
```

The `llamaDRY`, `llamaXTC`, and `llamaMirostatV2` fields are llama.cpp-only;
all other backends silently ignore them.

### `GenerationEvent` — consume the token stream

``GenerationEvent`` is the typed event emitted by every backend. The most
commonly handled cases are:

```swift,no-build
import ManifoldInference

for try await event in stream {
    switch event {
    case .token(let chunk):
        responseText += chunk
    case .thinkingToken(let chunk):
        thinkingText += chunk
    case .thinkingCompleted:
        showThinkingBubble(thinkingText)
    case .toolCall(let call):
        let result = try await myToolRegistry.dispatch(call)
        // The queue re-prompts automatically; you only need to observe.
    case .usage(let prompt, let completion):
        updateTokenCounter(prompt: prompt, completion: completion)
    default:
        break
    }
}
```

Pattern-match consumers must handle or default-case every case — the enum is
exhaustive and new cases are source-breaking. Use `default:` when you only care
about a subset.

### `ImageGenerationConfig` and `ImageGenerationEvent` — image pipelines

The image-generation value types live in `ManifoldInference` (not in
`ManifoldMLX`) so any module — catalog UI, persistence, cloud image service —
can reference them without pulling in ML dependencies:

```swift,no-build
import ManifoldInference
import ManifoldMLX

let backend = FluxDiffusionBackend()
try await backend.loadModel(from: weightsURL)

let config = ImageGenerationConfig(
    steps: 4,           // distilled model — 4 steps is enough
    width: 1024,
    height: 1024,
    seed: 42,
    outputDirectory: FileManager.default.temporaryDirectory
)

let stream = try await backend.generate(prompt: "a red fox in the snow", config: config)
for try await event in stream {
    switch event {
    case .progress(let step, let total):
        progressView.update(step: step, total: total)
    case .completed(let url):
        imageView.image = NSImage(contentsOf: url)
    }
}
```

For apps that swap models at runtime, use ``ImageGenerationService`` instead —
it manages backend lifecycle and arbitrates against the text-inference resource
pool.

### `ChatMessageRecord` — cross-boundary message snapshot

``ChatMessageRecord`` is a plain `Sendable` value type that crosses persistence
boundaries. It carries no SwiftData, no CoreData, and no UI. Use it to pass
message data between layers without coupling them:

```swift,no-build
import ManifoldInference

// Construct a record the persistence layer can store.
let record = ChatMessageRecord(
    sessionID: sessionID,
    role: .assistant,
    content: [.text(responseText)],
    modelName: "llama-3.2-3b"
)

// Persistence adapters receive this type — no SwiftData import needed here.
try await myMessageStore.insertMessage(record)
```

## Topics

### Configuration

- ``ManifoldConfiguration``

### Inference orchestration

- ``InferenceService``
- ``InferenceBackend``
- ``BackendCapabilities``

### Conversation records

- ``ChatMessageRecord``
- ``ChatSessionRecord``
- ``MessageRole``
- ``MessagePart``

### Generation

- ``GenerationEvent``
- ``GenerationStream``
- ``GenerationConfig``

### Image generation

The image-generation value types live here (not in `ManifoldMLX`) so non-MLX
modules — catalog UIs, persistence, runtime — can reference them without
pulling in a backend family. Concrete backends (``MLXDiffusionBackend``,
``FluxDiffusionBackend``) live in `ManifoldMLX`; see that module's
documentation for the high-level vs. direct-backend chooser.

- ``ImageGenerationBackend``
- ``ImageGenerationService``
- ``ImageGenerationConfig``
- ``ImageGenerationEvent``
- ``ImageModelInfo``
- ``ImageModelFormat``
- ``PrecisionVariant``
