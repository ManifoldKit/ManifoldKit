# Plan — `ManifoldRuntime` / ports refactor (Phase 1.2 onward)

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
  - #889 — this plan doc landed as the forward-looking spec.
- In review:
  - #890 — `SamplerPresetStore` + `BenchmarkCache` + `EndpointStore`
    internal port extraction (Phase 1.2 sub-step 3). Closes `@Query` /
    public `ModelContext` leaks in the editor flows.
  - #893 — `InferenceService` nonisolated wrappers (Phase 1.2 sub-step 4).
    Prereq for sub-step 5 — adds `capabilitiesAsync` / `tokenizerAsync` /
    `enqueueAsync` / `cancelAsync` for off-main composition.
- Related artifact: Fireside's
  `docs/architecture/runtime-decoupling-migration.md` RFC pushing the
  same direction from the consumer side. Fireside's reply to this plan
  (2026-04-29) drives the reframe in this revision — see "Stance" below
  and the Fireside appendix.
- Left to ship: Phase 1.2 sub-steps 1, 2, 5; Phase 2 physical target
  split.
- Window: pre-1.0; one breaking changelog entry per phase, no shims.
- Downstream consumers in view:
  - ManifoldKit demo app
  - ChatbotUI-iOS
  - Fireside

## Stance

ManifoldKit is a **library with a reference runtime, not a runtime with ports.**
This stance is load-bearing for everything below; if it changes the
whole plan changes.

- ManifoldKit ships ports (`MessageStore`, `SessionStore`, `PromptContextProvider`,
  etc.) and a reference use case (`ConversationRuntime`) that composes
  them into a turn loop.
- `ConversationRuntime` is **optional**. Demo and ChatbotUI-iOS adopt
  it; Fireside continues to drive its own turn loop (`StoryStore` →
  eventual `TurnEngine`) directly against `InferenceService` and the
  ports.
- The `ConversationEvent` enum is the contract for `ConversationRuntime`
  *users*, not a universal event surface. Direct `InferenceService`
  consumers (Fireside) get a different, narrower contract.
- `ContextContribution` as an aggregate value type lives in the
  consumer (Fireside has `[PromptSlot] + realCost`). ManifoldKit ships
  `PromptSlot` (already does), the new `PromptContextProvider` port,
  and `PromptContextPipeline` as a passive merge over `[PromptSlot]`.
  No competing aggregate type in ManifoldKit.

Implications captured throughout the doc; the most consequential are
that the "Fireside-gated" framing of sub-steps 1/2 changes shape (no
adoption flip blocks ManifoldKit; design constraints from FS shape what ManifoldKit
ships) and that `MessageStorePostWriteHook` is a low-level primitive,
not the canonical attachment point for Fireside's `GraphExtractionService`.

## Picking this up in a new session

Live artifacts in priority order:

- **This document** — the plan. Read top to bottom.
- The shipped PRs above are the prior art for shape and naming. #886's
  worker report is the canonical source for the final `SessionListEvent`
  shape.
- In-flight branches for this refactor: #890 (sub-step 3) and #893
  (sub-step 4). **v0.14.0** is the baseline (current `main`).
- Repo: `roryford/ManifoldKit` (private). If picking up outside the
  working tree: `gh repo clone roryford/ManifoldKit && gh pr checkout <this-PR>`.

**Next concrete action: Phase 1.2 sub-step 1 — `MessageStore` +
`MessageStorePostWriteHook` + `SessionStore` split.** The hook signature
is settled — see `MessageStore post-write hooks` below. Fireside's
`GraphExtractionService` does *not* attach via this hook (it lives at
the turn-orchestrator layer, see Fireside appendix); the hook ships as
a low-level primitive available to consumers who want it.

After 1.2.1: `PromptContextProvider` port + `PromptContextPipeline`
passive-merge use case (1.2.2 — no new value type ships). Then
`ConversationRuntime` extraction as the optional reference use case at
1.2.5. Phase 1.2 sub-steps 3 (internal port cleanups) and 4
(`InferenceService` nonisolated wrappers) are already in review (#890,
#893). Phase 2 is the physical target split: `ManifoldRuntime` and
`ManifoldPersistenceSwiftData` targets created, `ManifoldCore` deleted.

**No Fireside-adoption precondition.** The earlier draft of this plan
gated 1.2.1 on Fireside flipping to the post-#883 surface. Fireside's
2026-04-29 reply confirmed they consume ManifoldKit via a local SPM path
reference and have zero custom `ChatPersistenceProvider` impls, zero
`onFirstMessage` consumers, and no `SessionManagerViewModel` call sites
at all. The flip was a no-op; the precondition is dropped.

## Background

ManifoldKit already has a strong inference boundary: `ManifoldInference`
is storage-free and backend-agnostic; `ManifoldBackends` and `ManifoldMCP`
depend on Inference directly; `ChatPersistenceProvider` decouples
session/message persistence from SwiftData via storage-neutral records
(`ChatSessionRecord`, `ChatMessageRecord`, `APIEndpointRecord` — all
hosted in Inference). The Phase 1.0 work (#883, #885) formalised the
async surface across the persistence and command boundary; Phase 1.1
(#886) extracted session-list orchestration into a service with an
event stream. What remains is the broader port extraction
(`MessageStore`, `PromptContextProvider`, `ConversationRuntime`,
etc.) and the physical target split (`ManifoldRuntime` /
`ManifoldPersistenceSwiftData` / delete `ManifoldCore`).

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
                    ManifoldInference
                          ▲
            ┌─────────────┼──────────────────┐
            │             │                  │
   ManifoldBackends  ManifoldMCP      ManifoldRuntime
                                            ▲
                          ┌─────────────────┼──────────────────┐
                          │                 │                  │
                ManifoldPersistence-   ManifoldUI    ManifoldUIModelManagement
                   SwiftData               ▲                   │
                                           └───────────────────┘
                                                (one-way edge,
                                                 already CI-enforced)
```

The center of gravity moves from
`ChatViewModel + SessionManagerViewModel + ModelContext-aware UI`
to `ManifoldRuntime` use cases + ports, with UI as a presentation layer
rather than the application layer.

### Target naming

- The existing `public final class ManifoldRuntime` in
  `Sources/ManifoldCore/ManifoldRuntime.swift` is renamed to
  `ManifoldBootstrap` (a file by that name already exists in the same
  directory — it absorbs the rename).
- The new target is `ManifoldRuntime`.
- `ManifoldCore` is **deleted**, not deprecated. Its current contents
  redistribute: persistence implementation → `ManifoldPersistenceSwiftData`,
  storage-neutral helpers → `ManifoldRuntime`, intent protocols →
  `ManifoldRuntime`. Host apps update their imports in one PR.

These renames happen in Phase 2 and are not partly done yet — both the
class rename and the new target arrive together.

### Where today's pieces land

| Today | Lands in |
|-------|----------|
| `ManifoldCore` SwiftData `@Model` types + schema | `ManifoldPersistenceSwiftData` |
| `SwiftDataPersistenceProvider` | `ManifoldPersistenceSwiftData` |
| `ChatPersistenceProvider` protocol | `ManifoldRuntime` |
| `ManifoldRuntime` (bootstrap class) | `ManifoldRuntime` (renamed `ManifoldBootstrap`) |
| `ChatExportService` / `ConversationExporter` | `ManifoldRuntime` |
| `ChatIntentAction` / `ChatSessionIntentHandler` | `ManifoldRuntime` |
| `ChatViewModel` + extensions | `ManifoldUI` (thinned to ≤300 LOC) |
| `SessionManagerViewModel` | `ManifoldUI` (thin adapter) |
| `SessionListService` | `ManifoldRuntime` (moves with this PR) |
| `ModelLoadCoordinator` / `GenerationCoordinator` (UI-side) | `ManifoldRuntime` (renamed to avoid collision with Inference's `GenerationCoordinator`) |
| `ModelManagementViewModel` | `ManifoldUIModelManagement` (thin adapter) |
| `ManifoldBackends`, `ManifoldMCP`, `ManifoldTools`, `ManifoldAppIntents`, `ManifoldFuzz` | unchanged (still depend on Inference only) |
| `ManifoldTestSupport` | split: Inference-only fakes stay; SwiftData harnesses move to a new `ManifoldPersistenceSwiftDataTestSupport` |

## Non-goals

- No SwiftData schema redesign. `ManifoldSchemaV3` moves modules but
  entity names (the persistence keys) stay identical.
- No expansion of `InferenceService` public API as a shortcut.
- No new "misc runtime" bucket — every type added to `ManifoldRuntime`
  must be either a port, a use case, or a value type.
- No deprecation cycle, no compat shims, no `@available(deprecated)`
  re-exports. Pre-1.0 means clean cuts.

## Design principles

| # | Principle | Why |
|---|-----------|-----|
| 1 | **Runtime owns use cases, not view state.** | Transcript/session/model orchestration must be reusable by any host. Focus state, scroll, sheets, draft text are UI concerns. |
| 2 | **SwiftData stays behind adapters.** | `ManifoldRuntime` must not expose `ModelContext`, `@Model`, `@Query`, or migration internals. |
| 3 | **Records at the boundary.** | `ChatSessionRecord`, `ChatMessageRecord`, `APIEndpointRecord` already live in Inference. Every port traffics in records, not `@Model` types. |
| 4 | **Events out, commands in.** | Use cases expose `AsyncSequence<Event>` for state changes and `async throws` commands for actions. UI adapters subscribe and republish — no closure-bag wiring across boundaries. |
| 5 | **Secrets and network policy stay out of runtime.** | Keychain, `URLSession`, trust delegates, OAuth live in Inference (where they already are) or in adapters. |
| 6 | **Context injection is a first-class port.** | Fireside needs a structured way to supply story/memory/profile context. `PromptContextProvider` is the new slot-contributor port introduced in Phase 1.2 sub-step 2; consumers conform and the runtime composes them via `PromptContextPipeline`. |
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
| `PromptContextProvider` | new — the slot-contributor port for context assembly. (Distinct from the internal `GenerationContextProvider` in `ManifoldInference`, which is a `@MainActor`-bound model-state provider used by `GenerationCoordinator` — that protocol stays internal and unchanged.) |
| `ToolSource` | generalises today's `MCPToolSource` pattern |

`ChatPersistenceProvider` is split into `SessionStore` + `MessageStore`.
The combined provider was a v0.x convenience; per-port boundaries make
selective implementation by hosts (Fireside) cheaper. `SessionListService`
(already on main, post-#886) is the **use case** that consumes
`SessionStore` once that port lands; today it talks to
`ChatPersistenceProvider` directly.

#### `MessageStore` post-write hooks

`MessageStore` exposes a hook protocol as a **low-level primitive** —
not as the canonical attachment point for any specific consumer's
cross-cutting concerns. Hooks fire after the write commits, in
registration order. Phase 1.2 sub-step 1 ships this protocol alongside
the `SessionStore` / `MessageStore` split.

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
use-case layer (`ConversationRuntime`, or the consumer's own
orchestrator) instead.

**Where Fireside's `GraphExtractionService` lives:** *not* on this
hook. Fireside attaches extraction at the turn-orchestrator layer
(`StoryStore` post-turn, eventually a `StoryTurnObserver` protocol on
the Fireside side per their RFC). The natural extraction unit is a
turn, not a message; the per-message hook fires twice per turn and
doesn't surface the turn boundary. Shipping the hook as a low-level
primitive keeps it available for consumers whose unit of work *is* the
message (audit, indexing, debug logging) without overpromising it as
the right seam for higher-level concerns.

A symmetric `SessionStorePostWriteHook` is provided for completeness;
no internal consumer uses it yet, so its shape is provisional until a
host actually exercises it. Fireside's reply confirmed they have no
planned consumer either.

### Use cases

Use cases compose ports into a turn loop or other workflow. They are
**optional** — consumers that prefer to drive the ports directly
(Fireside) skip them.

| Use case | Status | Absorbs | Surface |
|----------|--------|---------|---------|
| `SessionListService` | ✅ shipped (#886, `Sources/ManifoldUI/ViewModels/SessionListService.swift`) | `SessionManagerViewModel`'s CRUD/search/pagination/title generation | `AsyncStream<SessionListEvent>` + commands |
| `ConversationRuntime` | forward-looking, **optional reference** | `ChatViewModel`'s send/cancel/regenerate/edit/branch logic, `GenerationCoordinator` (UI-side), `ModelLoadCoordinator` | `AsyncSequence<ConversationEvent>` + commands |
| `ModelManagementService` | forward-looking | `ModelManagementViewModel`'s discovery/download/delete/benchmark | `AsyncSequence<ModelCatalogEvent>` + commands |
| `PromptContextPipeline` | ✅ shipped (#TBD, sub-step 2; `Sources/ManifoldCore/Services/PromptContextPipeline.swift`) | new — passive merge over `[PromptSlot]` from registered `PromptContextProvider`s | `[PromptSlot]` |

#### `ConversationEvent` cases

`ConversationEvent` is the contract for `ConversationRuntime` *users*
(demo, ChatbotUI-iOS) — not a universal event surface. Direct
`InferenceService` consumers (Fireside) drive the ports themselves and
get a different, narrower contract documented under "Direct-inference
contract" below.

The starter set Phase 1.2 ships:

```swift
public enum ConversationEvent: Sendable {
    // Lifecycle
    case messageInserted(ChatMessageRecord)
    case streamStarted(messageID: ChatMessageRecord.ID)
    case tokenEmitted(messageID: ChatMessageRecord.ID, delta: String)
    case streamFinished(messageID: ChatMessageRecord.ID, reason: FinishReason)
    case errorRaised(ConversationError)

    // Context pipeline (runtime hook points)
    case beforeContextAssembly(prompt: String, request: PromptContextRequest)
    case contextAssembled(slots: [PromptSlot])
    case afterGeneration(messageID: ChatMessageRecord.ID, finalText: String)
    case compressionTriggered(removed: [ChatMessageRecord.ID], reason: CompressionReason)

    // Tool calls
    case toolCallRequested(ToolCall)
    case toolCallApproved(ToolCall.ID)
    case toolCallCompleted(ToolCall.ID, ToolResult)
}
```

**Load-bearing for `ConversationRuntime`-using consumers**:
`.beforeContextAssembly`, `.contextAssembled`, `.afterGeneration`,
`.compressionTriggered`. Removing or renaming any of these is a
coordinated breaking change. These bracket the two phases of generation
that runtime-using consumers need to extend — context assembly and
post-generation work — even when they don't drive their own turn loop.

**Direct-inference contract** (Fireside): consumers who compose
`InferenceService` + ports themselves, without using
`ConversationRuntime`, get a narrower contract pinned to the events
the underlying `GenerationStream` already provides:
`.tokenEmitted` (the raw token stream, pre-thinking-block-filter),
`.streamFinished`, and `.errorRaised`. These three are load-bearing
for direct-inference consumers — they're how Fireside drives narrative
streaming UI today. `.compressionTriggered` is also pinned for direct
consumers when (and only when) the consumer asks ManifoldKit to manage
compression; today Fireside drives its own compression and the case
is informational.

The two contracts overlap on `.compressionTriggered` and share the
same `.tokenEmitted / .streamFinished / .errorRaised` shape — the
difference is just which subset is pinned for which consumer posture.

**Why 12 cases (not collapsed à la `SessionListEvent`).** #886 collapsed
`.sessionInserted` into `.sessionsLoaded` because every insert was
immediately followed by a list reload — the adapter ignored the first
event and only acted on the second. That collapse pattern does not
apply here: each `ConversationEvent` case represents a distinct
observable transition that runtime-using adapters need to act on
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

- `ManifoldRuntime` is SwiftUI-free, Observation-free, SwiftData-free.
- Use cases are plain classes, not `@Observable`. Internal state is private.
  External state changes are emitted as events.
- Use cases are not `@MainActor`-pinned at the type level. Methods that
  call into `@MainActor` ports (SwiftData) hop on demand.
- Runtime instances are scene/window scoped, never singletons.
- All public API on use cases is `async throws` for commands and
  `AsyncSequence<Event>` for state.

## Trait propagation

`ManifoldRuntime` declares the same trait gates as `ManifoldUI` does today
(`Ollama`, `CloudSaaS`). `EndpointStore` and `ModelManagementService` use
`#if Ollama` / `#if CloudSaaS` where appropriate. `ManifoldPersistenceSwiftData`
is untraited (schema is the same regardless of which backends are enabled).

## Test-support partitioning

`ManifoldTestSupport` today depends on `ManifoldCore`. After the split:

- Inference-only fakes (`MockInferenceBackend`, `CharTokenizer`,
  `ChaosBackend`, etc.) — stay in `ManifoldTestSupport`, depend only on
  `ManifoldInference`.
- SwiftData-backed harnesses (`InMemoryPersistenceHarness`,
  `ErrorInjectingPersistenceProvider`, `MockBackgroundTaskScheduler`)
  → new `ManifoldPersistenceSwiftDataTestSupport` target.
- Runtime-port fakes (in-memory `SessionStore`, `MessageStore`, etc.)
  → also in `ManifoldPersistenceSwiftDataTestSupport`, or a separate
  `ManifoldRuntimeTestSupport` if it grows beyond ~5 fakes.

This split happens in the same PR cycle as the production split — test
infrastructure can't lag.

## Migration phases

### Phase 1.2 — port extraction

Inside the existing target structure, extract every remaining use case
as a plain async/event class. Each PR moves one use case + its ports +
its tests. Ordering: persistence ports first (sub-step 1) so downstream
work has the new shape to depend on, then context (sub-step 2) and
runtime (sub-step 5). Sub-steps 3 and 4 are independent and already in
review.

1. **`MessageStore` + `MessageStorePostWriteHook` + `SessionStore` split.**
   Splits `ChatPersistenceProvider` into the two per-port protocols and
   ships the hook protocol alongside as a low-level primitive (see the
   `MessageStore post-write hooks` section for the framing — Fireside's
   `GraphExtractionService` does *not* attach via this hook). LOC
   budget: ~600–900, dominated by test fakes and the persistence
   adapter implementing both new protocols against the same SwiftData
   store. Hook signature settled per Fireside's reply — no further
   co-design needed before opening the PR.

2. **`PromptContextProvider` port + `PromptContextPipeline` passive-merge
   use case.** Introduces `PromptContextProvider` as a new public
   protocol in `ManifoldInference` (`Sendable`, no `@MainActor` pin,
   bare `messageCount: Int` argument; throws propagate). Pairs it with
   `PromptContextPipeline` in `ManifoldCore` — a passive merge use case
   that asks each registered provider for slots, concatenates, sorts by
   `PromptSlotPosition.sortIndex(messageCount:)`, and returns the
   assembled `[PromptSlot]`. **No new value type** — `[PromptSlot]` is
   the boundary primitive (already in ManifoldKit). The new protocol is
   deliberately named to avoid colliding with the existing internal
   `GenerationContextProvider` (`@MainActor`-bound, `AnyObject`-constrained
   model-state provider used by `GenerationCoordinator`); they have
   different shapes, different consumers, and live alongside each
   other. Consumers that want a richer aggregate (Fireside's
   `ContextContribution` with budget accounting and `realCost`) keep
   that aggregate in their own module. LOC budget: ~250.

3. ✅ **Internal port cleanups: `SamplerPresetStore`, `BenchmarkCache`,
   `EndpointStore`** — in review as #890. Kills the remaining `@Query`
   / public `ModelContext` leaks listed under Background.

4. ✅ **`InferenceService` interaction prep** — in review as #893.
   Adds `capabilitiesAsync` / `tokenizerAsync` / `enqueueAsync` /
   `cancelAsync` nonisolated wrappers. Prereq for sub-step 5.

5. **`ConversationRuntime` extraction.** Absorbs `ChatViewModel`'s
   orchestration into the **optional reference** runtime use case.
   Closure-bag → events transformation against the `ConversationEvent`
   surface above. Demo and ChatbotUI-iOS adopt; Fireside continues to
   drive the ports directly. LOC budget per the original plan:
   ~4500–5000 vs. 3621 today; if any single PR moves more than ~1500
   LOC, split by sub-flow (send vs. regenerate vs. edit) rather than
   landing one mega-PR.

**Exit criterion**: no `@Observable` view model owns orchestration
state. Every state change in UI flows through an event stream.

### Phase 2 — physical target split

One PR — large, mostly mechanical. Creates `ManifoldRuntime` and
`ManifoldPersistenceSwiftData` targets, redistributes
`ManifoldCore`'s contents, deletes `ManifoldCore`. Updates host apps
(demo, ChatbotUI-iOS, Fireside) in the same PR.

`SessionListService` moves with this PR — it currently lives in
`ManifoldUI` (extracted there by #886 to keep the diff small) but is a
use case, so the Phase 2 split puts it in `ManifoldRuntime` alongside
the other use cases. The move is a `git mv` plus an import rewrite in
the `SessionManagerViewModel` adapter.

Mechanical because Phase 1.2 has already done the architectural work —
this PR is just `git mv`, import rewrites, and CI lint updates.

CI lint additions:

- No `SwiftData` / `@Observable` / SwiftUI import in `ManifoldRuntime`.
- No `URLSession` / Keychain in `ManifoldRuntime`.
- `ManifoldUI` does not import `ManifoldPersistenceSwiftData`.

SwiftData entity-name migration: `@Model` types stay nested inside
`ManifoldSchemaV3` enum, so SwiftData entity names (`ChatMessage`,
`ChatSession`, etc.) are unaffected by the module move. A read-back
test opens a v0.13.x-era store fixture and asserts data integrity.

**Exit criterion**: package graph matches the target diagram.
`ManifoldCore` no longer exists in `Package.swift`.

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
- Fireside replaces its custom bootstrap with `ManifoldRuntime` +
  custom `MessageStore` / `SessionStore` impls.
- `PromptContextProvider` port shape is locked at the end of Phase
  1.2 and treated as a stable contract for the remainder of the pre-1.0
  window. The boundary primitive is `[PromptSlot]` (already in ManifoldKit).
  Fireside's `GraphSlotFormatter` outputs continue to be wrapped in
  Fireside's own `ContextContribution` aggregate; ManifoldKit does not ship a
  competing aggregate type. Any change to `PromptSlot` itself after
  Phase 1.2 ships requires a coordinated PR pair across ManifoldKit and
  Fireside.
- `MessageStorePostWriteHook` ships in Phase 1.2 as a low-level
  primitive. The load-bearing `ConversationEvent` cases for
  runtime-using consumers (`.beforeContextAssembly`,
  `.contextAssembled`, `.afterGeneration`, `.compressionTriggered`)
  and the direct-inference contract (`.tokenEmitted`, `.streamFinished`,
  `.errorRaised`, plus `.compressionTriggered` when applicable) are
  pinned at the end of Phase 1.2.
- Read-back test confirms a pre-refactor SwiftData store opens cleanly
  with no data loss.
- No `@Observable` view model owns orchestration state.
- No public runtime API exposes `ModelContext` or `@Model` types.

## Hard no-gos

- No `SwiftData` or `ModelContext` in `ManifoldRuntime`.
- No SwiftUI or `@Observable` in `ManifoldRuntime`.
- No `URLSession` or Keychain in `ManifoldRuntime` (live in Inference
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
| ManifoldKit and Fireside invent parallel abstractions for the same problem | Fireside-migration checklist appendix below pins what changes in each repo per phase. Port-shape PRs require Fireside review before merge. |

## Appendix — Fireside migration checklist

Explicit coordination contract with Fireside (which has its own
`docs/architecture/runtime-decoupling-migration.md` RFC pushing the
same direction). This appendix is canonical: if ManifoldKit ships a phase that
requires a Fireside change not listed here, the plan is wrong, not
Fireside. Conversely, if Fireside lands a change that depends on a
port shape not pinned here, that PR blocks until the appendix catches
up.

#### Phase 1.0 — async migration ✅ shipped (ManifoldKit #883, #885)

Fireside's matching adoption: confirm `AppEnvironmentFactory.swift:168`
flipped to `configure(persistence:autoLoad:)`, custom
`ChatPersistenceProvider` impl signatures converted to `async throws`,
stored `onFirstMessage` closures flipped to `async`. If any of these
are still pending, raise it on the next port-shape PR rather than this
doc.

### Phase 1.2 — port extraction

ManifoldKit changes:
- `ChatPersistenceProvider` splits into `SessionStore` + `MessageStore`.
- `MessageStorePostWriteHook` protocol introduced as a low-level
  primitive.
- `PromptContextProvider` introduced as a new public port in
  `ManifoldInference`; `PromptContextPipeline` passive-merge use case
  introduced over `[PromptSlot]` in `ManifoldCore` (will move to
  `ManifoldRuntime` in Phase 2). **No competing `ContextContribution`
  aggregate ships from ManifoldKit** — Fireside's existing aggregate in
  `FiresideMemory` remains the source of truth on the consumer side.
- `ConversationRuntime` ships as the **optional reference** use case,
  with the `ConversationEvent` surface enumerated above.

Fireside changes (same window):

The library-stance reframe means Fireside's adoption is much narrower
than the earlier draft of this plan implied.

- ✅ No-op: replace combined provider impl with separate `SessionStore`
  + `MessageStore` impls. Fireside has no custom provider impl today;
  this is automatic.
- **Not migrating**: `GraphExtractionService` stays at the
  turn-orchestrator layer (`StoryStore` post-turn / eventual
  `StoryTurnObserver` per Fireside's RFC). It does *not* migrate to
  `MessageStorePostWriteHook` registration. The hook is available if
  Fireside wants it later for some other concern (audit, indexing);
  graph extraction has the wrong unit of work for it.
- **Not migrating**: `GraphSlotFormatter` outputs stay in Fireside's
  `ContextContribution` aggregate. Fireside conforms to ManifoldKit's
  `PromptContextProvider` port returning `[PromptSlot]`; the
  surrounding budget accounting and `realCost` tracking remain in
  `FiresideMemory`. No retrofit required.
- **Not migrating**: `StoryStore.send(_:)` continues to drive
  `InferenceService` directly through the direct-inference contract
  (`.tokenEmitted`, `.streamFinished`, `.errorRaised`). It does not
  consume `ConversationEvent` via `ConversationRuntime`.
- Optional later, on Fireside's timeline: if Fireside ever wants to
  collapse `StoryStore`'s orchestration into ManifoldKit's `ConversationRuntime`,
  the four load-bearing runtime events
  (`.beforeContextAssembly`, `.contextAssembled`, `.afterGeneration`,
  `.compressionTriggered`) are the integration points to hook against.
  Not on the critical path for either side's pre-1.0 work.

### Phase 2 — physical target split

ManifoldKit changes:
- `ManifoldCore` deleted.
- `ManifoldRuntime` and `ManifoldPersistenceSwiftData` targets created.
- `ManifoldBootstrap` (renamed) provides the host bootstrap.

Fireside changes (same window):
- Import rewrites:
  - `import ManifoldCore` → `import ManifoldRuntime` for orchestration
    types and ports.
  - `import ManifoldCore` → `import ManifoldPersistenceSwiftData` only
    if Fireside still uses the SwiftData persistence impl. If Fireside
    has fully replaced persistence with custom stores, the dependency
    on `ManifoldPersistenceSwiftData` can be dropped entirely.
- Replace Fireside's custom bootstrap with `ManifoldBootstrap` configured
  with custom `MessageStore` / `SessionStore` instances.
- Drop any inherited `@Model` type imports — they are no longer
  reachable through the public surface.

### Coordination protocol

- Each ManifoldKit PR in Phases 1.2 names the Fireside PR that consumes it
  (and vice versa). Both PRs land in the same review window; merging
  the ManifoldKit PR before the matching Fireside PR is ready breaks Fireside's
  `main`.
- Port-shape changes (signatures, event cases, hook protocols,
  `PromptSlot` shape) require a Fireside reviewer on the ManifoldKit PR before
  merge.
- The two pinned event sets — runtime-using
  (`.beforeContextAssembly`, `.contextAssembled`, `.afterGeneration`,
  `.compressionTriggered`) and direct-inference (`.tokenEmitted`,
  `.streamFinished`, `.errorRaised`, plus `.compressionTriggered` when
  applicable) — and `MessageStorePostWriteHook` are pinned to this
  appendix. Any deviation is updated here in the same PR that
  introduces the deviation — the plan is the source of truth, not
  Slack threads.
- **Exception — internal-only port cleanups (Phase 1.2 sub-step 3).**
  `SamplerPresetStore`, `BenchmarkCache`, and `EndpointStore` close
  `@Query` / public `ModelContext` leaks that Fireside does not
  consume; these PRs do not need a Fireside reviewer or a matching
  Fireside PR. They still go through normal ManifoldKit review, but the
  cross-repo coordination protocol does not gate them.

## Why this is worth doing now

Pre-1.0 is the only window where this refactor is cheap. After 1.0:

- `ChatPersistenceProvider`'s split into per-port protocols is locked.
- `ModelManagementViewModel.modelContext` public surface is locked.
- `ManifoldCore` as a target is locked.
- Each future host integration calcifies the current shape.

The codebase has evolved over 500 PRs and the shape has been trending
toward this design through repeated decompositions (`InferenceService`
split, `ChatViewModel` extractions, `ManifoldUIModelManagement` peel,
storage-neutral records hoisted into Inference, `ChatPersistenceProvider`
port, the Phase 1.0/1.1 work above). This refactor is the formalisation
and completion of work already underway.

If it succeeds:

- **demo app** remains the reference implementation.
- **ChatbotUI-iOS** gets a cleaner customization surface without
  forking ManifoldKit.
- **Fireside** uses ManifoldKit runtime/inference as a subsystem without
  inheriting ManifoldKit's UI and persistence assumptions.

One runtime center, multiple host shapes, and no further pressure to
push app logic into UI modules just because those modules currently
own the composition story.
