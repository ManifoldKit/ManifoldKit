# Plan — Target Architecture Migration

Sequenced path from today's structure to the end state in
[`target-architecture.md`](./target-architecture.md). This is a **planning artifact** —
decisions, sequencing, and test/CI prerequisites before code, so reviewers argue with the
plan, not the diff. It does not contain implementation.

## Status

- **Target:** `target-architecture.md` (signed off).
- **Strategy:** incremental, never big-bang. Every step is its own PR, passes the full
  `scripts/test.sh --profile local` gate, and keeps `@_exported import` shims on the old
  module names so downstream `import ManifoldInference` / `import ManifoldRuntime` never break
  mid-flight. Shims retire only in a final breaking release (Phase 7), after a ≥2-minor
  deprecation window with `@available(deprecated, renamed:)` annotations.
- **Unit-of-work rule:** CLAUDE.md prefers "fewer, larger units" and warns against PR storms.
  **This structural migration is the sanctioned exception** — it is ~12 PRs of *refactor*, not
  feature fan-out. Cap in-flight PRs to keep review tractable; do not let it run as a storm.
- **WWDC gate (keynote 2026-06-08):** **P0 and P1 are WWDC-independent — start now.** P0 is
  decisions + a bug fix; P1 is pure file-moves with zero behavior change. **P2–P4 sequencing
  is re-confirmed after the keynote**, since Apple's agent/tool/on-device-media announcements
  may reprioritize the driver seam (P3) and the media seam (P4).
- **Agentic scope (decided):** commit to **resumable runs only**. Multi-agent / plan-execute
  drivers are deferred until explicit adopter demand; the P3 seam keeps the door open but is
  built for `SingleTurnDriver` + `ResumableRunDriver` only.
- **Review:** the engine carve (P2) and driver seam (P3) get parallel persona plan review
  before dispatch. File-move phases do not.

## Critical-path overview

```
 [WWDC-independent — start now]        [re-confirm after 2026-06-08 keynote]
 P0 prerequisites ──► P1 thin kernel ─┊─► P2 engine carve ──► P3 driver + resumable Run
 (decisions+bug+P0c)   (leaf evictions)┊   (the real refactor)  (committed: resumable runs)
        │                              ┊                              │
        │                              ┊                              └─► multi-agent/plan-exec
        ▼                              ┊                                  = DEFERRED (seam only)
 P6 usability ── pull forward (WWDC-independent, high adopter value) ──┐
                                                                       │
 P4 modality generify ── parallelizable; re-confirm post-WWDC ─────────│
 P5 trait→product ── after products are independent ───────────────────┘
 P7 retire shims ── final breaking release, after deprecation window
```

**Ordering rationale:** leaves first (P1) shrink the kernel with zero cycle risk and de-risk
the hard carve. P2 is the only true refactor and is gated on the P0a decision **and the P0c
characterization harness**. P3 rides P2. P4 (modality) touches a disjoint file set, so it can
run in parallel. P5 (traits) needs satellites to already be independent products. P6
(usability) is structurally independent and high-value — **pull it forward**. P7 is last.

## Per-phase adopter impact

| Phase | Adopter-affecting? | Why |
|---|---|---|
| P0, P1, P2, P3a | **Transparent** | shims preserve imports; behavior preserved |
| P3b/c (run model) | **Additive** | new API + schema bump; no removals |
| P4b (`MessagePart` collapse) | **Breaking (data)** | SwiftData schema migration — ships a migration guide |
| P5 (trait→product) | **Breaking (build)** | consumers add a product dep instead of a trait — migration guide |
| P7 (retire shims) | **Breaking (source)** | old module names removed — the deprecation window ends here |

---

## Phase 0 — Prerequisites & de-risking (WWDC-independent; ship first)

- **P0a — Resolve the `InferenceService.GenerationRequestToken` coupling gate (DECISION).**
  Decision: accept *App-above-Engine* — UI may name the concrete `InferenceService`. Defer the
  protocol-token abstraction. *Test consequence:* cold-start **tier-1** drives `InferenceService`
  + `GenerationStream` directly, so keeping the token concrete leaves tier-1 unaffected; a later
  protocol-token change would touch tier-1's fake-backend driver.
- **P0b — Fix the `SessionToolSource.resolve` dead-dispatch bug (PR).** Wire a per-turn adapter
  registering session-source `resolve` into `ToolRegistry`, or make `SessionToolSource`
  advertising-only and route execution through `ToolExecutor`.
  - **Test & CI:** add a **`SessionToolSourceDispatchTest`** tripwire — an advertised session
    tool (`generate_image`) must actually reach `ToolExecutor`. The path has *zero production
    callers* today, exactly the shape that needs a guard against silent re-death.
- **P0c — Build the turn-loop characterization harness (PR). *Gates P2.*** Snapshot the
  `ConversationEvent` stream + final persisted records for `send`/`regenerate`/`edit`/`cancel`/
  `branch` against `MockInferenceBackend` (+ a scripted tool), via `ConversationEventRecorder`
  + the existing `swift-snapshot-testing` (`ManifoldSnapshotTests`). Record goldens on `main`
  **before P2**. This is the only thing that makes the P2/P3a "behavior-preserving" claims
  provable — today there is no turn-transcript golden (only the recorder's own tests, server
  wire-format goldens, and a hardware-gated load-serialization characterization).

---

## Phase 1 — Thin the kernel (leaf evictions)  ·  WWDC-independent

Goal: get `ManifoldInference` from ~25k toward the ~3.4k Contract by evicting the ~86%
non-contract mass. File-moves + dep edges + `@_exported` shims; no behavior change.

- **P1a — Extract `ManifoldNetworking`** (`Networking/` + CloudCore SSE/TLS/DNS infra).
- **P1b — Extract `ManifoldSecrets`** (`Security/` + `KeychainService`).
- **P1c — Move device-capability + GGUF readers adapter-side** (MLX/Llama consume them).
- **P1d — Move discovery / catalog / benchmark + image/video-gen records to their own products.**

- **Test & CI impact:** **Not "lowest risk" for tests.** The source-walking audit tests
  (`TrafficBoundaryAuditTest`, `SessionConstructionAuditTest`, `DNSRebindingCoverageAuditTest`,
  `ContractTestSupportSplitAuditTest`) assert on `Sources/<module>/` paths — moving files
  silently relocates what they police. **Each eviction PR updates its audit's walked-path root
  + the paired sabotage entry in the same PR.** New test targets: **`ManifoldNetworkingTests`,
  `ManifoldSecretsTests`.** The `foundation-only-build` ≤5 MB / no-MLX-symbol gate becomes
  *more* important (more leaf modules = more symbol-leak surface). *Risk: low (moves) but
  audit-aware. Gate: full local + trait-combo sweep.*

---

## Phase 2 — Engine carve (the one real refactor)  ·  re-confirm post-WWDC

Goal: create `ManifoldEngine` = today's `ManifoldRuntime` + orchestration evicted from the
kernel. Depends on **P0a** and **P0c**.

- **P2a — Create `ManifoldEngine`; move orchestration in** (`PromptAssembler`,
  `ContextWindowManager`, `GenerationQueue`, `ToolExecutor`, `GenerationToolDispatchLoop`,
  `TranscriptHealer`, streaming). `@_exported` shims on `ManifoldInference` + `ManifoldRuntime`.
- **P2b — De-tangle `ConversationTurnExecutor`.** Lift persistence-writes + event-emission
  behind narrow ports; reduce to a thin per-turn executor; reconcile the Inference/Runtime
  tool-dispatch split.

- **Test & CI impact (highest):** **New target `ManifoldEngineTests`** — the doc must name it
  *and* wire it into `scripts/test.sh`'s `PROFILE_CI/LOCAL_XCTEST_FILTERS` arrays and
  `ci.yml`'s `--filter` chain, or the suite never runs in the gate. **Duplicate the
  `ManifoldRuntime` framework-isolation CI lints** (no SwiftData/SwiftUI/URLSession/Keychain)
  for `Sources/ManifoldEngine/`, or the invariant evaporates. Preserve the XCTest vs
  Swift-Testing split (#681) and the TestSupport/ContractTestSupport split (#1409) when
  re-homing suites. **Any new contract suite with a process-global claims registry must follow
  the `BackendContractChecks` no-`--parallel` rule** (`scripts/test.sh` lines 297–356).
  **P2/P3a prove behavior-preservation by diffing against the P0c goldens.** *Risk: HIGH —
  persona-reviewed; flake-sensitive turn path (KV-cache re-read-after-async-write discipline).
  Likely 2 PRs.*

---

## Phase 3 — Turn-Driver seam + resumable Run model  ·  re-confirm post-WWDC

Goal: ship the committed resumable-runs capability. Depends on **P2**.

- **P3a — Introduce `TurnDriver` protocol; extract current behavior into `SingleTurnDriver`**
  (behavior-preserving — must diff clean against the P0c goldens). No new behavior.
- **P3b — Introduce `ConversationRun`/`RunStep` + `RunStore` port + a run-level event type**
  (separate from `GenerationEvent` — invariant #6) + `ResumableRunDriver`. Persistence adds a
  `RunStore` impl + schema bump.
- *Deferred (not built now):* `MultiAgentDriver`, `PlanExecuteDriver`, agent stack/tree state.
  The seam guarantees they can land as EDGE conformers if an adopter needs them.

- **Test & CI impact:** the test triad for P3b —
  1. **`RunStore` contract conformance** (mirror the existing store-port contracts).
  2. **Schema-migration fixture** (mirror `SchemaV3MigrationTests`: in-process seed of old
     version, re-open under new plan, OOD-nonce falsification). *Runs in the nightly Operational
     tier (`RUN_OPERATIONAL_TESTS=1`) — so a migration regression has up-to-24h detection
     latency, not per-PR.*
  3. **`GenerationEventClosedAuditTest`** tripwire enforcing invariant #6 (no run/media payload
     appears as a `GenerationEvent` case), **with a paired sabotage entry** (QA-PRACTICES §3).
  - Resumable pause/resume/checkpoint is non-deterministic to test — **inject clock + IDs** so
    the fixtures don't flake. *Risk: med (P3a behavior-preserving is the careful one; P3b is
    additive). Gate: full local + nightly operational for the migration fixture.*

---

## Phase 4 — Modality generify  ·  parallelizable; re-confirm post-WWDC

Goal: replace per-modality vertical clones with one generic seam. Disjoint file set, so it can
run in parallel with P2/P3 on a separate branch.

- **P4a — Introduce generic `MediaGeneration<Output>` (+ service/runtime) over
  `GeneratedMediaPayload`**, with a shared media event type (one-shot + streaming/duplex for
  realtime audio). **Ship concrete typealiases** (`ImageGeneration`, `VideoGeneration`,
  `AudioGeneration`) so adopters rarely write the generic.
- **P4b — Collapse `MessagePart.generatedImage`/`generatedVideo` → single
  `MessagePart.generatedMedia(GeneratedMediaPayload)`** (one Codable key, one UI render branch).
- **P4c — Migrate Image + Video impls onto the generic seam; delete the clones.**

- **Test & CI impact:** P4b is **SwiftData schema migration #2** — needs a `MessagePart`
  migration fixture (prior art: `MessagePartTests`, `SchemaMigrationReadBackTests`). The generic
  seam **extends the contract-conformance pattern** to media backends. Watch the
  `GenerationEvent` exhaustive-switch blast radius (~14+ consumers) — the media event type must
  stay off the text path. **Acceptance metric: a new modality lands in ≤3 EDGE files.**
  *Risk: med. Gate: full local + trait-combo sweep (MLX-gated diffusion bodies).*

---

## Phase 5 — Trait → product conversion

- **P5a — Retire the clean traits** (`MCP`, `Voice`, `Tools`, `AppIntents`) → product opt-ins.
- **P5b — Extract `Ollama` + `CloudSaaS` source into dedicated targets, then retire those
  traits** (blocked until the 36 + 53 in-body `#if` directives are carved out).

- **Test & CI impact (lockstep — naming the exact assertions):** dropping a trait without these
  edits **fails CI immediately** (intended tripwire, but expect it):
  - `PackageTraitGateAuditTest.expectedGates` — remove the `ManifoldMCP→MCP`,
    `ManifoldVoice→Voice`, `ManifoldTools→Tools`, `ManifoldAppIntents→AppIntents` entries.
  - `FeatureMatrixTests` — both directions (matrix↔manifest) + `pendingMapping`.
  - The `--traits` strings in `scripts/test.sh` (`PROFILE_LOCAL_TRAITS`) and the
    `build-modes.yml` matrix (the `ollama`/`saas` modes).
  - The three cold-start consumer manifests that pass `--traits`.
  - **CI-matrix delta:** retiring the four clean traits barely changes the switch-combo sweep
    (they had ~no `#if` bodies). The **real reduction is P5b** — extracting Ollama/CloudSaaS
    source means default builds stop carrying their 36+53 `#if` bodies, shrinking the
    all-traits sweep. Net per-PR billing ≈ flat; nightly all-traits sweep gets cheaper.
  *Do as a clean sweep, after satellites are independent products.*

---

## Phase 6 — Usability (moat investment — pull forward)  ·  WWDC-independent

Goal: make "easier to use" part of the moat. Structurally independent of P1–P5.

- **P6a — `quickStart()` brings a default inlet live**, per a defined **selection policy**:
  prefer Foundation Models if available → first registered local backend → a clearly-labeled
  empty state. Not just "a default inlet" — name the fallback chain so a fresh install is never
  a blank composer.
- **P6b — Honest one-import** (umbrella genuinely sufficient; fix examples/README that import
  `ManifoldUI` separately).
- **P6c — Reduce the 9 `configure*` overloads** to a coherent surface.

- **Test & CI impact:** directly exercised by **cold-start tiers 1/2/3** and the DX walkthrough
  (they exist to catch exactly this); `APIFreezeTests` pins the public surface, so `quickStart()`
  signature changes trip it intentionally. *Risk: low–med. Gate: full local + cold-start tiers.*

---

## Phase 7 — Retire back-compat shims (final breaking release)

Delete the `@_exported import` facades after the ≥2-minor deprecation window.
- **Precondition:** no `import ManifoldRuntime`/`ManifoldInference` old-name references remain
  in `Examples/`, README snippets (`readme-snippets.yml`), or the cold-start manifests; the
  shim-completeness gate (below) is green throughout.

---

## Cross-cutting gates (every PR)

- `scripts/test.sh --profile local` before push; `--profile ci` only when chasing a CI failure.
- **Shim-completeness cold-start tier (add before P2, delete at P7):** from a fresh consumer,
  import the *old* module names and touch one moved symbol per surface (`ConversationRuntime`,
  `GenerationQueue`, `PromptAssembler`, a `Networking` symbol, a `Secrets` symbol). The existing
  tiers only exercise the *new* names, so a missing `@_exported` re-export passes every current
  gate and breaks only in a downstream months later. This tier is the only proof the shim is
  complete.
- Trait-combo build sweep when a PR touches a switched enum or trait-gated source.
- `FeatureMatrix.swift` + cold-start gates + `PackageTraitGateAuditTest` move in lockstep with
  any trait/module change.
- Never stage `Package.resolved` regenerations.
- Docs move with each phase (CLAUDE.md: "tests and docs ship in the feature PR"). Renaming
  `ManifoldRuntime`→`ManifoldEngine` invalidates README's architecture diagram + Key Types
  table, CLAUDE.md's Targets table, both QUICKSTARTs, and DocC articles — budget that churn in
  the relevant phase PR, don't leave published docs describing dead modules.

## New test targets & audit tripwires (consolidated)

- **New test targets:** `ManifoldNetworkingTests`, `ManifoldSecretsTests` (P1);
  `ManifoldEngineTests` (P2) — wire into `scripts/test.sh` filters + `ci.yml`.
- **New audit tripwires:** `SessionToolSourceDispatchTest` (P0b); `GenerationEventClosedAuditTest`
  for invariant #6 + sabotage entry (P3); an engine framework-isolation lint for `ManifoldEngine`
  (P2); ideally a `DriverAdditiveAuditTest` asserting `TurnDriver` conformers live outside the
  orchestration-core file set (invariant #7).

## Acceptance metrics (per phase — falsifiable "the seam works")
- **P4:** adding a new modality = ≤3 EDGE files (vs ~14 across 5 modules today).
- **`APIProvider` work:** adding a cloud provider = register 1 descriptor, 0 switch edits
  (vs ~14 today).
- **P1:** `ManifoldInference` drops from ~25k to ≈ the ~3.4k Contract.
- **P3:** adding a driver = conform `TurnDriver`, 0 engine-core edits.

## Sequencing summary (recommended order)
1. **P0** (P0a decision, P0b bug, **P0c characterization harness**) — now, WWDC-independent.
2. **P6** usability — pull forward (high adopter value, WWDC-independent).
3. **P1** thin kernel — now, WWDC-independent; de-risks everything downstream.
4. **— WWDC keynote 2026-06-08: re-confirm the rest —**
5. **P2** engine carve — gated on P0a + P0c; persona review.
6. **P3** driver + resumable Run model — rides P2.
7. **P4** modality generify — parallel to P2/P3.
8. **P5** trait→product — after satellites are products.
9. **P7** retire shims — final breaking release, after the deprecation window.
- *Deferred (not scheduled): multi-agent / plan-execute drivers — built only on adopter demand,
  as EDGE conformers on the P3 seam.*

## Out of scope here
Per-PR issue creation. When signed off, open a single umbrella tracking issue with the phase
checklist (CLAUDE.md issue-hygiene), not one issue per sub-item.
