# Plan — Target Architecture ("The Manifold")

This is a **planning artifact**, not user-facing documentation and not an implementation
plan. It captures the agreed *end state* for ManifoldKit's module architecture so a
subsequent migration plan can be argued against a fixed target. When the structure
stabilises, the adopter-facing version becomes a DocC article.

## Status

- **End state:** agreed (this document).
- **Migration plan:** [`target-architecture-migration.md`](./target-architecture-migration.md).
- **Consumer assumption:** *public framework, diverse adopters.* Keep à-la-carte assembly;
  make optionality **legible**, don't remove it.
- **Diagram audience:** unified — one picture serves maintainers (north-star) and adopters
  (consumption map).
- **Decided design forks:**
  - **Modality** generifies to a single `MediaGeneration<Output>` seam (no per-modality
    vertical clones), with concrete typealiases (`ImageGeneration`, `VideoGeneration`,
    `AudioGeneration`) so adopters rarely write the generic.
  - **Agentic:** MK **commits to stateful/resumable runs only** (the on-device-defensible
    bet — leans on the persistence battery SK lacks). **Multi-agent and plan-execute are
    out of scope until an adopter explicitly needs them** — the pluggable turn-driver seam
    keeps the door open, but we do not build for them now. Rationale: multi-agent fan-out
    burns the context/tokens on-device 3B–8B models are most starved for; it is a
    cloud-scale pattern, not an on-device one.
- **WWDC posture (keynote 2026-06-08):** the migration's P0 (decisions + the
  `SessionToolSource` bug) and P1 (pure file-moves) are WWDC-independent and may start now;
  P2–P4 sequencing is re-confirmed after the keynote, since Apple's agent/tool/on-device-media
  announcements could reshape the driver and media seams.

## The frame: ManifoldKit *is* a manifold

The name encodes the architecture. The canonical visual reads as a literal intake manifold
first, software diagram second: **many model backends flow in → one common core normalises
them → a single conversation-event stream flows out to many consumers**, with side ports for
tools/data and a bottom port for persistence.

```
   INLETS (backends)            ┌──── THE CORE MANIFOLD ────┐          OUTLETS (consumers)
   ── adapters plug in ──►      ║                            ║   ──► one event stream ──►
                                ║   ◆ CONTRACT (kernel)      ║
   MLX        ┐                 ║   InferenceBackend proto   ║              ┌─ ManifoldUI (drop-in chat)
   Llama      ├─[Registrar]───► ║   BackendCapabilities      ║ ────────────►├─ your own SwiftUI
   Foundation ├──────────────── ║   GenerationEvent language ║   normalized ├─ ManifoldServer (HTTP)
   Cloud      ┘                 ║   tool & message contracts ║   stream     └─ CLI / headless
   MediaGen   ┐                 ║   ──────────────────────── ║
   (img/vid/  ├──[generic seam]►║   ◆ ENGINE                 ║
    audio)    ┘                 ║   Orchestration +          ║
                                ║   ▸ pluggable TURN-DRIVER  ║
   SIDE PORTS (tools / data)    ║     (single-turn today ·   ║
   MCP        ┐                 ║      resumable Run next)   ║
   AppIntents ├─[ToolSource]──► ║   over a RUN (resumable)   ║
   RAG / HF   ┘                 ║                            ║
                                └────────────┬───────────────┘
                                             │ ports (dependency-inverted)
                              PERSISTENCE (messages · sessions · RUN checkpoints)
```

A rendered diagram exists (manifold cross-section: colour-coded inlets converging to one
white stream, nested CONTRACT-inside-ENGINE core, chromed multi-branch outlet header, top
tool/data taps, bottom persistence port, depth-of-import tier legend). Add the export to the
repo when the structure lands.

## Verified baseline (fact-checked against current code — do not re-litigate)

Corrected several stale session-memory assumptions:

- **Single turn loop, no fork.** `ConversationRuntime` is the canonical, non-optional turn
  loop (PR #947). The old `GenerationCoordinator` was renamed `GenerationQueue` (#973) and
  sits *below* the loop as the inference-tier engine — not an alternative path.
- **`InferenceService` is a real facade**, not a god-object: ~985 LOC delegating to
  `ModelLifecycleCoordinator` (589) + `GenerationQueue` (929, further decomposed in #1165).
- **DAG is acyclic and points inward.** Backend families import *only* `ManifoldInference`;
  `ManifoldUI` imports no backend; conversation **records** live in `ManifoldInference`,
  persistence **ports** in `ManifoldRuntime`; no cycles.
- **The kernel is already small inside a large module.** Of `ManifoldInference`'s 25.1k LOC,
  only **~3.4k (14%)** is the actual contract; the rest is evictable mass.
- **The turn loop is the heaviest concept** and the instability epicenter:
  `ConversationTurnExecutor` (1,628 LOC) + `ConversationRuntime` are the hottest-churn files,
  mixing features and race-fixes, co-changing 12× (a false 2-file boundary).
- **Tooling is a clean absorber; agentic orchestration is not.** Adding a tool = conform
  `ToolExecutor` + register. But resumable/multi-step orchestration lands squarely on the
  un-refined `ConversationTurnExecutor`, which has **no turn-strategy/driver abstraction**.

## Moat thesis (triangulated)

Four lenses — historical churn, modality-ripple, agentic-ripple, and DX/reliability —
converge:

1. **The backend / tool / connector seams are strong absorbers. Protect them.** New models,
   engines, tools, consumers, and (per the WWDC analysis) a new Apple *text* surface all plug
   in at the edge. This is the industry-standard kernel *shape*.
2. **The kernel shape is table stakes — but the *quality* of the shape is not.** Reliability
   and DX (the one-import promise, a `quickStart()` that actually chats, a clean error
   surface) are where MK out-competes Semantic Kernel / LangChain, which are rough to operate.
   The usability work below is **moat investment, not cleanup.**
3. **The defensible moat is the on-device-first normalization + batteries-included runtime**
   (MLX/Llama/Foundation behind one capability-negotiated contract, plus persistence + UI) —
   precisely what SK/LangChain lack.
4. **The single highest-leverage refinement is cracking the engine turn-loop monolith into a
   pluggable driver seam over a resumable `ConversationRun`.** It is the chokepoint where
   modality, resumable runs, and (future, optional) richer orchestration all collide. One
   refinement, compounding returns.

## Target structure — concentric tiers (structure == consumption)

Dependencies point inward to the Contract, so *how deep an adopter imports is how much they
opt in.* The four rings are simultaneously the internal layering and the consumption ladder.
Each component carries: **Responsibility · Owns · Public surface · Edges · Invariants ·
Absorbs / Amplifies · Evolution.**

---

### RING 0 — CONTRACT (the kernel)  ·  product: `ManifoldInference` (target ~3.4k LOC)

The stable, SemVer-critical public API. Everything connects here; versioned most carefully.

- **Responsibility:** define *what* an inference/media backend is, *what* a tool is, and the
  vocabulary of a generation — nothing about *how* a conversation runs.
- **Owns:** `InferenceBackend`, `BackendCapabilities`, `GenerationConfig`, `GenerationEvent`,
  `EmbeddingBackend`, the media-gen backend protocol(s), `ToolDefinition`/`ToolCall`/
  `ToolResult`/`ToolChoice`/`ToolOutputPolicy`, `MessagePart`/`MessageKind`/`MessageRole`/
  `Message`, `ConversationRecords` (records, not ports), `BackendRegistrar`, `Citation`.
- **Public surface:** the entire module is API. Additive enum cases + additive struct fields
  are minor; any protocol-requirement or signature change is major.
- **Edges:** depends on nothing (except the `@ToolSchema` macro under `Macros`). Depended on
  by *everything*.
- **Invariants:** no SwiftData, no SwiftUI, no networking, no persistence ports, no
  orchestration. Records live here; ports do not.
- **Absorbs:** new models/engines; new tools; additive capability flags; additive
  `GenerationEvent` *payloads*.
- **Amplifies (to fix):** `GenerationEvent` *cases* are source-breaking across ~14 consumers;
  `MessagePart` cases force exhaustive-switch + schema churn; `ToolResult.content` is
  `String`-only (blocks typed/multimodal tool output before a 1.0 freeze).
- **Evolution:** stay thin — evict the ~86% non-contract mass to utility leaves and adapters.
  Keep pushing backend variation into *additive `BackendCapabilities` flags*. Decide the
  additive shape for non-text `ToolResult` and run-level events *before* 1.0 locks them.

---

### RING 1 — ENGINE  ·  product: `ManifoldEngine` (merges today's `ManifoldRuntime` + the orchestration evicted from the kernel)

Detailed as **three** components, because the leverage lives in separating them. Cut by
*"is it orchestration,"* not *"does it touch persistence."*

#### 1a — Orchestration core
- **Responsibility:** own the public conversation API and the per-turn machinery.
- **Owns:** `ConversationRuntime` (`send`/`regenerate`/`edit`/`branch`/`cancel`), prompt
  assembly, context budgeting, the generation queue, transcript healing, streaming, the event
  subsystem (`ConversationEvent`/`EventTapRegistry`/`ConversationEventRecorder`).
- **Public surface:** `ConversationRuntime`'s verb API + the event stream + the public
  `ConversationEventRecorder` (Glass Box, #1531).
- **Edges:** depends on Contract; consumes persistence + tool + driver via ports.
- **Invariants:** no SwiftData, no SwiftUI, no concrete backend.
- **Amplifies (to fix):** persistence-writes and event-emission are tangled *inside*
  `ConversationTurnExecutor` (co-change 7× and 5×) — move them behind narrow ports.
- **Evolution:** shrink `ConversationTurnExecutor` from a monolith to a thin per-turn executor
  the **driver** calls.

#### 1b — Turn-Driver seam  ·  *NEW first-class component (the enabler)*
- **Responsibility:** decide *how* a goal becomes turns/steps. The pluggable strategy.
- **Owns:** a `TurnDriver` protocol + conformers:
  - `SingleTurnDriver` — today's linear behavior (default, always available). **Committed.**
  - `ResumableRunDriver` — long-running, checkpointed, resumable runs. **Committed** (the
    on-device-shaped agentic bet).
  - `MultiAgentDriver`, `PlanExecuteDriver` — **seam-enabled but NOT committed.** Built only
    on explicit adopter demand. The seam guarantees they can be added as EDGE conformers.
- **Public surface:** `TurnDriver` (conform to add a strategy); driver selection on the
  run/turn input.
- **Edges:** sits between the orchestration core and the per-turn executor; reconciles the
  current Inference/Runtime dispatch split so a future agent-as-tool could re-enter cleanly.
- **Invariants:** drivers are additive — adding one is EDGE, never engine surgery. Single-turn
  remains the zero-config default.
- **Absorbs (by design):** resumable runs now; richer orchestration later without re-cutting
  the engine.
- **Evolution:** this seam is MK's lightweight, MK-shaped answer to SK's orchestration
  layers — ship `SingleTurnDriver` (refactor-in-place) then `ResumableRunDriver`.

#### 1c — Run model + ports  ·  *NEW, the committed stateful/resumable capability*
- **Responsibility:** represent a `ConversationRun` (a multi-step unit above a turn) with
  persisted, resumable state and checkpoints.
- **Owns:** `ConversationRun`/`RunStep` value types, run-level events (started/step/paused/
  resumed/completed), and the **`RunStore` port** + checkpoint records.
- **Public surface:** the run API on `ConversationRuntime` (start/pause/resume/cancel a run);
  `RunStore` for hosts.
- **Edges:** persistence ports (Ring 2 SwiftData implements `RunStore`); the driver executes a
  `ConversationRun`.
- **Invariants:** **run-level events must NOT be added as `GenerationEvent` cases** — they
  ride their own event type (precedent: `ImageRuntimeEvent` is deliberately separate from the
  text-path event vocabulary so exhaustive switches stay closed).
- **Absorbs:** resumable/long-running/checkpointed orchestration without touching the text
  event vocabulary.
- **Evolution:** persistence gains run/checkpoint storage (schema bump). *Agent stack/tree
  state is part of the deferred multi-agent track — not built now.*

Also in the Engine tier: **ports** (`MessageStore`, `SessionStore`, `EndpointStore`,
`SamplerPresetStore`, `VectorStore`, `DocumentStore`, `UsageStore`, `RunStore`), **hooks**
(`HookRegistry`/`PreToolUseHook`/`GenerationHook`; expand to `postToolUse`/`onTurnComplete`/
`onRunStep` as the run model lands), and **RAG/export/import** use cases.

---

### RING 2 — ADAPTERS (à-la-carte products that plug into the Contract / Engine ports)

Each depends down on the Contract (and Engine ports where relevant), never on each other.

#### Inference backends (inlets)
- **Products:** `ManifoldMLX`, `ManifoldLlama`, `ManifoldFoundation`, `ManifoldCloud`
  (+ `ManifoldCloudCore`).
- **Absorbs:** new engine/provider = conform + register (EDGE).
- **Amplifies (to fix):** `APIProvider` enum behind ~14 exhaustive switches.
  **Evolution / acceptance metric:** make provider selection registry/descriptor-driven so
  *adding a cloud provider drops from editing ~14 switches to registering 1 descriptor*.
- **Invariants:** never import Runtime/Engine or each other; never import UI. Heavy deps
  trait-gated.

#### Media-generation backends (generic seam) — *decided refactor*
- **Responsibility:** image / video / **audio (incl. realtime)** behind ONE generic seam.
- **Owns (target):** `MediaGeneration<Output>` + `MediaGenerationService<Output>` +
  `MediaGenerationRuntime<Output>` over a `GeneratedMediaPayload` protocol, with a shared media
  event type (one-shot *and* a streaming/duplex variant for realtime audio). **Provide
  concrete typealiases** (`ImageGeneration`, `VideoGeneration`, `AudioGeneration`) so adopters
  rarely write the generic.
- **Invariants:** generated media funnels through a single `MessagePart.generatedMedia
  (GeneratedMediaPayload)` case; media events stay OFF the text-path switch.
- **Absorbs (acceptance metric):** *a new modality = conform the generic seam in ≤3 EDGE
  files*, not a ~14-file 5-module clone. This is the WWDC hedge against an Apple on-device
  *media* surface.

#### Tool sources / data side-ports
- **Products:** `ManifoldMCP`, `ManifoldMCPHost`, `ManifoldAppIntents`, `ManifoldHuggingFace`
  (+ RAG in the Engine).
- **Public surface:** `ToolExecutor`/`ToolRegistry` (live dispatch) and `SessionToolSource`
  (advertising/allow-listing).
- **Absorbs:** new tool / MCP server / AppIntent = conform + register (EDGE). Approval,
  streaming progress, cancellation already first-class.
- **Amplifies / debt (to fix):** **`SessionToolSource.resolve` is dead in the dispatch path**
  — `generate_image`/`generate_video`/`web_search` are advertised but unreachable. Wire it or
  make `SessionToolSource` advertising-only by design. Parallel tool dispatch is declared but
  not wired.

#### Persistence (bottom port)
- **Product:** `ManifoldPersistenceSwiftData`.
- **Invariants:** the only place SwiftData lives.
- **Evolution:** implement the new `RunStore` + checkpoint records (schema bump).

---

### RING 3 — APP LAYER (batteries-included)  ·  `ManifoldUI`, `ManifoldUIModelManagement`, `ManifoldVoice`, bootstrap, `ManifoldKit` umbrella

- **Public surface:** `ChatView`/`ChatViewModel`, `ManifoldBootstrap`, `quickStart()`.
- **Edges:** Engine + Contract; CloudCore under `CloudSaaS`. **Never** a backend (CI-lint).
- **Absorbs:** new consumer = read the event stream + ports (CORE-free).
- **Amplifies / moat work (was "debt"):** `quickStart()` yields a chat that can't chat
  (registers backends, selects/loads none); cloud is off-by-default behind a trait edit;
  "one import" is contradicted by examples; 9 `configure*` overloads. **The target fixes
  these as moat investment** — incl. a defined first-launch **backend-selection policy**
  (prefer Foundation Models if available → first registered local backend → a clearly-labeled
  empty state), so a fresh install is never a blank composer.

---

### Utility leaves (evicted from the kernel)
- `ManifoldNetworking` — networking policy/factory + CloudCore SSE/TLS/DNS infra.
- `ManifoldSecrets` — `Security/` + `KeychainService`.
- Device-capability + GGUF readers → adapter-side (MLX/Llama only).
- Model discovery / catalog / benchmark → their own products.

## Expansion axes (the design forces this target must absorb)

| Axis | Today | Target seam | Cost after refactor |
|---|---|---|---|
| **Modality** (img/video/**audio/realtime**) | per-modality 5-module clone (~14 files) | generic `MediaGeneration<Output>` + single `MessagePart.generatedMedia` | ≤3 EDGE files |
| **Resumable runs** (committed) | none; single linear turn | `ResumableRunDriver` over `ConversationRun` + `RunStore` | conform a driver (EDGE) |
| **Richer orchestration** (multi-agent / plan-execute — deferred) | n/a | the same `TurnDriver` seam (door kept open) | conform a driver, when an adopter needs it |
| **Models / providers** | `InferenceBackend` clean, but `APIProvider` in ~14 switches | registry/descriptor-driven provider selection | register a descriptor |
| **Consumers** | already clean | event stream + ports | CORE-free |

## Consumption ladder
| Adopter wants… | Reaches to… | Imports | Brings |
|---|---|---|---|
| Drop-in chat app | App layer | `ManifoldKit` (umbrella) | nothing |
| Own UI, our engine | Engine | `ManifoldEngine` + a backend + a store | views |
| Headless / CLI / server | Contract + Engine | `ManifoldInference` + `ManifoldEngine` + a backend | loop |
| New backend / provider / driver | Contract only | `ManifoldInference` | conform + register |

## Invariants the target must preserve
1. Acyclic, inward-pointing dependencies — everything depends toward the Contract.
2. UI never imports a backend (CI-lint enforced).
3. Records in the Contract; ports in the Engine; adapters implement ports.
4. Heavy-dependency traits stay traits; product-selection-equivalent traits retire.
5. The Contract is the SemVer surface — breaking it is a major bump; adapters may churn.
6. **New modality/run-level events ride their own event types — never new `GenerationEvent`
   cases on the text path.** *(Needs a tripwire audit test — see migration plan.)*
7. **Adding a driver or a modality is EDGE, never engine surgery.** *(Needs a tripwire.)*
8. **Every adopter-affecting change ships a migration guide + `@available(deprecated,
   renamed:)` annotations; `@_exported` shims live ≥2 minor releases.**

## Trait disposition (target)
- **Stay:** `MLX`, `Llama`, `HuggingFace`, `Macros`, `Server`, `AnyLanguageModel`,
  `FoundationOnly`, `Fuzz` (Xcode-scheme collision #982), WWDC stubs.
- **Retire → product opt-in (clean):** `MCP`, `Voice`, `Tools`, `AppIntents`.
- **Retire → product, blocked on source extraction first:** `Ollama` (36 in-body `#if`),
  `CloudSaaS` (53).
- **Decide later:** `MCPBuiltinCatalog`, `Skills`.

## Known debts & hard problems (carry into the migration plan)
1. **The one real refactor gate: `InferenceService.GenerationRequestToken`.** UI binds the
   concrete `InferenceService` at ~9 declaration + 22 call sites. Decision: App-above-Engine
   (UI names the concrete type); protocol-token abstraction is later polish.
2. **`ConversationTurnExecutor` monolith** must be split into orchestration + thin executor +
   driver before the run model piles on.
3. **Tool-dispatch layer split** (Inference vs Runtime) must be reconciled by the driver seam.
4. **`SessionToolSource.resolve` dead path** — live bug; wire or redesign.
5. **`APIProvider` exhaustive-switch sprawl** — make descriptor-driven.
6. **Run/checkpoint persistence** — new `RunStore` + schema migration; resumable state needs
   injected clock/IDs to be deterministically testable.
7. **Ollama/CloudSaaS `#if` extraction** before those traits can retire.
8. **Module naming** — `ManifoldEngine`, `ManifoldNetworking`, `ManifoldSecrets`,
   `ConversationRun`; whether the App layer is one `ManifoldAppKit` or stays separate products.
9. **Back-compat** — `@_exported import` shims on old module names; retire in a final breaking
   release (≥2-minor deprecation window).
10. **Lockstep CI** — `FeatureMatrix.swift`, cold-start gates, `PackageTraitGateAuditTest`
    move with any trait/module change.
11. **No turn-loop characterization harness exists** — the P2/P3 "behavior-preserving" claims
    are unprovable until one is built (migration P0c).

## Semantic Kernel orientation (where MK sits in the landscape)
MK's inference+tooling **core** is ~60–70% the standard kernel shape SK/LangChain share
(backends ≈ connectors, `ToolRegistry` ≈ plugins, the tool loop ≈ auto-invocation, RAG ≈
memory, both speak MCP) — so the kernel shape is **table stakes, not the moat**. MK diverges
as an **on-device-first Swift chat *runtime* with batteries SK omits** (persistence + SwiftUI
UI), organised around one normalizing event stream + one turn loop. Of the two capabilities SK
has and MK lacks — multi-agent orchestration and a stateful/resumable process engine — **MK
commits only to the latter** (resumable runs, the on-device-defensible one), built MK-shaped
on the TurnDriver seam + `ConversationRun`. **Multi-agent is explicitly deferred**: it is a
cloud-scale fan-out pattern poorly suited to on-device context budgets, and the seam keeps the
option open without paying for it now.

## Explicitly out of scope here
The sequenced migration, PR scoping, test-infra prerequisites, and issue creation — see
[`target-architecture-migration.md`](./target-architecture-migration.md).
