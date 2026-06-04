# Plan — Target Architecture ("The Manifold")

This is a **planning artifact**, not user-facing documentation and not an implementation
plan. It captures the agreed *end state* for ManifoldKit's module architecture so a
subsequent migration plan can be argued against a fixed target. When the structure
stabilises, the adopter-facing version becomes a DocC article.

## Status

- **End state:** agreed (this document).
- **Migration plan:** deferred until this target is signed off — written as a separate doc.
- **Consumer assumption:** *public framework, diverse adopters.* Keep à-la-carte assembly;
  make optionality **legible**, don't remove it.
- **Diagram audience:** unified — one picture serves maintainers (north-star) and adopters
  (consumption map).
- **Decided design forks:**
  - **Modality** generifies to a single `MediaGeneration<Output>` seam (no more per-modality
    vertical clones).
  - **Agentic:** MK **commits to growing multi-agent + stateful/resumable runs**, built
    *MK-shaped* (on a pluggable turn-driver seam + the `GenerationEvent`/event stream +
    persistence ports) — **not** as bolted-on Semantic-Kernel-style separate frameworks.

## The frame: ManifoldKit *is* a manifold

The name encodes the architecture. The canonical visual reads as a literal intake manifold
first, software diagram second: **many model backends flow in → one common core normalises
them → a single conversation-event stream flows out to many consumers**, with side ports for
tools/data/agents and a bottom port for persistence.

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
   SIDE PORTS (tools / agents)  ║     (single · plan-exec ·  ║
   MCP        ┐                 ║      multi-agent · autonom)║
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
  `ToolExecutor` + register. But multi-agent/planning/autonomous runs land squarely on the
  un-refined `ConversationTurnExecutor`, which has **no turn-strategy/driver abstraction**.

## Moat thesis (triangulated)

Three independent lenses — historical churn, modality-ripple, agentic-ripple — converge on
the same conclusion:

1. **The backend / tool / connector seams are strong absorbers. Protect, don't polish.**
   New models, engines, tools, consumers, and (per the WWDC analysis) a new Apple *text*
   surface all plug in at the edge. This is the industry-standard kernel shape — table
   stakes, not differentiation.
2. **The defensible moat is the on-device-first normalization + batteries-included runtime**
   (MLX/Llama/Foundation behind one capability-negotiated contract, plus persistence + UI).
   This is precisely what Semantic Kernel / LangChain *lack*.
3. **The single highest-leverage refinement is cracking the engine turn-loop monolith into a
   pluggable driver seam over a resumable `Run`.** It is the chokepoint where *every*
   expansion axis collides — modality, multi-agent, planning. One refinement, compounding
   returns.

## Target structure — concentric tiers (structure == consumption)

Dependencies point inward to the Contract, so *how deep an adopter imports is how much they
opt in.* The four rings are simultaneously the internal layering and the consumption ladder.
Each component below carries: **Responsibility · Owns · Public surface · Edges · Invariants ·
Absorbs / Amplifies · Evolution.**

---

### RING 0 — CONTRACT (the kernel)  ·  product: `ManifoldInference` (target ~3.4k LOC)

The stable, SemVer-critical public API. Everything connects here; versioned most carefully.

- **Responsibility:** define *what* an inference/media backend is, *what* a tool is, and the
  vocabulary of a generation — nothing about *how* a conversation runs.
- **Owns:** `InferenceBackend`, `BackendCapabilities`, `GenerationConfig`, `GenerationEvent`,
  `EmbeddingBackend`, the media-gen backend protocol(s), `ToolDefinition`/`ToolCall`/
  `ToolResult`/`ToolChoice`/`ToolOutputPolicy`, `MessagePart`/`MessageKind`/`MessageRole`/
  `Message`, `ConversationRecords` (records, not ports), `BackendRegistrar`, `Agent`/
  `AgentHandoff` value types, `Citation`.
- **Public surface:** the entire module is API. Treat additive enum cases + additive struct
  fields as minor; any protocol-requirement or signature change is major.
- **Edges:** depends on nothing (except the `@ToolSchema` macro plugin under the `Macros`
  trait). Depended on by *everything*.
- **Invariants:** no SwiftData, no SwiftUI, no networking, no persistence ports, no
  orchestration. Records live here; ports do not.
- **Absorbs:** new models/engines (conform `InferenceBackend`); new tools (`ToolDefinition`);
  additive capability flags; additive `GenerationEvent` *payloads*.
- **Amplifies (to fix):** `GenerationEvent` *cases* are source-breaking across ~14 consumers;
  `MessagePart` cases force exhaustive-switch + schema churn; `ToolResult.content` is
  `String`-only (blocks typed/multimodal tool output before a 1.0 freeze).
- **Evolution:** stay thin — evict the ~86% non-contract mass (infra, GGUF, device, catalog,
  discovery, HF probe) to utility leaves and adapters. Keep pushing backend variation into
  *additive `BackendCapabilities` flags* (the pressure-relief valve) rather than new protocol
  requirements. Decide the additive shape for non-text `ToolResult` and run/agent events
  *before* 1.0 locks them.

---

### RING 1 — ENGINE  ·  product: `ManifoldEngine` (merges today's `ManifoldRuntime` + the orchestration evicted from the kernel)

The engine is detailed as **three** components, because the leverage lives in separating
them. Cut by *"is it orchestration,"* not *"does it touch persistence."*

#### 1a — Orchestration core
- **Responsibility:** own the public conversation API and the per-turn machinery.
- **Owns:** `ConversationRuntime` (`send`/`regenerate`/`edit`/`branch`/`cancel`), prompt
  assembly (`PromptAssembler`/`PromptTemplate`/`PromptSlot`), context budgeting
  (`ContextWindowManager`/`ContextBudgetPlanner`/`GenerationPreflightTrimmer`), the
  generation queue (`GenerationQueue`), transcript healing, streaming, the event subsystem
  (`ConversationEvent`/`EventTapRegistry`/`ConversationEventRecorder`).
- **Public surface:** `ConversationRuntime`'s verb API + the event stream + the public
  `ConversationEventRecorder` (Glass Box, #1531).
- **Edges:** depends on Contract; consumes persistence + tool + driver via ports.
- **Invariants:** no SwiftData, no SwiftUI, no concrete backend.
- **Absorbs:** new consumers (read the event stream), new hooks, new tool sources.
- **Amplifies (to fix):** today persistence-writes and event-emission are tangled *inside*
  `ConversationTurnExecutor` (co-change 7× and 5×) — they must move behind narrow ports.
- **Evolution:** shrink `ConversationTurnExecutor` from a 1,100-LOC monolith to a thin
  per-turn executor that the **driver** calls; lift persistence + event-emit to ports.

#### 1b — Turn-Driver seam  ·  *NEW first-class component*
- **Responsibility:** decide *how* a goal becomes turns/agent-steps. This is the pluggable
  strategy the agentic commitment requires.
- **Owns:** a `TurnDriver` protocol + conformers:
  - `SingleTurnDriver` — today's linear behavior (default, always available).
  - `PlanExecuteDriver` — goal decomposition / ReAct-style plan→act phases.
  - `MultiAgentDriver` — concurrent / collaborating sub-agents, agent-as-tool, handoff.
  - `AutonomousRunDriver` — long-running, checkpointed, resumable runs.
- **Public surface:** `TurnDriver` (conform to add an orchestration shape); driver selection
  on the run/turn input.
- **Edges:** sits between `ConversationRuntime` (orchestration) and the per-turn executor;
  uses the Contract's tool/agent types; reconciles the **current Inference/Runtime dispatch
  split** (the reactive tool loop in `GenerationToolDispatchLoop` vs agent/handoff
  orchestration in the executor) so "agent-as-tool" can re-enter the runtime cleanly.
- **Invariants:** drivers are additive — adding one must be EDGE (conform + register), never
  engine surgery. Single-turn behavior must remain the zero-config default.
- **Absorbs (by design):** multi-agent, planning, autonomous runs — the whole agentic axis.
- **Evolution:** this seam *is* MK's answer to SK's Agent Framework + Process Framework,
  built MK-shaped. Ship `SingleTurnDriver` first (refactor-in-place), then add drivers.

#### 1c — Run model + ports  ·  *NEW, required by the stateful/resumable commitment*
- **Responsibility:** represent a `Run` (a multi-step unit above a turn) with persisted,
  resumable state and checkpoints.
- **Owns:** `Run`/`RunStep` value types, run-level events (started/step/paused/resumed/
  completed), and the **`RunStore` port** + checkpoint records. Agent state generalises from
  a single `activeAgentID` to an **agent stack/tree**.
- **Public surface:** the `Run` API on `ConversationRuntime` (start/pause/resume/cancel a
  run); `RunStore` port for hosts.
- **Edges:** persistence ports (Ring 2 SwiftData implements `RunStore`); the driver executes
  a `Run`.
- **Invariants:** **run/agent events must NOT be added as `GenerationEvent` cases** — they
  ride their own event type (precedent: `ImageRuntimeEvent` is deliberately separate from
  the text-path `ConversationEvent` so exhaustive switches stay closed). This is the modality
  lesson applied to agentic.
- **Absorbs:** resumable/long-running/checkpointed orchestration without touching the text
  event vocabulary.
- **Evolution:** the persistence layer must gain run/checkpoint storage (SwiftData schema
  bump) — sequence this with the driver work.

Also in the Engine tier: **ports** (`MessageStore`, `SessionStore`, `EndpointStore`,
`SamplerPresetStore`, `VectorStore`, `DocumentStore`, `UsageStore`, `RunStore`), **hooks**
(`HookRegistry`/`PreToolUseHook`/`GenerationHook` — expand coverage to `postToolUse`/
`onTurnComplete`/`onHandoff`/`onRunStep` as drivers land), and **RAG/export/import** use
cases.

---

### RING 2 — ADAPTERS (à-la-carte products that plug into the Contract / Engine ports)

Each depends down on the Contract (and Engine ports where relevant), never on each other —
the "provider package" model expressed as SwiftPM products.

#### Inference backends (inlets)
- **Products:** `ManifoldMLX`, `ManifoldLlama`, `ManifoldFoundation`, `ManifoldCloud`
  (+ `ManifoldCloudCore`).
- **Responsibility:** implement `InferenceBackend` for one engine/provider.
- **Public surface:** the conformer + its `BackendRegistrar`.
- **Edges:** Contract only (Cloud also CloudCore). Heavy deps (MLX, LlamaSwift) stay
  trait-gated.
- **Invariants:** never import Runtime/Engine or each other; never import UI.
- **Absorbs:** new engine/provider = conform + register (EDGE).
- **Amplifies (to fix):** `APIProvider` is an enum behind ~14 exhaustive switches — adding a
  cloud provider ripples. **Evolution:** make provider selection registry/descriptor-driven
  (the registrar already uses a factory closure — extend it to encoding/extraction) so a new
  provider is "register a descriptor," not "edit 14 switches."

#### Media-generation backends (generic seam) — *decided refactor*
- **Responsibility:** image / video / **audio (incl. realtime)** generation behind ONE
  generic seam, replacing the per-modality vertical clones.
- **Owns (target):** `MediaGeneration<Output>` backend + `MediaGenerationService<Output>` +
  `MediaGenerationRuntime<Output>` over a `GeneratedMediaPayload` protocol, with a shared
  media event type (allowing both one-shot `progress→completed` *and* a streaming/duplex
  variant for realtime audio).
- **Edges:** Contract; MLX-family diffusion impls under the `MLX` trait.
- **Invariants:** generated media funnels through a single `MessagePart.generatedMedia
  (GeneratedMediaPayload)` case (not per-type cases) — one Codable key, one UI render branch.
  Media events stay OFF the text-path `GenerationEvent` switch.
- **Absorbs (by design):** a new modality = conform the generic seam (~3 EDGE files), not a
  ~14-file 5-module clone. This is the WWDC hedge against an Apple on-device *media* surface.

#### Tool sources / agentic side-ports
- **Products:** `ManifoldMCP`, `ManifoldMCPHost`, `ManifoldAppIntents`, `ManifoldHuggingFace`
  (+ RAG in the Engine).
- **Responsibility:** contribute tools/agents/data into the registry.
- **Public surface:** `ToolExecutor`/`ToolRegistry` (the live dispatch seam) and
  `SessionToolSource` (advertising/allow-listing).
- **Invariants:** external tool universes (MCP, AppIntents) collapse onto `ToolExecutor`.
- **Absorbs:** new tool / MCP server / AppIntent = conform + register (EDGE). Approval,
  streaming progress, cancellation already first-class.
- **Amplifies / debt (to fix):** **`SessionToolSource.resolve` is dead in the dispatch path**
  — `generate_image`/`generate_video`/`web_search` are advertised but unreachable (no
  `SessionToolSource → ToolExecutor` adapter). Either wire it per-turn or make
  `SessionToolSource` advertising-only by design and route execution through `ToolExecutor`.
  Also: parallel tool dispatch is *declared* (`supportsConcurrentDispatch`) but not wired.

#### Persistence (bottom port)
- **Product:** `ManifoldPersistenceSwiftData`.
- **Responsibility:** implement the Engine ports against SwiftData; own schema + `Bootstrap`.
- **Edges:** Engine ports + Contract records.
- **Invariants:** the only place SwiftData lives.
- **Evolution:** must implement the new `RunStore` + checkpoint records (schema bump) for the
  stateful/resumable commitment.

---

### RING 3 — APP LAYER (batteries-included)  ·  `ManifoldUI`, `ManifoldUIModelManagement`, `ManifoldVoice`, bootstrap, `ManifoldKit` umbrella

- **Responsibility:** drop-in SwiftUI chat + model-management UI + the one-import umbrella.
- **Public surface:** `ChatView`/`ChatViewModel`, `ManifoldBootstrap`, `quickStart()`.
- **Edges:** Engine + Contract; CloudCore under `CloudSaaS`. **Never** a backend (CI-lint).
- **Absorbs:** new consumer = read the event stream + ports (CORE-free).
- **Amplifies / debt (usability, to fix in target):** `quickStart()` yields a chat that
  can't chat (registers backends, selects/loads none); cloud is off-by-default behind a trait
  edit; "one import" is contradicted by examples importing `ManifoldUI` too; 9 `configure*`
  overloads. The target bakes in: umbrella genuinely one-import; `quickStart()` brings a
  default inlet live; cloud not a silent wall.

---

### Utility leaves (evicted from the kernel)
- `ManifoldNet` — networking policy/factory + CloudCore SSE/TLS/DNS infra.
- `ManifoldSecrets` — `Security/` + `KeychainService`.
- Device-capability + GGUF readers → adapter-side (MLX/Llama only).
- Model discovery / catalog / benchmark → their own products.

## Expansion axes (the design forces this target must absorb)

| Axis | Today | Target seam | Cost after refactor |
|---|---|---|---|
| **Modality** (img/video/**audio/realtime**) | per-modality 5-module clone (~14 files) | generic `MediaGeneration<Output>` + single `MessagePart.generatedMedia` | ~3 EDGE files |
| **Agentic** (multi-agent, plan-execute, autonomous) | single-active-agent + handoff on a monolith | pluggable **TurnDriver** seam over a resumable **Run** | conform a driver (EDGE) |
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
6. **New modality/agentic events ride their own event types — never new `GenerationEvent`
   cases on the text path.**
7. **Adding a driver or a modality is EDGE, never engine surgery.**

## Trait disposition (target)
- **Stay:** `MLX`, `Llama`, `HuggingFace`, `Macros`, `Server`, `AnyLanguageModel`,
  `FoundationOnly`, `Fuzz` (Xcode-scheme collision #982), WWDC stubs
  (`SystemAIProviderExtension`, `CoreAI`).
- **Retire → product opt-in (clean):** `MCP`, `Voice`, `Tools`, `AppIntents`.
- **Retire → product, blocked on source extraction first:** `Ollama` (36 in-body `#if`),
  `CloudSaaS` (53).
- **Decide later:** `MCPBuiltinCatalog`, `Skills`.

## Known debts & hard problems (carry into the migration plan)
1. **The one real refactor gate: `InferenceService.GenerationRequestToken`.** UI binds the
   concrete `InferenceService` at ~9 declaration + 22 call sites; the nested token type is the
   tightest knot. The engine carve needs either App-above-Engine (UI names the concrete type)
   or a protocol-level token abstraction.
2. **`ConversationTurnExecutor` monolith** (1,100–1,628 LOC) must be split into orchestration
   + thin executor + driver before agentic expansion piles on.
3. **Tool-dispatch layer split** (Inference `GenerationToolDispatchLoop` vs Runtime executor)
   must be reconciled so agent-as-tool can re-enter cleanly.
4. **`SessionToolSource.resolve` dead path** — live bug; wire or redesign.
5. **`APIProvider` exhaustive-switch sprawl** — make descriptor-driven.
6. **Run/checkpoint persistence** — new `RunStore` + schema migration for resumable runs.
7. **Ollama/CloudSaaS `#if` extraction** before those traits can retire.
8. **Module naming** — `ManifoldEngine`, `ManifoldNet`, `ManifoldSecrets`; whether the App
   layer is one `ManifoldAppKit` or stays separate products.
9. **Back-compat** — `@_exported import` shims on old module names during migration; retire
   in a final breaking release.
10. **Lockstep CI** — `FeatureMatrix.swift`, cold-start gates, `PackageTraitGateAuditTest`
    must move with any trait change.

## Semantic Kernel orientation (where MK sits in the landscape)
MK's inference+tooling **core** is ~60–70% the standard kernel shape SK/LangChain share
(backends ≈ connectors, `ToolRegistry` ≈ plugins, the tool loop ≈ auto-invocation, RAG ≈
memory, both speak MCP) — so the kernel shape is **table stakes, not the moat**. MK diverges
as an **on-device-first Swift chat *runtime* with batteries SK omits** (persistence + SwiftUI
UI), organised around one normalizing event stream + one turn loop. The two capabilities SK
has and MK lacks — **formal multi-agent orchestration** and a **stateful/resumable process
engine** — are exactly the agentic frontier this target now **commits to**, built MK-shaped
on the TurnDriver seam + `Run` model rather than as SK-style separate frameworks.

## Explicitly out of scope here
The sequenced migration (leaf evictions → engine carve + driver seam → modality generify →
trait→product → usability fixes → run/checkpoint persistence), PR scoping, and issue
creation. That is the next document, written against this target.
