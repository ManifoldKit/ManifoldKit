# Architecture improvement plan — 2026-07

Scope: the ManifoldKit family. **Part I** covers core; **Part II** covers the companions
(manifold-llama, manifold-mlx, manifold-eval) — both the verified ripple of Part I's changes on
them and their own improvement backlogs. Goal: the next wave of architectural improvements for
technical quality, reliability, extensibility, maintainability, and understandability —
prioritised, PR-sized, and grounded in current code on each repo's `main`, not stale phase labels.

Grounding: a four-agent read-only survey of core (2026-07-05) — module/dependency graph,
turn-loop + engine core, backend-extensibility surface, runtime ports / persistence / UI — plus
a second three-agent survey of the companion repos' `origin/main`, plus reconciliation against
the executed `target-architecture-migration.md` and `cross-repo-simplification-2026-07.md`
(the latter is now fully executed through Wave D). Load-bearing claims were spot-verified by
hand before inclusion (core refs as of 71f026e0; llama d88dfdc, mlx 5ad93e5, eval fd7afb7).

---

# Part I — ManifoldKit core

## Where the architecture actually stands

The June target-architecture migration is **essentially executed**: P0 (decisions + P0c
characterization harness, now 9 golden tests), P1 (leaf extractions), P2 (Contract kernel carve
#1719/#1723, executor de-tangle #1724/#1757), P2.5b (`BackendName` is already the open
`RawRepresentable` struct), P3 (TurnDriver seam + resumable-run persistence #1744/#1795),
P4 (MediaGeneration generify), the #1593 streaming-parser unification, and P7 (shim retirement
#1837). The v0.48 trait retirement went further than the plan's P5. The six inert-code fix waves
(#2120–#2125) landed 2026-07-03.

What this plan is **not**: a re-litigation of any of that. It is (a) the residue the executed
plan left behind, (b) defects and structural debt the survey found that no existing plan covers,
and (c) a consolidated decision queue for items already written down elsewhere
(`inert-code-audit-2026-07.md`, `tool-calling-architecture.md` #2038, #1957).

## Healthy — verified, leave alone

Named explicitly so future sessions don't re-derive or "improve" them:

- **The ports layer** (`MessageStore`/`SessionStore`/`RunStore`/`EndpointStore`/…): value-type
  traffic only, no `@Model`/`PersistentIdentifier` leakage, documented narrow-write methods.
  A genuinely well-executed ports/adapters boundary.
- **The single-turn-loop invariant.** Every UI verb routes through
  `ConversationRuntime.processTurn*`; `ChatGenerationCoordinator` is a pure event reducer, not
  a second turn loop. `ConversationRuntime` itself (thin, actor-delegated state) is the target
  shape for the executor's internals.
- **Cancellation propagation** on the live path (registry → task cancel → queue → backend) is
  careful and race-conscious, with explicit reasoning at the tricky spots.
- **`InferenceBackend` is cohesive** — ~10 requirements, 3 defaulted; embeddings and tracing
  live outside the protocol. The 710-line file is mostly `GenerationConfig` sampler docs.
- **The `CloudMessageEncoder`/`CloudHTTPProviderAdapter`/`FramedTransport` spine** is a real
  shared abstraction with thin typed provider adapters — not copy-paste.
- **`GenerationEvent` freeze discipline**: growth channels through struct payloads; the
  closed-switch audit test is a working tripwire (invariant 6 holds).
- **Contract kernel isolation** is double-defended (manifest scan + runtime type-location pin).
- **Additive schema migration mechanics** (V3→V12, all lightweight, each justified inline,
  read-back tested).
- **Trait discipline** post-v0.48; `PackageTraitGateAuditTest` is manifest-driven and
  self-improving.
- **Turn-loop regression cover**: 9 characterization goldens + mutation baseline +
  `TurnDriverDispatchTests` — the safety net that makes Priority 3 below tractable.

---

## Priority 1 — Reliability fixes on the live turn path

Highest ratio of user-visible reliability to effort in the whole survey. Two PRs.

### 1.1 Close the cross-session tool/handoff/hook wiring race  (fix size M)

`ConversationTurnExecutor` wires per-turn behavior by mutating **ambient shared state** on the
shared service: `setHandoffDetector` (`ConversationTurnExecutor.swift:588-598`) and
`setPreToolUseHook` (`:615-617`), with further `await` suspension points before the actual
enqueue (`:718-730`). Two concurrent sessions on one `InferenceService` are last-writer-wins —
`SessionToolDispatchBinder.swift:25-28` documents exactly this. The fix already exists in the
API and is unused: `enqueueAsync` accepts per-request `handoffDetector:`/`preToolUseHook:`
closures (`InferenceService+Nonisolated.swift:71-72`, threaded into `QueuedRequest`, added for
#1494) — the only production caller doesn't pass them.

- Thread the executor's closures through the enqueue call; delete the ambient set/clear pairs.
- The remaining shared-`ToolRegistry` register/unregister race has no per-request escape hatch;
  scope it in the same PR's description as a follow-up decision (session-scoped registry) rather
  than expanding this PR.
- Axes: reliability (multi-session correctness — the framework already advertises
  `requestGroupID`/multi-session support).

### 1.2 Stop dropping persistence failures from the cancel-path outcome  (fix size S)

The stream-failure branch surfaces a persistence error through the reliable completion
(`completeOutcome(..., error: persistenceError)`, `ConversationTurnExecutor.swift:1001-1010`);
the cancel branch swallows the identical failure — best-effort `emit(.errorRaised(...))` then
`completeOutcome(..., error: nil)` (`:1041-1061`). A caller of `processTurnWithOutcome` — whose
doc contract promises completion independent of event buffering — sees `reason: .cancelled,
error: nil` while a partial message was silently lost. The outcome carries both `reason` and
`error`; populate both. One golden test update expected.

### 1.3 Backend-capability fidelity: fix the drop, then make the class impossible  (fix size S+S)

`AnyLanguageModelBackend.loadModel` rebuilds `BackendCapabilities` by hand to override one field
and silently zeroes 7 of 25 (`supportsVision`, `supportsGuidedStructuredOutput`,
`supportsStrictSchema`, `toolDialect`, `maxAdvertisedToolCount`, `rendersFullPrompt`,
`sharesMLXProcessResources`) — `AnyLanguageModelBackend.swift:48-67`. Root cause is structural:
the 25-field struct has no copy-with helper, and `union(_:)`'s own doc comment
(`BackendCapabilities.swift:293-298`) admits it's already stale for the newer flags.

- Add `BackendCapabilities.updating(...)` copy-with; fix the two known-stale sites.
- Add a **field-completeness tripwire** using the `Mirror` technique the repo already uses in
  `BackendContractChecks.unprovenClaims`: a test that fails when a new stored field isn't
  handled by `union`/copy-with. This converts "remember to update N sites" into compiler/test
  truth — the same lesson as the API-quality memo (contracts in types/signals, not prose).

### 1.4 Defuse `runFastOrPrimary`  (fix size S)

`InferenceService.swift:964-971` calls `primary.generateEnforcingCapabilities(...)` directly,
bypassing `GenerationQueue`'s documented single-active-generation invariant — a live hazard for
stateful backends (llama.cpp KV cache) the moment it gains its first caller. It has **zero**
callers today. Route it through the queue; if that fights its stated purpose (fast-path subtask
routing), deprecate it now and fold removal into Priority 5.3.

---

## Priority 2 — Boundary rules become code, and one wrong edge dies

Cheap, mechanical, and directly serves the repo's own economics (violations caught at the local
gate instead of after a CI round-trip). One or two PRs.

### 2.1 Port the prose/YAML boundary rules to audit tests  (fix size S)

Four architecture rules exist only as inline greps in `ci.yml:438-503` (UI ↛ UIModelManagement;
Runtime ↛ SwiftData/SwiftUI; Runtime ↛ URLSession/Keychain; UI ↛ PersistenceSwiftData) —
invisible to `scripts/test.sh --profile local`. Two more exist **nowhere**:

- "UI never imports a backend family" — the most-stated rule in CLAUDE.md, zero enforcement
  (holds today by luck/discipline).
- "`ManifoldCloudCore`'s only `ManifoldRuntime` import is `DefaultWebSearchRuntime`" — a
  `Package.swift` comment (moot once 2.2 lands, but a one-line guard until then).

Port all of them into XCTest audits following the `TrafficBoundaryAuditTest` pattern (comment
-stripped source scan + paired sabotage-suite allowlist entries), and delete the YAML steps in
the same PR so there's one source of truth.

### 2.2 Move `WebSearchRuntime` down; drop the CloudCore→Runtime edge  (fix size S/M)

`ManifoldCloudCore → ManifoldRuntime` exists for exactly one file's conformance
(`DefaultWebSearchRuntime.swift` — verified the only Runtime import in the target). The port
itself is a bare `@MainActor` protocol referencing no Runtime type — unlike its
`ImageGenerationRuntime` siblings, which genuinely wrap `MessageStore`. Today every consumer of
`ManifoldOllama`/`ManifoldCloudSaaS` (manifold-tools, fuzz-chat, ManifoldServer, …) transitively
links the persistence-ports layer for nothing, and readers of the graph draw the wrong
conclusion ("cloud infra needs persistence").

- Relocate `WebSearchRuntime`/`WebSearchRuntimeError` to `ManifoldInference`; drop the dep edge.
- Verified no tripwire blocks the move (`ProtocolLocationAuditTest` doesn't pin it;
  `PackageTopologyAuditTest` pins only the concrete file's location).
- Module-hop is source-visible: run api-digester, allowlist, and add a migration note — MK has
  at least one live external consumer of the shim story.
- Acceptance: `ManifoldOllama`/`ManifoldCloudSaaS` build without `ManifoldRuntime` in their
  transitive closure; the 2.1 guard flips from "exactly one import" to "zero imports".

---

## Priority 3 — The one real refactor: `ConversationTurnExecutor`, round two

The north-star doc named this file the instability epicenter; the P2c de-tangle moved strategy
*selection* up into `ConversationRuntime` but not the *content* of a turn. Today both `TurnDriver`
conformers funnel 100% of real work into the same 1,501-line executor whose `runGenerationTurn`
is a ~730-line linear function (`:471-1199`), and the type is constructed **only** inside
`ConversationRuntime` — no behavior in the file is unit-testable without the full
runtime + service + backend stack. That test cost is exactly why Priority-1-class asymmetries
(1.2) survive review: the three finalization branches (stream-failed / cancelled / happy-path,
`:982-1132`) each hand-roll persist→emit→completeOutcome slightly differently.

**The surgical split (not a rewrite):** along the function's own existing comment boundaries —

1. **`TurnPreparation`** — history fetch/heal/shape → RAG → system-prompt composition → tool
   advertise/register (`:471-744`). In: `TurnInput` + stores. Out: a small immutable
   "prepared turn" struct (messages, composed prompt, advertised tools, registered names).
2. **`TurnStreamFinalizer`** — stream-drain state machine + a **single** finalization path
   parameterized by reason, replacing the three divergent branches (`:758-1198`). This makes
   1.2's bug class structurally unrepresentable, not just fixed once.
3. The executor becomes glue: prepare → enqueue → finalize.

Constraints and gates:

- **Behavior-preserving, proven**: the 9 characterization goldens + mutation baseline are the
  oracle; land Priority 1.1/1.2 *first* so the goldens capture corrected behavior, then this
  refactor diffs clean against them.
- Each unit gets direct unit tests (the entire point); target `runGenerationTurn` ≤ ~200 lines.
- Do NOT touch the driver seam, the Inference/Runtime tool-dispatch split (coherent in
  principle; 1.1 fixes the wiring), or `GenerationToolDispatchLoop`'s deliberate
  unstructured-Task workaround.
- Fix size: **L** — adversarial persona review before dispatch, per the P2 precedent.
- Acceptance: a finalization edge case testable with a struct literal instead of a full
  `ConversationRuntime` + mock backend + in-memory store.

---

## Priority 4 — Extensibility hardening (one coordinated `feat!:` wave)

Batch the breaking pieces into a single pre-1.0 minor with allowlisted api-digester entries and
a companion-compat window, per the #2122/#2124 precedent.

### 4.1 Open the local-family escape valve: `ModelType`  (fix size M)

`ModelType` is a closed 3-case enum (`ModelType.swift:4-11`) keying `BackendFactory` — a new
*local* model family needs a core PR before it can register, while cloud already has
`APIProvider.custom`. `docs/COMPANION-BACKENDS.md` explicitly anticipates a third family.
Apply the exact `BackendName` P2.5b precedent (RawRepresentable struct, static well-known
constants, raw values unchanged so stored data decodes). Fan-out is real but contained
(`ModelStorageService`/`ModelCatalog`/download UI); companions consume via `@unknown
default`-safe patterns per the enum-growth memory.

### 4.2 Instance-scope the capability-claims registry  (fix size M + 3-repo coordination)

`BackendContractChecks.swift:100-101`'s process-global claims set is the single reason the whole
fleet — core **and** both companions — bans `swift test --parallel` on contract suites. The
registry's natural lifetime is one reset→claim→assert sequence in one test case. Instance-scope
it (owned per test case, threaded through the assert entry points). Breaking change to a
published product → coordinate via companion-compat + pin-bump window.
Acceptance: contract suites green under `swift test --parallel` in all three repos; the DocC
serial-run warnings deleted.

### 4.3 De-duplicate the SSE extractor plumbing  (fix size S)

Narrower than — and independent of — the #2038 ChatProfile proposal:

- Thinking-close boilerplate is byte-identical in 3 extractors
  (`ClaudeStreamEventExtractor.swift:542-546`, `OpenAIStreamEventExtractor.swift:183-187`,
  `OpenAIResponsesStreamEventExtractor.swift:219-223`) because `ThinkingBlockManager.flushIfOpen`
  has a continuation-shaped signature and consumers accumulate into arrays: add the array
  overload, delete 3 copies.
- Tool-call finalization near-identical across the two OpenAI-family extractors
  (`OpenAIStreamEventExtractor.swift:189-198` vs `OpenAIResponsesStreamEventExtractor.swift:225-241`):
  share via a default on `CloudStreamEventConsumer`.
- `OllamaStreamEventExtractor.swift:382-405` hand-rolls the thinking open/close state machine as
  a raw bool despite importing the module whose type exists to centralize it.

### 4.4 Split `ManifoldTestSupport`'s persistence-touching mocks  (fix size M)

`ManifoldTestSupport` unconditionally depends on `ManifoldRuntime` + `ManifoldPersistenceSwiftData`
(`Package.swift:542-557`) though only 3 of 41 files need them — so the "zero-dependency" leaf
test suites (Hardware/Secrets/Networking) and **both companion repos** link the whole
persistence stack to get one mock. Split the 3 files into `ManifoldPersistenceTestSupport`
(mirrors the precedented TestSupport/ContractTestSupport split). Breaking for companions —
same wave as 4.2.

---

## Priority 5 — Composition-root & public-surface finish line

The residue of the executed migration plan's P6 plus survey findings. Mostly S items; batch.

- **5.1 `ManifoldBootstrap` store construction extracted to one factory** (S). The
  sync-`init`/async-`build()` paths duplicate the six-store construction block verbatim
  (`ManifoldBootstrap.swift:325-333` vs `:626-632`) — the exact divergence class that already
  shipped one bug (the file's own `makeConversationRuntime` comment narrates it). Extract
  `makeStores(modelContext:)` alongside the existing shared factories.
- **5.2 Injectable persistence pair in `ManifoldBootstrap`** (M). The composition root
  hard-forecloses custom `MessageStore`/`SessionStore` (`:143-147` says "construct the view
  models yourself") even though the ports are swap-ready. Accept an optional persistence
  provider; default to SwiftData. This finishes the ports story the architecture already paid for.
- **5.3 Deprecated-surface removal sweep** (M, breaking — ride the Priority 4 wave). The 4
  deprecated enqueue/generate overloads exist **twice** (mirrored `GenerationQueue.swift:330-437,
  944-1044` ↔ `InferenceService.swift:543-692`), plus the Phase-7 list from the migration doc
  (`TurnUsageRecord`, `MCPOAuthTokenStore.accessToken`, `Quantization.load(from:)`, …). Also
  delete the never-assigned `activeGenerationToken` (`ChatViewModel.swift:626-629`,
  `ChatGenerationCoordinator.swift:123`) — verified vestigial, and 2 of the 7 remaining concrete
  `InferenceService` declarations in UI.
- **5.4 Narrow the UI→engine coupling with a lifecycle port** (M). Current gate: ~5 live
  declarations + 19 call sites, all backend/model-lifecycle (`isModelLoaded`, `capabilities`,
  `stopGeneration`, `secureWipe`, …) — none turn-execution. Introduce a ~11-member
  `BackendLifecyclePort` protocol that `InferenceService` already satisfies; do **not** build a
  general `InferenceServiceProtocol` (it would re-couple UI to the execution API under a new
  name). This supersedes the P0a "accept concrete" decision only at this narrow surface.
- **5.5 P6c finish: `configure*` and quickStart policy** (M). 10 `configure*` overloads now
  (the plan wanted the 9 reduced). `QuickStart.swift` (710 lines) carries real selection policy
  (`:560-647`) locked inside the umbrella's static funcs — extract the policy down to where
  `ModelRegistry`/`ManifoldBootstrap` live so direct-bootstrap hosts get it, keep the umbrella
  thin, and document the fallback chain. Exercised by cold-start tiers + DX walkthrough.
- **5.6 Post-write hooks: first consumer or honest labeling** (S). Both hook mechanisms have
  complete plumbing, thorough tests, zero production registrations
  (`MessageStore.swift:89,176`, `SessionStore.swift:151,236`). Either wire the obvious first
  consumer (RAG re-index-on-write) or mark both as host-only extension points — the
  `SessionStore` variant admits this, the `MessageStore` one doesn't.

---

## Decision queue (needs Rory — blocks the items noted)

1. **Inert-code decision list** (`inert-code-audit-2026-07.md`): 13 wire-or-cut surfaces + 21
   seams. One sit-down; unblocks a batch of S-sized honesty PRs (including 5.6).
2. **Resumable runs: adopt or annotate.** Built, wired, tested, live-inert — `enableResumableRuns:
   true` appears only in one test (`ManifoldBootstrap.swift:301`; #1957 Tier 4). Recommendation:
   flip it on in the Advanced example app (the cheapest real consumer) or explicitly document
   "built, dormant, opt-in" and stop carrying it as implicitly live.
3. **`TurnDriver` visibility honesty.** The seam is `package`-scoped with one real behavior
   (`ResumableRunDriver.executeTurn` is a passthrough, `ResumableRunDriver.swift:255-267`) while
   its docs say "EDGE by design". Either widen to `public` with a documented conformance story,
   or fix the docs. Recommendation: fix the docs now; widen on first adopter demand.
4. **#2038 ChatProfile / tool-calling consolidation**: schedule or keep parked. Preconditions
   unchanged (matrix re-measure on current main). Priority 4.3 deliberately skims only the
   provider-plumbing duplication so it stays independent of this call. **This is now a
   three-repo decision** — the manifold-mlx render-path fork (Part II, X1) is the strongest new
   evidence for scheduling it: MLX ships three different tool-injection shapes for the same
   `GenerationConfig.tools` input, all on a second render stack.
5. **`ChatSession`/`ChatMessage` façade vs schema-tracking** (migration plan's open P6 decision;
   typealiases still pin `ManifoldSchemaV9`). Must resolve before any 1.0 freeze talk.
6. **Destructive-migration rehearsal.** All 9 shipped migration stages are lightweight/additive;
   the flagged P4b `MessagePart` collapse would be the first custom stage ever. Decide whether to
   rehearse one (in-process seed → custom stage → read-back, nightly tier) before it's on the
   critical path.
7. **`GenerationEvent` freeze wording** (S): the doc-comment says "frozen as of the 1.0 release"
   on a 0.65 package. Make the commitment precise (frozen-since-tag, or "will freeze at 1.0").

## Sequencing

```
P1 reliability (2 PRs) ──► P3 executor round-two (goldens re-baselined first)
P2 boundary tests + edge fix (1-2 PRs) ── independent, start immediately
P4 feat!: wave (4.1-4.4 + 5.3) ── one coordinated breaking minor + companion window
P5 remainder (5.1, 5.2, 5.4, 5.5, 5.6) ── independent S/M items; batch 2-3 per PR
Decision queue ── schedule the sit-down early; items 1-3 gate several S PRs
```

Standard gates apply throughout: full `--profile local` before push, draft-PR review loop for
everything here (all items are non-trivial), api-digester + allowlist for the breaking wave,
trait-combo sweep where switched enums change. No new tracking issues — this doc plus the
existing umbrellas (#1957, #2005-successor decisions) carry the checklist.

## Explicitly out of scope (Part I)

- Re-splitting or renaming module targets (the 33-target factoring was judged intentional by
  two independent surveys; `ManifoldEngine` stays dead).
- Unifying the three UI observability idioms (each is locally justified; unification is churn
  without a driver — noted for awareness only).
- Multi-agent / plan-execute drivers (deferred on adopter demand, unchanged).

---

# Part II — Companion repos

Survey briefs handed each scout the Part I items with instructions to verify ripple at
grep-level, then assess the repo on its own terms. Pins at survey time: llama and mlx build
against core 0.65.0; eval pins `exact: "0.65.0"` — bumped **fully automatically** by the org
`repository_dispatch` → core-bump → automerge pipeline (run 28685069531 merged eval PR #18 with
no human step). Three of the survey's premises from prior session memory turned out stale and
are corrected here: Wave D is fully merged (llama #130/#132, mlx #128/#131 — no vendored
residue in either repo), the eval pin automation works end-to-end, and the MLX tool-call
normalizers are live in the hot generation path, not inert.

## II.1 Ripple of Part I on the companions — verdict: cheap by design

The Contract kernel + registrar seams did exactly what they were built for: the expensive-looking
core wave is almost free downstream. Verified per item:

| Part I item | manifold-llama | manifold-mlx | manifold-eval |
|---|---|---|---|
| 1.1/1.2/1.4, 2.2, P3 (turn path, `WebSearchRuntime`, executor split) | zero references; `ManifoldRuntime`/`PersistenceSwiftData` confirmed test-target-only | zero references; same confirmation | n/a — no runtime consumer |
| 1.3 `BackendCapabilities` | 3 fresh-literal sites, no copy/`union` use | 3 fresh-literal sites, no copy/`union` use | zero hits |
| 4.1 `ModelType` → struct | 1 switch, already has `default:`; ~zero adaptation | 1 switch, already has `default:`; non-event | zero hits |
| 4.2 claims registry | 1 collapsed test method to rewrite; constraint encoded in CLAUDE.md + 2 workflows | same shape, <1 file | zero exposure |
| 4.4 TestSupport split | 29 importing files, **zero** persistence-piece usage — safe | 20 importing files, one `MockInferenceBackend` use — safe | zero imports |
| 5.3 deprecated sweep | 2 live `service.enqueue(` sites (CLI + E2E test) | 1 DocC prose mention | 2 `enqueue(` sites + the trapping `OllamaBackend(urlSession:)` in BFCL (E1) |
| `GenerationEvent` freeze | 12 switches, all `default:`-guarded | 2 prod switches, `default:`-guarded | 2 `if case` bindings only |

Three consequences flow back into Part I:

- **4.2's honest payoff is core-side test quality, not companion CI wall-clock.** Verified:
  llama's PR lane runs 2–4 min model-less (the live-claims lane is nightly-only); mlx is a
  single-job suite. The win is deleting a fleet-wide constraint that forces claims into one
  collapsed test method per repo (#1601 shape) and forbids `--parallel` everywhere. Keep the
  change; state the motivation accurately.
- **1.3's tripwire should note the downstream literal sites.** All six companion
  `BackendCapabilities` sites are fresh full literals — when core adds a field *with a default*,
  they compile unchanged and silently adopt it. That's acceptable (defaults must be
  conservative-false per the capability meta-contract), but the copy-with PR should say so, and
  new fields with non-obvious defaults warrant a companion heads-up in the release notes.
- **5.3's removal list has 4 known downstream call sites** (2 llama + 2 eval `enqueue`) — the
  removal release will leave companion core-bump PRs red until each lands a one-file migration;
  stage those as drafts per the Wave-D precedent (below).

## II.2 Breaking-wave coordination runbook (Part I Priority 4 + 5.3)

The machinery for this already exists and is proven; the runbook is mostly "use it in order":

1. **Pre-tag compat check**: dispatch core's `companion-compat.yml` (workflow_dispatch,
   builds each companion against an arbitrary `core_ref`) against the wave branch **before**
   merging the release — compile breaks surface here, not post-tag.
2. **Stage companion adapt PRs as drafts** pinned to the future core version (claims-registry
   adoption in llama/mlx; `enqueue` migration in llama; nothing needed in eval yet). This is
   the D1 pattern from the executed cross-repo plan.
3. Merge the core wave; cut the release. The core-bump fanout auto-opens pin PRs; each is
   gated on `swift build --build-tests && swift test` **before** merge — a breaking release
   leaves the pin PR open and red (loud), never silently merged. Ready the staged adapt PRs;
   merge pin + adapt together per repo.
4. **eval last**: its exact-pin bump PR runs the same gate; land its `enqueue` migration with
   the bump. `ConformanceRecord` is untouched by this wave (see X3) so nothing else moves.

## II.3 manifold-llama — own improvements

Assessment: the healthiest repo of the three. `LlamaBackendProcessLifecycle` (the process-global
init latch), the deinit retain/detach/release teardown, `docs/LLAMA_CONTRACT.md` (853 lines of
living C-API/upgrade/CVE documentation), and the slim self-hosted xcframework repackage
(769 MB → 30 MB) are all reference-quality — core's own CLAUDE.md already cites two of them.
Tool-call dialect handling reuses core's `ToolCallDialect`/`ToolCallTransform` directly (the
expected duplicated taxonomy does **not** exist).

| # | Item | Evidence | Size |
|---|------|----------|------|
| L1 | Fix the self-contradicting CLAUDE.md: the targets table still says scenario JSONs/fixtures are "vendored… planned migration" while the same file's Vendored-data section correctly describes the post-#130 state | `CLAUDE.md:13` vs `:30-32` | S |
| L2 | Port core's `SilentCatchAuditTest` pattern: 9 production `try?` sites are currently all legitimate trust-boundary decodes, but nothing enforces that boundary | `LlamaModelLoader.swift` ×3, `LlamaToolMarkers.swift` ×6 | S |
| L3 | Drop 2 unused test-target imports of `ManifoldRuntime`/`ManifoldPersistenceSwiftData` (no symbol from either is used) | `Tests/ManifoldLlamaTests/LlamaBackendTests.swift:3-4` | S |
| L4 | `LlamaGenerationDriver.run()` is a ~730-line flat hot loop (batch sizing, KV reuse, sampler chain, prefill, decode loop in one body) — the same shape as core's `runGenerationTurn`. Decompose **only with a perf gate**; deliberately flat code in a hot loop is a defensible trade, so this is opportunistic, not urgent | `LlamaGenerationDriver.swift:152-886` | M |
| L5 | The `main.swift` ↔ `ScenarioCorpusFixture` manual lockstep (SwiftPM can't `@testable import` an executable) — already self-documented in-repo; leave until it actually drifts | `Tests/…/ScenarioCorpusFixture.swift` | — |

## II.4 manifold-mlx — own improvements

Assessment: sound engineering wrapped around two structural risks — the render fork (X1) and
the vendored diffusion trees. The normalizer chain
(`mistralNormalizer.process(llamaNormalizer.process(…))` in the hot loop) is live and correctly
placed; the metallib staging and xcodebuild env-injection workarounds are well-documented
solutions to real problems.

| # | Item | Evidence | Size |
|---|------|----------|------|
| M1 | Mistral tool-call repair: the 494-line normalizer is wired into the hot path and unit-green (9 tests) but a June live re-soak proved it **live-ineffective** on real 4-bit emissions (F1=0 — the conservative parser correctly declines interleaved-prose / mismatched-bracket / bare-JSON manglings; tracked mlx#106). Do NOT just widen unit fixtures — that shape was already proven insufficient. Harvest real captured manglings into the corpus *and* pursue #106's durable fix: decode-time grammar constraint of the `[TOOL_CALLS]` envelope (GBNF executor #96 exists; watch perf #100). Feeds X1/#2038 — grammar-first is exactly that plan's principle | `MLXMistralToolCallNormalizer.swift`; mlx#106 | M |
| M2 | Define a sync/drift policy for vendored `FluxSwift`/`StableDiffusion` — **47% of the repo's source** (≈7.0k of 14.7k lines), imported once, never re-synced, no tooling to surface upstream correctness/security fixes. Minimum viable: pin the imported upstream SHA in a comment + a quarterly diff-check script; the alternative (consume as packages) was presumably rejected for patch-carrying reasons — record which | `Sources/FluxSwift/` (~4.4k), `Sources/StableDiffusion/` (~2.6k) | M |
| M3 | Doc-truth sweep: README still calls module names "temporary pre-0.48"; `scripts/test-mlx-integration.sh` carries the same stale note; CLAUDE.md's pin note says 0.63 while Package.swift is at 0.65 | `README.md:7`, script header, CLAUDE.md | S |
| M4 | When core's 1.3 tripwire lands, update the 3 fresh-literal `BackendCapabilities` sites in the same PR as the pin bump (silent-default exposure noted in II.1) | `MLXBackend.swift:69`, `MLXGenerationDriver.swift:49`, contract test | S |

## II.5 manifold-eval — own improvements

Assessment: the strongest provenance discipline in the family (seeded `SamplerConfig` on every
run, `coreCommit` threaded through records, mixed-commit sets rejected rather than merged,
byte-stable JSON output, replayable diff/regress by construction) and genuine reuse discipline
(`ASTMatcher`/`MatrixRenderer` consumed from core's `ManifoldTools`, explicitly not
reimplemented). Its problems are small and specific:

| # | Item | Evidence | Size |
|---|------|----------|------|
| E1 | BFCL path uses the deprecated **trapping** `OllamaBackend(urlSession: nil)` while the IFEval path already uses the catchable `makeChecked` — the two files even carry parallel comments about the tradeoff and only one made the safe choice. Swap 2 call sites | `BFCLGenerateCommand.swift:108`, `BFCLGenerateLiveTests.swift:42` vs `IFEvalGenerateCommand.swift:137` | S |
| E2 | Extract a shared `OllamaBackendFactory` — the duplicated construct/configure/load boilerplate across the two generate commands is the root cause of E1's drift | `BFCLGenerateCommand.swift` / `IFEvalGenerateCommand.swift` | S |
| E3 | Doc-truth sweep: README's P5 row and `EVAL-IMPROVEMENT-LOOP.md` still say rot-guard is "deferred" (it shipped in #19, runs weekly); `core-bump.yml`'s header still claims the dispatch PAT is broken (run history disproves it). Align to `ORIGINS.md`'s accurate framing | `README.md:281`, `docs/EVAL-IMPROVEMENT-LOOP.md:116`, `core-bump.yml` header | S |
| E4 | Migrate the 2 `InferenceService.enqueue` call sites ahead of core's 5.3 removal (staged draft per II.2) | `IFEvalGenerateCommand.swift:227`, `IFEvalGenerateLiveTests.swift:76` | S |

## II.6 Cross-repo architectural items

- **X1 — Render-path convergence (the structural one; extends decision-queue item 4).**
  manifold-mlx renders through a genuinely separate stack (mlx-swift-lm →
  swift-transformers `applyChatTemplate`; zero references to core's `JinjaPromptRenderer`),
  and its tool injection is three-shaped: Qwen and Llama get hand-built prose blocks (Llama
  deliberately, to dodge the detokenizer's special-token drops), Mistral renders tools
  structurally through the real template. Every model-template quirk is currently fixed twice,
  in two codebases, in two idioms (`normalizeSystemMessages`/`foldSystemIntoFirstUser` exist
  only to patch crashes core's renderer wouldn't hit the same way). The decision — whether
  Mistral's structural path becomes the target shape for all MLX dialects as detokenizer
  coverage improves, or core's renderer absorbs MLX quirks — **is the concrete, evidence-backed
  form of the #2038 scheduling call** and should be made once, for three repos, after the
  matrix re-measure.
- **X2 — MLX eval leg.** manifold-eval has two drivers (Ollama in-process raw HTTP, llama.cpp
  subprocess) and **no MLX leg** — it cannot reproduce its own founding 3-way-divergence
  anecdote for a new case. Blocked on manifold-mlx growing a subprocess-able eval-runner CLI
  with the same fixed flag contract as `LlamaRunnerDriver` expects; then an `MLXRunnerDriver`
  in eval is mechanical. (Same item as the old attended-backlog "materialize manifold-mlx-eval";
  the subprocess boundary also respects the one-process Metal hazard eval's Package.swift
  documents.)
- **X3 — Treat `ConformanceRecord` as a cross-repo wire contract.** It is eval's widest core
  coupling (fields consumed: model/quant/backend/renderer/coreCommit/status/verdict/
  toolSelection.f1/toolingVersions). Nothing in this plan touches it — keep it that way: any
  future shape change ships with an eval-side migration PR in the same train, and a pinned
  decode fixture on the eval side would make drift loud. Cheap to add during E2's PR.
- **X4 — Propagate the cheap core tripwires.** llama lacks a `SilentCatchAuditTest` (L2);
  neither companion enforces doc-claims-vs-reality (the L1/M3/E3 staleness all rotted silently).
  Port the silent-catch audit where it fits; doc drift stays a batched manual sweep (a doc-lint
  gate is over-engineering at this repo count).
- **X5 — Release-notes discipline for capability fields.** From II.1: new `BackendCapabilities`
  fields with defaults are invisible to companions' literal construction sites. One line in the
  core release-notes template ("new capability field X, default Y — backends that support X
  must opt in") closes the gap without tooling.

## Explicitly out of scope (Part II)

- Merging companions back into core, or converting the vendored diffusion trees to package
  deps without first recording why they were vendored (M2 records the decision, not a reversal).
- An MLX in-process leg in eval (the one-process Metal/`llama_backend_init` hazard is
  documented in eval's Package.swift; subprocess boundary only — X2).
- Rewriting llama's hot generation loop for style points (L4 is gated on a perf harness).
- A doc-lint CI gate across companions (three repos is below the tooling threshold; X4).
