# Plan — Target Architecture Migration

Sequenced path from today's structure to the end state in
[`target-architecture.md`](./target-architecture.md). This is a **planning artifact** —
decisions and sequencing before code, so reviewers argue with the plan, not the diff. It does
not contain implementation.

## Status

- **Target:** `target-architecture.md` (signed off).
- **Strategy:** incremental, never big-bang. Every step is its own PR, passes the full
  `scripts/test.sh --profile local` gate, and keeps `@_exported import` shims on the old
  module names so downstream `import ManifoldInference` / `import ManifoldRuntime` never break
  mid-flight. Shims retire only in a final breaking release (Phase 7).
- **Unit-of-work rule:** "fewer, larger units" (CLAUDE.md). Each phase below is one PR unless
  noted; sub-items bundle into that PR.
- **Review:** the engine carve (Phase 2) and driver seam (Phase 3) get parallel persona plan
  review before dispatch (`feedback_plan_review_personas`). File-move phases do not.

## Critical-path overview

```
 P0 prerequisites ──► P1 thin kernel ──► P2 engine carve ──► P3 driver + run model
 (decision + bug)     (leaf evictions)   (the real refactor)  (agentic enabler)
        │                                                            │
        │                                                            ├─► P3+ drivers (FEATURE work, post-migration)
        ▼
 P6 usability  ── can be pulled forward (independent of structure) ──┐
                                                                     │
 P4 modality generify ── parallelizable with P2/P3 (different files) │
 P5 trait→product ── after products are independent ─────────────────┘
 P7 retire shims ── final breaking release, after downstreams migrate
```

**Ordering rationale:** leaves first (P1) shrink the kernel with zero cycle risk and de-risk
the hard carve. P2 is the only true refactor and is gated on the P0 coupling decision. P3
rides P2. P4 (modality) touches a disjoint file set, so it can run in parallel. P5 (traits)
needs satellites to already be independent products. P6 (usability) is structurally
independent and high-value — **pull it forward** if it helps adopters sooner. P7 is last.

---

## Phase 0 — Prerequisites & de-risking (small, independent, ship first)

Goal: remove the two blockers that make later phases risky, before touching module structure.

- **P0a — Resolve the `InferenceService.GenerationRequestToken` coupling gate (DECISION).**
  UI binds the concrete `InferenceService` at ~9 declaration + 22 call sites; the nested token
  type is the tightest knot. **Recommended decision:** accept *App-layer-sits-above-Engine* —
  UI may name the concrete `InferenceService` because AppKit depends on Engine anyway. Defer
  the protocol-token abstraction to a later polish PR. Record the decision here; it unblocks P2
  without forcing a UI rewrite.
- **P0b — Fix the `SessionToolSource.resolve` dead-dispatch bug (PR).** `generate_image` /
  `generate_video` / `web_search` are advertised to the model but unreachable (no
  `SessionToolSource → ToolExecutor` adapter; zero production callers of `resolve`). Either add
  a per-turn adapter that registers session-source `resolve` into `ToolRegistry`, or make
  `SessionToolSource` advertising-only by design and route execution through `ToolExecutor`.
  Independent of all structural work; ship immediately. *Risk: low. Gate: full local.*

---

## Phase 1 — Thin the kernel (leaf evictions)

Goal: get `ManifoldInference` from ~25k to ~the ~3.4k Contract by evicting the ~86%
non-contract mass to leaf modules/adapters. Pure file-moves + dep edges + `@_exported` shims;
no behavior change. Lowest-risk structural phase.

- **P1a — Extract `ManifoldNet`** (`Networking/` + `ManifoldCloudCore`'s SSE/TLS/DNS infra).
- **P1b — Extract `ManifoldSecrets`** (`Security/` + `KeychainService`).
- **P1c — Move device-capability + GGUF readers adapter-side** (only MLX/Llama consume them).
- **P1d — Move model discovery / catalog / benchmark + image/video-gen records to their own
  products** (out of the kernel).

Each as its own PR. After P1, `ManifoldInference` ≈ the thin Contract (protocols + value types
+ records + `BackendRegistrar`). *Risk: low (moves). Gate: full local + trait-combo sweep
because moves touch trait-gated files.*

---

## Phase 2 — Engine carve (the one real refactor)

Goal: create `ManifoldEngine` = today's `ManifoldRuntime` + the orchestration evicted from the
kernel, cut by *"is it orchestration."* Depends on **P0a**.

- **P2a — Create `ManifoldEngine`; move orchestration in.** Relocate `PromptAssembler`,
  `ContextWindowManager`, `GenerationQueue`, `ToolExecutor`, `GenerationToolDispatchLoop`,
  `TranscriptHealer`, streaming into `ManifoldEngine` alongside `ConversationRuntime`.
  `@_exported` shims on `ManifoldInference` + `ManifoldRuntime` keep downstream imports alive.
- **P2b — De-tangle `ConversationTurnExecutor`.** Lift persistence-writes and event-emission
  behind narrow ports (they co-change 7× / 5× today); reduce the 1,100–1,628 LOC monolith to a
  thin per-turn executor. Reconcile the Inference/Runtime tool-dispatch split so a future
  agent-as-tool can re-enter cleanly.

*Risk: HIGH — the only step that is a refactor, not a move. Persona plan review first. Gate:
full local + the KV-cache-race-class re-read-after-async-write discipline; this is the
flake-sensitive turn path.* Likely 2 PRs (P2a move, then P2b de-tangle) to keep diffs reviewable.

---

## Phase 3 — Turn-Driver seam + Run model (agentic enabler)

Goal: make the committed multi-agent + stateful/resumable direction *possible at the edge*.
Depends on **P2**.

- **P3a — Introduce `TurnDriver` protocol; extract current behavior into `SingleTurnDriver`**
  (behavior-preserving refactor — must produce byte-identical turns; verify against existing
  E2E). This is the seam; no new behavior yet.
- **P3b — Introduce `Run`/`RunStep` + `RunStore` port + a run-level event type** (separate from
  `GenerationEvent` — invariant #6). Persistence adds a `RunStore` impl + schema bump (next V).
- **P3c — Generalize agent state** from single `activeAgentID` to an agent stack/tree; lift
  handoff into the driver.

After P3 the seam exists and single-turn is the default. **The actual drivers** —
`MultiAgentDriver`, `PlanExecuteDriver`, `AutonomousRunDriver` — are **feature work that rides
this seam (post-migration initiatives), not part of the structural migration.** Each should be
EDGE: conform `TurnDriver`, no engine surgery. *Risk: med (P3a behavior-preserving is the
careful one; P3b/c are additive). Gate: full local.*

---

## Phase 4 — Modality generify (parallelizable)

Goal: replace per-modality vertical clones with one generic seam. Touches a disjoint file set
(media-gen), so it can run in parallel with P2/P3 on a separate branch.

- **P4a — Introduce generic `MediaGeneration<Output>` + `MediaGenerationService<Output>` +
  `MediaGenerationRuntime<Output>`** over a `GeneratedMediaPayload` protocol, with a shared
  media event type allowing both one-shot (`progress→completed`) and a streaming/duplex variant
  (for realtime audio).
- **P4b — Collapse `MessagePart.generatedImage`/`generatedVideo` → single
  `MessagePart.generatedMedia(GeneratedMediaPayload)`** (one Codable key, one UI render branch;
  schema migration).
- **P4c — Migrate Image + Video impls onto the generic seam; delete the clones.**

*Risk: med (P4b is a schema migration — fixture + migration test required). Gate: full local +
trait-combo sweep (MLX-gated diffusion bodies).*

---

## Phase 5 — Trait → product conversion

Goal: shrink ~17 traits to the ~8 with real binary/dependency weight; make optionality
product-selection where possible.

- **P5a — Retire the clean traits** (`MCP`, `Voice`, `Tools`, `AppIntents`) → product opt-ins.
  Zero/near-zero source `#if`; trait only gates test edges today. Update `FeatureMatrix.swift`,
  cold-start gates, and `PackageTraitGateAuditTest` in lockstep (or CI fails).
- **P5b — Extract `Ollama` + `CloudSaaS` source into dedicated targets, then retire those
  traits** (blocked until the 36 + 53 in-body `#if` directives are carved out).

Keep `MLX`, `Llama`, `HuggingFace`, `Macros`, `Server`, `AnyLanguageModel`, `FoundationOnly`,
`Fuzz`, and the WWDC stubs. *Risk: low mechanically but touches every manifest target — do as a
clean sweep, and only after satellites are independent products. Gate: full local + all-traits
build sweep.*

---

## Phase 6 — Usability fixes (independent — pull forward)

Goal: make "easier to use" part of the target, not an afterthought. Structurally independent of
P1–P5, so any of these can ship early.

- **P6a — `quickStart()` brings a default inlet live** (selects/loads a sensible default
  backend; cloud is not a silent off-by-default wall).
- **P6b — Honest one-import** (umbrella genuinely sufficient; fix examples/README that import
  `ManifoldUI` separately).
- **P6c — Reduce the 9 `configure*` overloads** on `ChatViewModel` to a coherent surface.

*Risk: low–med. Gate: full local + the cold-start human/tier gates (they exist to catch exactly
this).*

---

## Phase 7 — Retire back-compat shims (final breaking release)

After downstream consumers migrate to the new module names, delete the `@_exported import`
facades on `ManifoldInference`/`ManifoldRuntime`. Single breaking (`feat!`) release. *Do not
start until adopters have had a deprecation window.*

---

## Cross-cutting gates (every PR)

- `scripts/test.sh --profile local` before push; `--profile ci` only when chasing a CI failure.
- Trait-combo build sweep when a PR touches a switched enum or trait-gated source.
- `FeatureMatrix.swift` + cold-start gates + `PackageTraitGateAuditTest` move in lockstep with
  any trait/module change.
- Never stage `Package.resolved` regenerations; `@_exported` shims preserve every public import
  until Phase 7.

## Sequencing summary (recommended order)

1. **P0** (decision + bug) — now.
2. **P6** usability — pull forward where independent (high adopter value, low risk).
3. **P1** thin kernel — de-risks everything downstream.
4. **P2** engine carve — gated on P0a; persona review.
5. **P3** driver + run model — rides P2; unlocks the agentic frontier.
6. **P4** modality generify — parallel to P2/P3.
7. **P5** trait→product — after satellites are products.
8. **P3+** the actual drivers (multi-agent / plan-execute / autonomous) — feature initiatives
   on the seam, tracked separately.
9. **P7** retire shims — final breaking release.

## Out of scope here

Per-PR issue creation and GitHub tracking-issue setup. When this plan is signed off, open a
single umbrella tracking issue with the phase checklist (per CLAUDE.md issue-hygiene), not one
issue per sub-item.
