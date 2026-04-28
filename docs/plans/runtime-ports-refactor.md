# Plan — `BaseChatRuntime` / ports refactor

This is a **plan document**, not implementation. It records the intended shape,
migration order, and review constraints before code lands so reviewers can
argue with the architecture instead of reverse-engineering it from the diff.

## Status

- Branch: `docs/runtime-ports-proposal`
- Scope: architecture and migration plan only
- Downstream consumers in view:
  - BaseChatKit demo app
  - ChatbotUI-iOS
  - Fireside

## Problem

BaseChatKit already has a strong inference boundary:

- `BaseChatInference` is storage-free and backend-agnostic.
- `BaseChatBackends` and `BaseChatMCP` depend on inference directly.
- `ChatPersistenceProvider` already decouples chat/session persistence from
  SwiftData for the main transcript flows.

But the app/runtime boundary is still mixed across `BaseChatCore`,
`BaseChatUI`, and `BaseChatUIModelManagement`:

- some UI flows still know about SwiftData directly
- app orchestration still lives in UI-owned view models
- model management still exposes `ModelContext` for benchmark persistence
- endpoint/settings flows still leak Core-era storage assumptions into
  UI-facing APIs

That shape is workable for the stock demo app, but it makes two other host
styles harder than they should be:

1. **ChatbotUI-iOS** wants mostly stock BCK behavior with a custom shell.
2. **Fireside** wants to use BCK as a subsystem inside a story/memory runtime,
   not adopt BCK's UI and persistence assumptions wholesale.

## What we are building

A new runtime-centered package split:

```text
BaseChatInference
  ^ used by BaseChatBackends, BaseChatMCP, BaseChatRuntime

BaseChatRuntime
  depends on BaseChatInference
  owns application use cases + ports only

BaseChatPersistenceSwiftData
  depends on BaseChatRuntime
  owns SwiftData schema, migrations, adapters, container/bootstrap helpers

BaseChatUI
  depends on BaseChatRuntime
  owns SwiftUI views and thin presentation adapters

BaseChatUIModelManagement
  depends on BaseChatUI + BaseChatRuntime
  owns optional model-management UI only

BaseChatCore
  temporary compatibility facade for one release cycle, then removed
```

The center of gravity moves from:

```text
ChatViewModel + SessionManagerViewModel + ModelContext-aware UI
```

to:

```text
BaseChatRuntime services + ports
```

with UI acting as a presentation layer rather than the application layer.

## Non-goals

- No SwiftData schema redesign unless the refactor forces a narrowly-scoped one.
- No expansion of `ChatViewModel` or `InferenceService` public API as a shortcut.
- No giant "misc runtime" bucket that simply replaces the current `BaseChatCore`
  overload with a new overload.
- No permanent direct `SwiftData`, `@Query`, or `ModelContext` usage in
  `BaseChatUI*` once the migration is complete.

## Design principles

| # | Principle | Why |
|---|-----------|-----|
| 1 | **Runtime owns use cases, not view state.** | Transcript/session/model orchestration should be reusable by the demo app, ChatbotUI-iOS, and Fireside. Focus state, scroll affordances, sheets, and draft text are UI concerns. |
| 2 | **SwiftData stays behind adapters.** | `BaseChatRuntime` must not expose `ModelContext`, `@Model` types, `@Query`, or migration internals. |
| 3 | **Prefer existing record/value types.** | `ChatSessionRecord`, `ChatMessageRecord`, and `APIEndpointRecord` already express the right direction: storage-neutral data at the boundary. |
| 4 | **Additive migration first.** | The fastest way to break consumers is a big rename/delete wave. Land runtime and adapter surfaces first, then move call sites. |
| 5 | **Secrets and network policy stay out of runtime.** | Keychain, `URLSession`, trust policy, OAuth, and remote process/network configuration belong in adapters. |
| 6 | **Context injection is a first-class port.** | Fireside needs a structured way to supply story, memory, and profile context without forking the chat runtime. |

## Proposed runtime surface

### Ports

- `SessionStore`
- `MessageStore` / `ConversationStore`
- `EndpointStore`
- `SamplerPresetStore`
- `ModelCatalog`
- `ModelDownloadCoordinator`
- `BenchmarkCache`
- `TitleGenerator`
- `GenerationContextProvider` / `PromptContextContributor`

### Use cases

- `ConversationRuntime`
- `SessionListService`
- `ModelManagementService`
- `PromptContextPipeline`

### Constraints

- `BaseChatRuntime` stays SwiftUI-free and Observation-free.
- Prefer `async/await`, `AsyncSequence`, and typed events over nested
  observable state.
- Runtime instances should be scene/window scoped, not hidden singletons.

## Current coupling hotspots to remove early

1. **UI-owned orchestration**
   - `ChatViewModel`
   - `SessionManagerViewModel`
   - `ModelManagementViewModel`

2. **SwiftData leakage in UI/model-management flows**
   - direct `@Query`
   - direct `ModelContext`
   - benchmark cache persistence via `ModelManagementViewModel.modelContext`

3. **Core/storage-shaped types leaking into UI/runtime APIs**
   - endpoint/settings flows that still assume SwiftData-backed Core models

These are the first seams to attack because they determine whether the runtime
is genuinely reusable or just a renamed copy of today's stack.

## Migration phases

### Phase 0 — freeze behavior and add guardrails

- Write characterization coverage for:
  - session CRUD, ordering, pagination
  - message paging and search/snippet semantics
  - model/endpoint selection restoration
  - first-message auto-rename behavior
- Add repo guardrails:
  - no new `SwiftData` imports in `BaseChatUI*`
  - no new `@Query` / `.modelContext` usage in UI targets
  - no new UI-facing APIs that expose Core/storage-only types

### Phase 1 — define runtime contracts

- Inventory current logic in:
  - `ChatViewModel`
  - `SessionManagerViewModel`
  - `ModelManagementViewModel`
  - `SessionController`
  - model load/generation coordinators
- Separate each path into:
  - runtime orchestration
  - persistence adapter work
  - presentation-only state
- Land the new contracts additively before moving behavior.

### Phase 2 — create `BaseChatRuntime`

- Add the new target.
- Move or re-home runtime-owned protocols into it.
- Introduce runtime-facing endpoint/settings abstractions where UI still depends
  on storage-shaped models.
- Keep compatibility shims in `BaseChatCore`.

### Phase 3 — peel orchestration out of UI view models

- Extract transcript/session/send-cancel-regenerate/model-selection logic into
  runtime services.
- Extract session list CRUD/search/pagination/title generation into runtime.
- Extract model discovery/search/download orchestration into runtime.

Deliverable: `BaseChatUI` and `BaseChatUIModelManagement` become thin adapters
over runtime services instead of owning application logic.

### Phase 4 — create `BaseChatPersistenceSwiftData`

- Move SwiftData assets out of `BaseChatCore`:
  - persistence providers
  - schema/model types
  - migrations
  - container/bootstrap helpers
  - endpoint/preset/benchmark persistence adapters
- Keep endpoint metadata separate from secret references.
- Preserve stable Keychain identifier mapping throughout the move.

### Phase 5 — remove direct SwiftData usage from UI packages

- Replace direct `@Query`, `ModelContext`, and mutation of SwiftData models in:
  - `BaseChatUI`
  - `BaseChatUIModelManagement`
- Route endpoints, presets, and benchmark persistence through runtime and
  persistence ports.

### Phase 6 — migrate host apps

- Migrate the **BaseChatKit demo app** first using the stock composition path.
- Validate **ChatbotUI-iOS** as the "mostly stock BCK, custom shell" consumer.
- Validate **Fireside** as the "custom domain/runtime, BCK as subsystem"
  consumer via context contributors and app-owned stores.

### Phase 7 — compatibility cleanup

- Keep `BaseChatCore` as a deprecated facade for one release cycle.
- Publish a migration guide with three recipes:
  - stock UI app
  - custom shell app
  - runtime-only / domain-owned integration
- Remove the facade only after parity and downstream adoption are proven.

## Review feedback folded into this plan

### Architect

- The refactor only counts if UI stops knowing SwiftData exists.
- Do not turn `BaseChatRuntime` into a new junk drawer.
- Remove storage-shaped endpoint/settings leakage early.

### DevEx

- Keep the rollout additive.
- Preserve a one-snippet quick start via a stock composition API/container.
- Use `BaseChatCore` as a temporary compatibility umbrella rather than a hard cut.

### QA

- "It compiles" is not a sufficient success signal.
- Add contract tests for each new runtime port and SwiftData adapter.
- Use differential tests to compare old and new behavior during the migration.
- Gate completion on demo app and downstream consumer smoke coverage.

### Security

- Keep raw secrets, Keychain APIs, `URLSession`, trust delegates, and remote
  execution/network policy out of runtime.
- Treat context injection as a trust boundary.
- Preserve endpoint metadata vs secret separation through the migration.

### Apple / Swift / AI platform review

- Keep runtime SwiftUI-free and Observation-free.
- Prefer async/evented APIs with thin `@Observable` presentation adapters.
- Avoid hidden singletons; scope runtime to app or scene composition.

## Acceptance criteria

Before calling the refactor done:

- Existing CI-safe suites still pass.
- New runtime contract suites pass for fakes and SwiftData adapters.
- Differential behavior checks pass across old vs new chat/session wiring.
- Demo app smoke coverage passes.
- ChatbotUI-iOS builds and passes agreed smoke flows without local patching.
- Fireside proves story/memory/profile context injection via runtime ports.
- Legacy persisted data opens without loss of sessions, messages, search
  behavior, settings, or pinned-message semantics.
- No meaningful regression in large-history pagination or search behavior.

## Hard no-gos

- No `SwiftData` or `ModelContext` in `BaseChatRuntime`.
- No SwiftUI or `@Observable` in `BaseChatRuntime`.
- No public runtime APIs that expose raw secret material.
- No permanent dual path where UI uses both runtime ports and direct SwiftData.
- No migration that relies on widening public API just to keep the refactor
  moving.

## Why this is worth doing

If this refactor succeeds:

- the **demo app** remains the reference implementation
- **ChatbotUI-iOS** gets a cleaner customization surface without forking BCK
- **Fireside** can use BCK runtime/inference as a subsystem without inheriting
  BCK's UI and persistence assumptions

That is the architectural payoff: one runtime center, multiple host shapes,
and less pressure to push app logic into UI modules just because those modules
currently own the composition story.
