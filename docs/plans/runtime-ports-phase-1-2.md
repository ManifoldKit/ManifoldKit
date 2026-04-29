# Plan — `BaseChatRuntime` / ports refactor (Phase 1.2 onward)

This is a **plan document**, not implementation. It records the intended
shape, migration order, and review constraints for the remainder of the
runtime ports refactor so reviewers can argue with the architecture
instead of reverse-engineering it from the diff. Pre-1.0 — breaking
changes free, no compatibility tail, one breaking changelog entry per
phase.

## Status

- Shipped on `main`:
  - #883 — `ChatPersistenceProvider` and the public command APIs on
    `ChatViewModel` / `SessionManagerViewModel` are now `async throws`
    (Phase 1.0).
  - #885 — `SessionManagerViewModel.configure(persistence:autoLoad:diagnostics:)`
    makes auto-load opt-in explicit; `configure(runtime:)` passes
    `autoLoad: true` automatically (Phase 1.0 follow-up).
  - #886 — `SessionListService` extracted from `SessionManagerViewModel`;
    session-list orchestration uses the events-out / commands-in pattern
    with a 6-case `SessionListEvent` enum (Phase 1.1).
- Open as a related artifact: this PR (the forward-looking plan), and
  Fireside's `docs/architecture/runtime-decoupling-migration.md` RFC
  pushing the same direction from the consumer side.
- Left to ship: Phase 1.2 port extraction, Phase 2 physical target
  split.
- Window: pre-1.0; one breaking changelog entry per phase, no shims.
- Downstream consumers in view:
  - BaseChatKit demo app
  - ChatbotUI-iOS
  - Fireside

## Picking this up in a new session

Live artifacts in priority order:

- **This document** — the plan. Read top to bottom.
- The shipped PRs above are the prior art for shape and naming. #886's
  worker report is the canonical source for the final `SessionListEvent`
  shape.
- No other in-flight branches for this refactor. **v0.14.0** is the
  baseline (current `main`).
- Repo: `roryford/BaseChatKit` (private). If picking up outside the
  working tree: `gh repo clone roryford/BaseChatKit && gh pr checkout <this-PR>`.

**Next concrete action: Phase 1.2 sub-step 1 — `MessageStore` +
`MessageStorePostWriteHook` + `SessionStore` split.** Co-design the
hook signature with Fireside *before* writing the PR. Fireside's
`GraphExtractionService` registration is the worked example that drives
the protocol shape; landing the protocol without that review risks a
v0.x churn cycle on a load-bearing surface.

**Precondition before opening sub-step 1**: confirm Fireside's adoption
of #883 + #885 + #886 has landed (the `configure(persistence:autoLoad:)`
flip at `AppEnvironmentFactory.swift:168`, custom
`ChatPersistenceProvider` impl signatures converted to `async throws`,
stored `onFirstMessage` closures flipped to `async`). If their `main`
is still on the pre-#883 surface, the BCK Phase 1.2 PR will block on
their adoption rather than the other way around. Verify before drafting.

After 1.2.1: `GenerationContextProvider` re-export + `PromptContextPipeline`
use case + `ContextContribution` value type (1.2.2 — locks the context
contract for the rest of pre-1.0). Then internal port cleanups
(`SamplerPresetStore`, `BenchmarkCache`, `EndpointStore`) at 1.2.3,
`InferenceService` interaction prep at 1.2.4, and `ConversationRuntime`
extraction at 1.2.5. Phase 2 is the physical target split:
`BaseChatRuntime` and `BaseChatPersistenceSwiftData` targets created,
`BaseChatCore` deleted.

## Background

BaseChatKit already has a strong inference boundary: `BaseChatInference`
is storage-free and backend-agnostic; `BaseChatBackends` and `BaseChatMCP`
depend on Inference directly; `ChatPersistenceProvider` decouples
session/message persistence from SwiftData via storage-neutral records
(`ChatSessionRecord`, `ChatMessageRecord`, `APIEndpointRecord` — all
hosted in Inference). The Phase 1.0 work (#883, #885) formalised the
async surface across the persistence and command boundary; Phase 1.1
(#886) extracted session-list orchestration into a service with an
event stream. What remains is the broader port extraction
(`MessageStore`, `GenerationContextProvider`, `ConversationRuntime`,
etc.) and the physical target split (`BaseChatRuntime` /
`BaseChatPersistenceSwiftData` / delete `BaseChatCore`).

The concrete leaks Phase 1.2 closes:

- `SamplerPresetPickerView` uses `@Query(sort: \SamplerPreset.createdAt)`
  directly against the SwiftData `@Model`.
- `ModelManagementViewModel.modelContext: ModelContext?` is a public
  property that hands the SwiftData store to host code.
- `APIConfigurationView` and `ModelManagementSheet` `import SwiftData`
  for endpoint editor flows.
- `ChatViewModel.swift:608–708` wires its coordinators via ~50 closure
  callbacks — orchestration and presentation share storage instead of
  communicating across a typed boundary.

## What we are building

A runtime-centered package split. **Pre-1.0**, so this is a hard cut,
not a deprecation cycle.

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

These renames happen in Phase 2 and are not partly done yet — both the
class rename and the new target arrive together.

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
| `SessionListService` | `BaseChatRuntime` (moves with this PR) |
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
| 7 | **Ports are async at the use-case surface, sync at the implementation.** | `ChatPersistenceProvider` is already `async throws` (#883); the rule still applies to every new port added in Phase 1.2. SwiftData `ModelContext` is `@MainActor`-bound; `async` at the boundary lets the use case yield without blocking. |

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
selective implementation by hosts (Fireside) cheaper. `SessionListService`
(already on main, post-#886) is the **use case** that consumes
`SessionStore` once that port lands; today it talks to
`ChatPersistenceProvider` directly.

#### `MessageStore` post-write hooks

`MessageStore` exposes a hook protocol so cross-cutting persistence
concerns (graph extraction, indexing, audit) can attach without
subclassing the store or wrapping it in a delegating impl. Hooks fire
after the write commits, in registration order. Phase 1.2 sub-step 1
ships this protocol alongside the `SessionStore` / `MessageStore` split.

```swift
public protocol MessageStorePostWriteHook: Sendable {
    func messageDidWrite(
        _ record: ChatMessageRecord,
        in sessionID: ChatSessionRecord.ID
    ) async
}

public protocol MessageStore: Sendable {
    // CRUD + search methods (async throws) elided …
    func addPostWriteHook(_ hook: any MessageStorePostWriteHook)
}
```

Hooks must not throw — a failing hook cannot roll back a committed
write. Hook errors are logged via `Log.persistence.error` and otherwise
swallowed; surfaces that need transactional guarantees compose at the
use-case layer (`ConversationRuntime`) instead. Fireside's
`GraphExtractionService` registers as a post-write hook at bootstrap
time; no `MessageStore` subclass needed.

A symmetric `SessionStorePostWriteHook` is provided for completeness;
no internal consumer uses it yet, so its shape is provisional until a
host actually exercises it.

### Use cases

| Use case | Status | Absorbs | Surface |
|----------|--------|---------|---------|
| `SessionListService` | ✅ shipped (#886, `Sources/BaseChatUI/ViewModels/SessionListService.swift`) | `SessionManagerViewModel`'s CRUD/search/pagination/title generation | `AsyncStream<SessionListEvent>` + commands |
| `ConversationRuntime` | forward-looking | `ChatViewModel`'s send/cancel/regenerate/edit/branch logic, `GenerationCoordinator` (UI-side), `ModelLoadCoordinator` | `AsyncSequence<ConversationEvent>` + commands |
| `ModelManagementService` | forward-looking | `ModelManagementViewModel`'s discovery/download/delete/benchmark | `AsyncSequence<ModelCatalogEvent>` + commands |
| `PromptContextPipeline` | forward-looking | new — composes `GenerationContextProvider` contributions | `[ContextContribution]` |

#### `ConversationEvent` cases

The closure-bag → events transformation only works if the event surface
is enumerated up front. The starter set below is the contract Phase 1.2
must ship; cases may be added during `ConversationRuntime` extraction
but cannot be removed or renamed without a coordinated breaking-change
cycle with downstream consumers (Fireside).

```swift
public enum ConversationEvent: Sendable {
    // Lifecycle
    case messageInserted(ChatMessageRecord)
    case streamStarted(messageID: ChatMessageRecord.ID)
    case tokenEmitted(messageID: ChatMessageRecord.ID, delta: String)
    case streamFinished(messageID: ChatMessageRecord.ID, reason: FinishReason)
    case errorRaised(ConversationError)

    // Context pipeline (Fireside hook points)
    case beforeContextAssembly(prompt: String, request: PromptContextRequest)
    case contextAssembled(contributions: [ContextContribution])
    case afterGeneration(messageID: ChatMessageRecord.ID, finalText: String)
    case compressionTriggered(removed: [ChatMessageRecord.ID], reason: CompressionReason)

    // Tool calls
    case toolCallRequested(ToolCall)
    case toolCallApproved(ToolCall.ID)
    case toolCallCompleted(ToolCall.ID, ToolResult)
}
```

`.beforeContextAssembly`, `.contextAssembled`, `.afterGeneration`, and
`.compressionTriggered` are the integration points Fireside's
story/memory pipeline composes against. They are load-bearing —
removing or renaming any of them is a coordinated change with Fireside,
not a unilateral rename. The other cases are BCK-internal and can
evolve more freely.

**Why 12 cases (not collapsed à la `SessionListEvent`).** #886 collapsed
`.sessionInserted` into `.sessionsLoaded` because every insert was
immediately followed by a list reload — the adapter ignored the first
event and only acted on the second. That collapse pattern does not
apply here: each `ConversationEvent` case represents a distinct
observable transition that adapters and Fireside both need to act on
(start vs. finish of a stream is a UI-state phase change; tool-call
request vs. approval vs. completion are three different user-facing
moments; the four context-pipeline cases bracket two distinct phases
of generation). Pre-emptive collapse would re-conflate concerns the
spike already separated. The starter set ships at 12; cases may be
added during `ConversationRuntime` extraction if a transition surfaces
that the starter set missed, but only by widening, never by collapsing.

For shape and naming conventions, `SessionListEvent` on main is the
worked precedent:

```swift
public enum SessionListEvent: Sendable {
    case sessionsLoaded([ChatSessionRecord], hasMore: Bool, offset: Int)
    case sessionRenamed(UUID, title: String)
    case sessionDeleted(UUID)
    case searchResultsChanged(SearchResults)
    case titleGenerated(UUID, title: String)
    case persistenceFailure(any Error)
}
```

`ConversationEvent` follows the same patterns: associated values rather
than separate identifier cases, IDs as `UUID` aliases (`ChatMessageRecord.ID`),
errors carried as the last associated value of the failure case, no
optional wrapping where a value is always present.

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

### Phase 1.2 — port extraction

Inside the existing target structure, extract every remaining use case
as a plain async/event class. Each PR moves one use case + its ports +
its tests. Ordering is driven by Fireside's gating ports rather than
"smallest blast radius first" — landing the load-bearing context and
hook surfaces early lets Fireside migrate in parallel.

1. **`MessageStore` + `MessageStorePostWriteHook` + `SessionStore` split.**
   Splits `ChatPersistenceProvider` into the two per-port protocols and
   ships the hook protocol alongside. Co-design the hook signature with
   Fireside before the PR opens — `GraphExtractionService` is the
   worked example. LOC budget: ~600–900, dominated by test fakes and
   the persistence adapter implementing both new protocols against the
   same SwiftData store.

2. **`GenerationContextProvider` re-export + `PromptContextPipeline`
   use case + `ContextContribution` value type.** Acceptance gate
   triggers here — the `ContextContribution` shape locks for the rest
   of pre-1.0. After this PR, any change to the context value type
   requires a coordinated PR pair with Fireside, not a unilateral edit.
   LOC budget: ~500.

3. **Internal port cleanups: `SamplerPresetStore`, `BenchmarkCache`,
   `EndpointStore`.** Kills the remaining `@Query` / public
   `ModelContext` leaks listed under Background. Lower priority than
   1–2 because no downstream is gated on these surfaces; they exist to
   close the CI-lint loop. May ship as one PR or three. LOC budget:
   ~400 each.

4. **`InferenceService` interaction prep.** Add nonisolated wrappers
   (or actor-isolated equivalents) for the operations runtime services
   call from off-main contexts: `enqueue`, `tokenizer` access,
   `capabilities` reads. Keeps `InferenceService` `@MainActor` for
   view-binding but lets runtime services compose it without a per-call
   hop. Prereq for sub-step 5. LOC budget: ~300.

5. **`ConversationRuntime` extraction.** Absorbs `ChatViewModel`'s
   orchestration — the biggest PR in the phase. Closure-bag → events
   transformation against the `ConversationEvent` surface above. LOC
   budget per the original plan: ~4500–5000 vs. 3621 today; if any
   single PR moves more than ~1500 LOC, split by sub-flow (send vs.
   regenerate vs. edit) rather than landing one mega-PR.

**Exit criterion**: no `@Observable` view model owns orchestration
state. Every state change in UI flows through an event stream.

### Phase 2 — physical target split

One PR — large, mostly mechanical. Creates `BaseChatRuntime` and
`BaseChatPersistenceSwiftData` targets, redistributes
`BaseChatCore`'s contents, deletes `BaseChatCore`. Updates host apps
(demo, ChatbotUI-iOS, Fireside) in the same PR.

`SessionListService` moves with this PR — it currently lives in
`BaseChatUI` (extracted there by #886 to keep the diff small) but is a
use case, so the Phase 2 split puts it in `BaseChatRuntime` alongside
the other use cases. The move is a `git mv` plus an import rewrite in
the `SessionManagerViewModel` adapter.

Mechanical because Phase 1.2 has already done the architectural work —
this PR is just `git mv`, import rewrites, and CI lint updates.

CI lint additions:

- No `SwiftData` / `@Observable` / SwiftUI import in `BaseChatRuntime`.
- No `URLSession` / Keychain in `BaseChatRuntime`.
- `BaseChatUI` does not import `BaseChatPersistenceSwiftData`.

SwiftData entity-name migration: `@Model` types stay nested inside
`BaseChatSchemaV3` enum, so SwiftData entity names (`ChatMessage`,
`ChatSession`, etc.) are unaffected by the module move. A read-back
test opens a v0.13.x-era store fixture and asserts data integrity.

**Exit criterion**: package graph matches the target diagram.
`BaseChatCore` no longer exists in `Package.swift`.

## Acceptance criteria

### Already met

- ✅ All CI-safe suites pass (continuous; #883 + #885 + #886 maintained
  this throughout).
- ✅ Phase 1.0 async migration: `ChatPersistenceProvider` and the
  public command APIs on `ChatViewModel` / `SessionManagerViewModel`
  are `async throws` (#883).
- ✅ `SessionManagerViewModel.configure` makes the auto-load opt-in
  explicit; `autoLoad` is required (no default) so the behaviour change
  cannot be missed silently (#885).
- ✅ Session-list orchestration extracted as a service with an
  event-stream surface and async-throws commands (#886).

### Outstanding

Before tagging 1.0:

- Demo app passes its smoke coverage.
- ChatbotUI-iOS builds against the new graph without local patching.
- Fireside replaces its custom bootstrap with `BaseChatRuntime` +
  custom `MessageStore` / `SessionStore` impls.
- `GenerationContextProvider` port shape and `ContextContribution`
  value type are locked at the end of Phase 1.2 and treated as a
  stable contract for the remainder of the pre-1.0 window. Fireside's
  `GraphSlotFormatter` outputs become formal `ContextContribution`
  values without retrofitting. Any change to the `ContextContribution`
  type after Phase 1.2 ships requires a coordinated PR pair across BCK
  and Fireside, not a unilateral edit.
- `MessageStorePostWriteHook` and the load-bearing `ConversationEvent`
  cases (`.beforeContextAssembly`, `.contextAssembled`,
  `.afterGeneration`, `.compressionTriggered`) ship in Phase 1.2 and
  are similarly locked.
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
| Closure-bag → event transformation explodes the event surface (~50 callbacks today) | #886 validated the transformation on the session-list slice with a 6-case enum. The same discipline carries into `ConversationRuntime`; if the case count grows beyond ~15 during extraction, sub-divide the use case rather than letting the enum sprawl. |
| SwiftData entity-name drift after module move | Entity names are simple class names, unaffected by module rename. Read-back test against pre-refactor fixture confirms. |
| `InferenceService` already overlaps with the proposed runtime | Runtime is a thin layer *over* `InferenceService` + ports. Use cases compose existing services; they don't absorb them. |
| Phase 1.2 PR sizes balloon (especially `ConversationRuntime`) | Per-use-case PRs with explicit LOC budget; if `ConversationRuntime` > 1500 LOC moved in one PR, split by sub-flow (send vs. regenerate vs. edit). |
| BCK and Fireside invent parallel abstractions for the same problem | Fireside-migration checklist appendix below pins what changes in each repo per phase. Port-shape PRs require Fireside review before merge. |

## Appendix — Fireside migration checklist

Explicit coordination contract with Fireside (which has its own
`docs/architecture/runtime-decoupling-migration.md` RFC pushing the
same direction). This appendix is canonical: if BCK ships a phase that
requires a Fireside change not listed here, the plan is wrong, not
Fireside. Conversely, if Fireside lands a change that depends on a
port shape not pinned here, that PR blocks until the appendix catches
up.

#### Phase 1.0 — async migration ✅ shipped (BCK #883, #885)

Fireside's matching adoption: confirm `AppEnvironmentFactory.swift:168`
flipped to `configure(persistence:autoLoad:)`, custom
`ChatPersistenceProvider` impl signatures converted to `async throws`,
stored `onFirstMessage` closures flipped to `async`. If any of these
are still pending, raise it on the next port-shape PR rather than this
doc.

### Phase 1.2 — port extraction

BCK changes:
- `ChatPersistenceProvider` splits into `SessionStore` + `MessageStore`.
- `MessageStorePostWriteHook` protocol introduced.
- `GenerationContextProvider` re-exported from `BaseChatRuntime`;
  `PromptContextPipeline` use case introduced; `ContextContribution`
  value type pinned.
- `ConversationRuntime` ships with the `ConversationEvent` surface
  enumerated above.

Fireside changes (same window):
- Replace Fireside's combined provider impl with separate `SessionStore`
  + `MessageStore` impls.
- Migrate `GraphExtractionService` from its current attachment mechanism
  to `MessageStorePostWriteHook` registration at bootstrap.
- Migrate `GraphSlotFormatter` outputs to formal `ContextContribution`
  values; register as a `GenerationContextProvider` contributor through
  `PromptContextPipeline`.
- Migrate `StoryStore.send(_:)` from closure-callback orchestration to
  `AsyncSequence<ConversationEvent>` consumption. The four load-bearing
  cases are `.beforeContextAssembly`, `.contextAssembled`,
  `.afterGeneration`, `.compressionTriggered`.

### Phase 2 — physical target split

BCK changes:
- `BaseChatCore` deleted.
- `BaseChatRuntime` and `BaseChatPersistenceSwiftData` targets created.
- `BaseChatBootstrap` (renamed) provides the host bootstrap.

Fireside changes (same window):
- Import rewrites:
  - `import BaseChatCore` → `import BaseChatRuntime` for orchestration
    types and ports.
  - `import BaseChatCore` → `import BaseChatPersistenceSwiftData` only
    if Fireside still uses the SwiftData persistence impl. If Fireside
    has fully replaced persistence with custom stores, the dependency
    on `BaseChatPersistenceSwiftData` can be dropped entirely.
- Replace Fireside's custom bootstrap with `BaseChatBootstrap` configured
  with custom `MessageStore` / `SessionStore` instances.
- Drop any inherited `@Model` type imports — they are no longer
  reachable through the public surface.

### Coordination protocol

- Each BCK PR in Phases 1.2 names the Fireside PR that consumes it
  (and vice versa). Both PRs land in the same review window; merging
  the BCK PR before the matching Fireside PR is ready breaks Fireside's
  `main`.
- Port-shape changes (signatures, event cases, hook protocols,
  `ContextContribution` shape) require a Fireside reviewer on the BCK
  PR before merge.
- The four load-bearing `ConversationEvent` cases and
  `MessageStorePostWriteHook` are pinned to this appendix. Any
  deviation is updated here in the same PR that introduces the
  deviation — the plan is the source of truth, not Slack threads.
- **Exception — internal-only port cleanups (Phase 1.2 sub-step 3).**
  `SamplerPresetStore`, `BenchmarkCache`, and `EndpointStore` close
  `@Query` / public `ModelContext` leaks that Fireside does not
  consume; these PRs do not need a Fireside reviewer or a matching
  Fireside PR. They still go through normal BCK review, but the
  cross-repo coordination protocol does not gate them.

## Why this is worth doing now

Pre-1.0 is the only window where this refactor is cheap. After 1.0:

- `ChatPersistenceProvider`'s split into per-port protocols is locked.
- `ModelManagementViewModel.modelContext` public surface is locked.
- `BaseChatCore` as a target is locked.
- Each future host integration calcifies the current shape.

The codebase has evolved over 500 PRs and the shape has been trending
toward this design through repeated decompositions (`InferenceService`
split, `ChatViewModel` extractions, `BaseChatUIModelManagement` peel,
storage-neutral records hoisted into Inference, `ChatPersistenceProvider`
port, the Phase 1.0/1.1 work above). This refactor is the formalisation
and completion of work already underway.

If it succeeds:

- **demo app** remains the reference implementation.
- **ChatbotUI-iOS** gets a cleaner customization surface without
  forking BCK.
- **Fireside** uses BCK runtime/inference as a subsystem without
  inheriting BCK's UI and persistence assumptions.

One runtime center, multiple host shapes, and no further pressure to
push app logic into UI modules just because those modules currently
own the composition story.
