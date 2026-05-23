# ``ManifoldRuntime``

Persistence ports, the conversation turn loop, and the hook + handoff machinery that sits between `ManifoldInference` and a host app's SwiftData store.

## Overview

`ManifoldRuntime` owns the surfaces that need a session record but no concrete persistence backend:

- **Ports** — ``MessageStore``, ``SessionStore``, ``EndpointStore``, ``SamplerPresetStore``, ``BenchmarkCache`` — protocol shapes that `ManifoldPersistenceSwiftData` (or any drop-in alternative) satisfies.
- **Use cases** — ``ConversationRuntime``, ``PromptContextPipeline``, ``ChatExportService``, ``SessionListService``.
- **Session-scoped tool contributors** — ``SessionToolSource``, ``HandoffToolSource``, the contract mixins consumers can use to ship their own.
- **Synchronous hooks** — ``HookRegistry``, ``HookEvent``, ``HookInput``, ``HookOutput`` — the host-mutation seam at `preToolUse` and `preCompact` decision points.

The four backend family targets (`ManifoldMLX`, `ManifoldLlama`, `ManifoldFoundation`, `ManifoldCloud`) and `ManifoldMCP` deliberately do **not** depend on `ManifoldRuntime` — they stay session-free. Persistence-aware orchestration lives here.

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
