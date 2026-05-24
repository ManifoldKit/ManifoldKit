# ``ManifoldRuntime``

Persistence-port protocols and the turn-loop orchestration shell that sits between `ManifoldInference` and a host app's storage layer.

## Overview

`ManifoldRuntime` is the session-aware orchestration tier of ManifoldKit. It owns the surfaces that need a session record but no concrete persistence backend:

- **Ports** — ``MessageStore``, ``SessionStore``, ``EndpointStore``, ``SamplerPresetStore``, ``BenchmarkCache`` — protocol shapes that `ManifoldPersistenceSwiftData` (or any drop-in alternative) satisfies.
- **Turn-loop runtime** — ``ConversationRuntime`` composes the ports into the canonical send / regenerate / edit / branch / cancel pipeline and surfaces lifecycle as ``ConversationEvent`` values.
- **Use cases** — ``PromptContextPipeline``, ``ChatExportService``, ``SessionListService``.
- **Session-scoped tool contributors** — ``SessionToolSource``, ``HandoffToolSource``, plus the contract mixins consumers can use to ship their own.
- **Synchronous hooks** — ``HookRegistry``, ``HookEvent``, ``HookInput``, ``HookOutput`` — the host-mutation seam at `preToolUse` and `preCompact` decision points.

The four backend family targets (`ManifoldMLX`, `ManifoldLlama`, `ManifoldFoundation`, `ManifoldCloud`) and `ManifoldMCP` deliberately do **not** depend on `ManifoldRuntime` — they stay session-free. Persistence-aware orchestration lives here.

## When to use this module

Import `ManifoldRuntime` directly when:

- You are building a host shell that drives the turn loop from your own UI layer (not ``ChatView``) and need a single entry point for `send` / `regenerate` / `edit` / `cancel` / `branch`.
- You want to swap in a custom ``MessageStore`` or ``SessionStore`` adapter — for example to log every write to an audit sidecar, or to back chat history with something other than SwiftData.
- You need to install a ``HookRegistry`` (mutate tool calls before they run, redact compaction prompts, etc.) or register a ``SessionToolSource`` that contributes per-session tool descriptors.
- You want to consume the ``ConversationEvent`` lifecycle stream directly — `.userMessageInserted`, `.assistantStreaming`, `.contextAssembled`, `.turnCompleted`, etc.

## When not to use this module

- **You only need to call a backend.** ``InferenceService``, ``Backend``, and ``GenerationConfig`` live in `ManifoldInference`. The runtime adds session, persistence, and hooks on top — if you have none of those, skip the runtime and drive the backend directly.
- **You are happy with the shipped SwiftUI chat shell.** ``ChatView`` and ``ChatViewModel`` already configure a ``ConversationRuntime`` for you via ``ManifoldBootstrap``; you only need to touch this module if you are driving the runtime yourself.
- **You want a backend.** Backend family targets do not import `ManifoldRuntime`. Importing this module from inside a backend creates a layering cycle.

## Beyond chat

`ConversationRuntime` is named for its most common use case but is best understood as a **session-scoped turn-loop shell**: it persists writes, assembles context, calls a ``Backend``, streams events, and tears down on cancel. Anything that fits that shape — interactive agents, classification pipelines that need to record prompts, voice-driven flows, image-generation runs (see ``ImageGenerationRuntime``) — can sit on top of these ports without dragging in `ChatView`. The "chat" word in the surface area names is historical; the orchestration shell is general.

## The 3–5 most-used types

### Construct a `ConversationRuntime` against custom ports

The runtime composes ports you supply. The minimum surface is a ``MessageStore`` and an ``InferenceService``; everything else is optional and unlocks specific features:

```swift,no-build
import ManifoldInference
import ManifoldRuntime

let runtime = ConversationRuntime(
    messageStore: myMessageStore,           // required
    sessionStore: mySessionStore,           // optional — touches updatedAt on send
    inferenceService: InferenceService(),   // required
    pipeline: nil,                          // optional context assembler
    usageStore: myUsageStore,               // optional — per-turn token cost
    sessionToolSources: [mySessionToolSource],
    hookRegistry: HookRegistry()
)

// Drain events on a long-lived task. The stream is single-consumer and caps
// at 500 buffered events; an unread stream will drop newest arrivals first.
Task {
    for await event in runtime.events {
        print(event)
    }
}
```

### Send a turn

`processTurn(_:)` is the canonical entry point — build a ``TurnInput`` with the appropriate ``TurnKind`` (`.send`, `.regenerate`, `.edit`, `.branch`) and a shared ``TurnConfig``:

```swift,no-build
let input = TurnInput(
    sessionID: sessionID,
    kind: .send(text: "Summarise the attached document."),
    config: TurnConfig(
        modelDescriptor: descriptor,
        backend: backend,
        generationConfig: GenerationConfig(temperature: 0.7)
    )
)

let handle = try await runtime.processTurn(input)
// `handle` exposes cancel + completion; events arrive on `runtime.events`.
```

The legacy per-flow methods (`send`, `regenerate`, `edit`, `branch`) are deprecation shims and forward to `processTurn(_:)`.

### Implement a custom `MessageStore`

The simplest adapter persists writes to your own storage and returns ``ChatMessageRecord`` values. Hooks registered via ``MessageStore/addPostWriteHook(_:)`` fire after every commit:

```swift,no-build
@MainActor
final class AuditedMessageStore: MessageStore {
    private let inner: any MessageStore
    private var hooks: [@MainActor (ChatMessageRecord) async -> Void] = []

    init(wrapping inner: any MessageStore) { self.inner = inner }

    func insertMessage(_ message: ChatMessageRecord) async throws {
        try await inner.insertMessage(message)
        Log.audit.notice("inserted \(message.id, privacy: .public)")
        for hook in hooks { await hook(message) }
    }
    // ...remaining MessageStore methods forward to `inner`...
}
```

### Implement a custom `SessionStore`

`SessionStore` and `MessageStore` are deliberately split — implement one or both. Common pattern: a host that owns sessions in its own database conforms to `SessionStore` only and lets `ManifoldPersistenceSwiftData` handle the messages.

```swift,no-build
@MainActor
final class RemoteSessionStore: SessionStore {
    func insertSession(_ session: ChatSessionRecord) async throws { /* POST /sessions */ }
    func updateSession(_ session: ChatSessionRecord) async throws { /* PATCH /sessions/{id} */ }
    func deleteSession(_ sessionID: UUID) async throws { /* DELETE /sessions/{id} */ }
    func fetchSessions() async throws -> [ChatSessionRecord] { /* GET /sessions */ [] }
    func session(for id: UUID) async throws -> ChatSessionRecord? { /* GET /sessions/{id} */ nil }
}
```

### Manage cloud API endpoints

``EndpointStore`` replaces direct SwiftData queries for cloud-endpoint CRUD. Keychain lifecycle is **not** the store's job — the store deletes the endpoint row; callers delete the matching Keychain item via `KeychainService.delete(account:)`:

```swift,no-build
let endpoints = try await endpointStore.fetchEndpoints()
try await endpointStore.insertEndpoint(
    APIEndpointRecord(name: "Production OpenAI", baseURL: openAIURL, ...)
)
```

## Topics

### Articles

- <doc:AgentHandoffs>
- <doc:HookSystem>

### Conversation runtime

- ``ConversationRuntime``
- ``ConversationEvent``
- ``ConversationStreamHandle``

### Session-scoped tool sources

- ``SessionToolSource``
- ``HandoffToolSource``
- ``HandoffSourceError``

### Hook system

- ``HookRegistry``
- ``HookEvent``
- ``HookInput``
- ``HookOutput``
- ``PreToolUseHookAdapter``

### Persistence ports

- ``MessageStore``
- ``SessionStore``
- ``EndpointStore``
- ``SamplerPresetStore``
- ``BenchmarkCache``
