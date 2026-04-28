# Plan — `BaseChatRuntime` / ports refactor

This is a **plan document**, not implementation. It records the intended shape,
migration order, and review constraints before code lands so reviewers can
argue with the architecture instead of reverse-engineering it from the diff.

## Status

- Branch: `docs/runtime-ports-proposal`
- Scope: architecture and migration plan only
- Window: **pre-1.0** — break public API freely; no compatibility tail
- Downstream consumers in view:
  - BaseChatKit demo app
  - ChatbotUI-iOS
  - Fireside

## Problem

BaseChatKit already has a strong inference boundary:

- `BaseChatInference` is storage-free and backend-agnostic.
- `BaseChatBackends` and `BaseChatMCP` depend on inference directly.
- `ChatPersistenceProvider` decouples session/message persistence from
  SwiftData via storage-neutral records (`ChatSessionRecord`,
  `ChatMessageRecord`, `APIEndpointRecord` — all hosted in
  `BaseChatInference`).

But the app/runtime boundary is still mixed across `BaseChatCore`,
`BaseChatUI`, and `BaseChatUIModelManagement`. The concrete leaks:

- `SamplerPresetPickerView` uses `@Query(sort: \SamplerPreset.createdAt)`
  directly against the SwiftData `@Model`.
- `ModelManagementViewModel.modelContext: ModelContext?` is a public
  property that hands the SwiftData store to host code.
- `APIConfigurationView` and `ModelManagementSheet` `import SwiftData`
  for endpoint editor flows.
- Application orchestration (`ChatViewModel`, `SessionManagerViewModel`,
  `ModelManagementViewModel`) is intertwined with `@Observable`
  presentation state. `ChatViewModel.swift:608–708` wires its coordinators
  via ~50 closure callbacks — orchestration and presentation share
  storage instead of communicating across a typed boundary.

Three host shapes pay the cost:

1. **BaseChatKit demo app** — fine today, but cannot evolve without
   pulling other consumers along.
2. **ChatbotUI-iOS** — wants stock BCK behavior with a custom shell.
3. **Fireside** — wants BCK as a subsystem inside a story/memory runtime.
   Already integrates by importing `InferenceService` + `ChatPersistenceProvider`
   directly and writing its own bootstrap; this works but inherits
   `BaseChatCore`'s SwiftData surface unwillingly.

## What we are building

A runtime-centered package split. **Pre-1.0**, so this is a hard cut, not
a deprecation cycle.

```text
                    BaseChatInference
                          ▲
            ┌─────────────┼──────────────────┐
            │             │                  │
   BaseChatBackends  BaseChatMCP      BaseChatRuntime
                                            ▲
                          ┌─────────────────┼──────────────────┐
                          │                 │                  │
                BaseChatPersistence-   BaseChatUI    BaseChatUIModelManagement
                   SwiftData               ▲                   │
                                           └───────────────────┘
                                                (one-way edge,
                                                 already CI-enforced)
```

The center of gravity moves from
`ChatViewModel + SessionManagerViewModel + ModelContext-aware UI`
to `BaseChatRuntime` use cases + ports, with UI as a presentation layer
rather than the application layer.

### Target naming

- The existing `public final class BaseChatRuntime` in
  `Sources/BaseChatCore/BaseChatRuntime.swift` is renamed to
  `BaseChatBootstrap` (a file by that name already exists in the same
  directory — it absorbs the rename).
- The new target is `BaseChatRuntime`.
- `BaseChatCore` is **deleted**, not deprecated. Its current contents
  redistribute: persistence implementation → `BaseChatPersistenceSwiftData`,
  storage-neutral helpers → `BaseChatRuntime`, intent protocols →
  `BaseChatRuntime`. Host apps update their imports in one PR.

### Where today's pieces land

| Today | Lands in |
|-------|----------|
| `BaseChatCore` SwiftData `@Model` types + schema | `BaseChatPersistenceSwiftData` |
| `SwiftDataPersistenceProvider` | `BaseChatPersistenceSwiftData` |
| `ChatPersistenceProvider` protocol | `BaseChatRuntime` |
| `BaseChatRuntime` (bootstrap class) | `BaseChatRuntime` (renamed `BaseChatBootstrap`) |
| `ChatExportService` / `ConversationExporter` | `BaseChatRuntime` |
| `ChatIntentAction` / `ChatSessionIntentHandler` | `BaseChatRuntime` |
| `ChatViewModel` + extensions | `BaseChatUI` (thinned to ≤300 LOC) |
| `SessionManagerViewModel` | `BaseChatUI` (thin adapter) |
| `ModelLoadCoordinator` / `GenerationCoordinator` (UI-side) | `BaseChatRuntime` (renamed to avoid collision with Inference's `GenerationCoordinator`) |
| `ModelManagementViewModel` | `BaseChatUIModelManagement` (thin adapter) |
| `BaseChatBackends`, `BaseChatMCP`, `BaseChatTools`, `BaseChatAppIntents`, `BaseChatFuzz` | unchanged (still depend on Inference only) |
| `BaseChatTestSupport` | split: Inference-only fakes stay; SwiftData harnesses move to a new `BaseChatPersistenceSwiftDataTestSupport` |

## Non-goals

- No SwiftData schema redesign. `BaseChatSchemaV3` moves modules but
  entity names (the persistence keys) stay identical.
- No expansion of `InferenceService` public API as a shortcut.
- No new "misc runtime" bucket — every type added to `BaseChatRuntime`
  must be either a port, a use case, or a value type.
- No deprecation cycle, no compat shims, no `@available(deprecated)`
  re-exports. Pre-1.0 means clean cuts.

## Design principles

| # | Principle | Why |
|---|-----------|-----|
| 1 | **Runtime owns use cases, not view state.** | Transcript/session/model orchestration must be reusable by any host. Focus state, scroll, sheets, draft text are UI concerns. |
| 2 | **SwiftData stays behind adapters.** | `BaseChatRuntime` must not expose `ModelContext`, `@Model`, `@Query`, or migration internals. |
| 3 | **Records at the boundary.** | `ChatSessionRecord`, `ChatMessageRecord`, `APIEndpointRecord` already live in Inference. Every port traffics in records, not `@Model` types. |
| 4 | **Events out, commands in.** | Use cases expose `AsyncSequence<Event>` for state changes and `async throws` commands for actions. UI adapters subscribe and republish — no closure-bag wiring across boundaries. |
| 5 | **Secrets and network policy stay out of runtime.** | Keychain, `URLSession`, trust delegates, OAuth live in Inference (where they already are) or in adapters. |
| 6 | **Context injection is a first-class port.** | Fireside needs a structured way to supply story/memory/profile context. `GenerationContextProvider` already exists in Inference — runtime exposes a port that wraps it. |
| 7 | **Ports are async at the use-case surface, sync at the implementation.** | `ChatPersistenceProvider` becomes `async throws` (SwiftData `ModelContext` is `@MainActor`-bound; `async` lets the use case yield without blocking). Pre-1.0 lets us break the existing sync signature without compat shims. |

## Proposed runtime surface

### Ports

| Port | Replaces today's leak |
|------|-----------------------|
| `SessionStore` | `ChatPersistenceProvider` session methods |
| `MessageStore` | `ChatPersistenceProvider` message + search methods |
| `EndpointStore` | `APIConfigurationView` direct SwiftData access |
| `SamplerPresetStore` | `SamplerPresetPickerView`'s `@Query(SamplerPreset)` |
| `BenchmarkCache` | `ModelManagementViewModel.modelContext: ModelContext?` |
| `ModelCatalog` | `ModelManagementViewModel`'s direct disk inspection |
| `TitleGenerator` | `SessionManagerViewModel.generateTitle` calling `InferenceService` directly |
| `GenerationContextProvider` (re-exported) | already exists in Inference — runtime exposes it |
| `ToolSource` | generalises today's `MCPToolSource` pattern |

`ChatPersistenceProvider` is split into `SessionStore` + `MessageStore`.
The combined provider was a v0.x convenience; per-port boundaries make
selective implementation by hosts (Fireside) cheaper.

### Use cases

| Use case | Absorbs | Surface |
|----------|---------|---------|
| `ConversationRuntime` | `ChatViewModel`'s send/cancel/regenerate/edit/branch logic, `GenerationCoordinator` (UI-side), `ModelLoadCoordinator` | `AsyncSequence<ConversationEvent>` + commands |
| `SessionListService` | `SessionManagerViewModel`'s CRUD/search/pagination/title generation | `AsyncSequence<SessionListEvent>` + commands |
| `ModelManagementService` | `ModelManagementViewModel`'s discovery/download/delete/benchmark | `AsyncSequence<ModelCatalogEvent>` + commands |
| `PromptContextPipeline` | new — composes `GenerationContextProvider` contributions | `[ContextContribution]` |

### Constraints

- `BaseChatRuntime` is SwiftUI-free, Observation-free, SwiftData-free.
- Use cases are plain classes, not `@Observable`. Internal state is private.
  External state changes are emitted as events.
- Use cases are not `@MainActor`-pinned at the type level. Methods that
  call into `@MainActor` ports (SwiftData) hop on demand.
- Runtime instances are scene/window scoped, never singletons.
- All public API on use cases is `async throws` for commands and
  `AsyncSequence<Event>` for state.

## Trait propagation

`BaseChatRuntime` declares the same trait gates as `BaseChatUI` does today
(`Ollama`, `CloudSaaS`). `EndpointStore` and `ModelManagementService` use
`#if Ollama` / `#if CloudSaaS` where appropriate. `BaseChatPersistenceSwiftData`
is untraited (schema is the same regardless of which backends are enabled).

## Test-support partitioning

`BaseChatTestSupport` today depends on `BaseChatCore`. After the split:

- Inference-only fakes (`MockInferenceBackend`, `CharTokenizer`,
  `ChaosBackend`, etc.) — stay in `BaseChatTestSupport`, depend only on
  `BaseChatInference`.
- SwiftData-backed harnesses (`InMemoryPersistenceHarness`,
  `ErrorInjectingPersistenceProvider`, `MockBackgroundTaskScheduler`)
  → new `BaseChatPersistenceSwiftDataTestSupport` target.
- Runtime-port fakes (in-memory `SessionStore`, `MessageStore`, etc.)
  → also in `BaseChatPersistenceSwiftDataTestSupport`, or a separate
  `BaseChatRuntimeTestSupport` if it grows beyond ~5 fakes.

This split happens in the same PR cycle as the production split — test
infrastructure can't lag.

## Migration phases

Three phases, all pre-1.0, no deprecation tail.

### Phase 0 — spike + characterization (in flight)

Spike: rewrite one slice (`SessionListService`) end-to-end in the
proposed shape inside the existing target structure (no new targets).
Validates:

- Sync-port-via-async-use-case actually works.
- Event-stream pattern covers the surface cleanly.
- Adapter LOC delta is meaningfully smaller than today.
- Title generation can be migrated without special handling.

Characterization coverage written alongside the spike:

- session CRUD, ordering, pagination
- message paging and search/snippet semantics
- model/endpoint selection restoration
- first-message auto-rename
- transcript send/cancel/regenerate
- tool-call approval flow

Repo guardrails added in the same PR cycle:

- CI lint: no new `SwiftData` import in `BaseChatUI*`.
- CI lint: no new `@Query` / `.modelContext` usage in UI targets.
- CI lint: no new public API exposing `ModelContext` or `@Model` types.

**Exit criterion**: spike PR demonstrates the pattern works. If the spike
finds a blocker (event surface explodes, adapter not meaningfully thinner,
title generation unmigratable) → revisit the plan. **No code moves to a
new target until this gate passes.**

### Phase 1 — orchestration extracted, targets unchanged

Inside the existing target structure, extract every use case as a plain
async/event class. Each PR moves one use case + its ports + its tests.

Order — smallest blast radius first:

1. `SessionListService` (the spike, productionised)
2. `SamplerPresetStore` + adapter (kills the `@Query` leak)
3. `BenchmarkCache` + adapter (kills `modelContext` public surface)
4. `ModelManagementService` (absorbs `ModelManagementViewModel`)
5. `ConversationRuntime` (absorbs `ChatViewModel`'s orchestration; the
   biggest PR — closure-bag → events transformation)
6. `EndpointStore` + adapter (kills SwiftData imports in endpoint editor)

Each PR keeps the public API of the corresponding view model
source-compatible. UI adapters wrap the new use cases. Persistence stays
in `BaseChatCore` for now.

`ChatPersistenceProvider` becomes `async throws` in the same PR cycle.
Breaking change announced in the changelog as one entry, not per-method.

**Exit criterion**: no `@Observable` view model owns orchestration
state. Every state change in UI flows through an event stream.

### Phase 2 — physical target split

One PR — large, mostly mechanical. Creates `BaseChatRuntime` and
`BaseChatPersistenceSwiftData` targets, redistributes
`BaseChatCore`'s contents, deletes `BaseChatCore`. Updates host apps
(demo, ChatbotUI-iOS, Fireside) in the same PR.

Mechanical because Phase 1 has already done the architectural work —
this PR is just `git mv`, import rewrites, and CI lint updates.

CI lint additions:

- No `SwiftData` / `@Observable` / SwiftUI import in `BaseChatRuntime`.
- No `URLSession` / Keychain in `BaseChatRuntime`.
- `BaseChatUI` does not import `BaseChatPersistenceSwiftData`.

SwiftData entity-name migration: `@Model` types stay nested inside
`BaseChatSchemaV3` enum, so SwiftData entity names (`ChatMessage`,
`ChatSession`, etc.) are unaffected by the module move. A read-back test
opens a v0.13.x-era store fixture and asserts data integrity.

**Exit criterion**: package graph matches the target diagram.
`BaseChatCore` no longer exists in `Package.swift`.

## Acceptance criteria

Before tagging 1.0:

- All CI-safe suites pass.
- Demo app passes its smoke coverage.
- ChatbotUI-iOS builds against the new graph without local patching.
- Fireside replaces its custom bootstrap with `BaseChatRuntime` +
  custom `MessageStore`/`SessionStore` impls.
- Read-back test confirms a pre-refactor SwiftData store opens cleanly
  with no data loss.
- No `@Observable` view model owns orchestration state.
- No public runtime API exposes `ModelContext` or `@Model` types.

## Hard no-gos

- No `SwiftData` or `ModelContext` in `BaseChatRuntime`.
- No SwiftUI or `@Observable` in `BaseChatRuntime`.
- No `URLSession` or Keychain in `BaseChatRuntime` (live in Inference
  or backend adapters where they already are).
- No public runtime APIs exposing raw secret material.
- No closure-bag wiring across the runtime/UI boundary. Events out,
  commands in, full stop.
- No "while we're here" schema redesign.

## Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Closure-bag → event transformation explodes the event surface (~50 callbacks today) | Spike (Phase 0) measures this on the session-list slice before committing. Fail-fast gate. |
| `ChatPersistenceProvider` going async breaks Fireside's existing custom impl | Coordinated with Fireside in same PR. Pre-1.0 = breakage is the rule, not the exception. |
| SwiftData entity-name drift after module move | Entity names are simple class names, unaffected by module rename. Read-back test against pre-refactor fixture confirms. |
| `InferenceService` already overlaps with the proposed runtime | Runtime is a thin layer *over* `InferenceService` + ports. Use cases compose existing services; they don't absorb them. |
| Phase 1 PR sizes balloon (especially `ConversationRuntime`) | Per-use-case PRs with explicit LOC budget; if `ConversationRuntime` > 1500 LOC moved in one PR, split by sub-flow (send vs. regenerate vs. edit). |

## Why this is worth doing now

Pre-1.0 is the only window where this refactor is cheap. After 1.0:

- `ChatPersistenceProvider`'s sync signature is locked.
- `ModelManagementViewModel.modelContext` public surface is locked.
- `BaseChatCore` as a target is locked.
- Each future host integration calcifies the current shape.

The codebase has evolved over 500 PRs and the shape has been trending
toward this design through repeated decompositions (`InferenceService`
split, `ChatViewModel` extractions, `BaseChatUIModelManagement` peel,
storage-neutral records hoisted into Inference, `ChatPersistenceProvider`
port). This refactor is the formalisation and completion of work
already underway.

If it succeeds:

- **demo app** remains the reference implementation.
- **ChatbotUI-iOS** gets a cleaner customization surface without forking BCK.
- **Fireside** uses BCK runtime/inference as a subsystem without inheriting
  BCK's UI and persistence assumptions.

One runtime center, multiple host shapes, and no further pressure to
push app logic into UI modules just because those modules currently
own the composition story.
