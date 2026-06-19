# Reusable Model-Selection Surfaces + Headless Load Path (+ Doc Uplift)

**Status:** Draft plan — pending review
**Date:** 2026-06-14
**Motivation:** Consumers keep re-implementing the model selector and re-deriving capability/recommendation logic that MK already owns, because the logic is reachable only by accepting MK's bundled views or by spinning up `ChatViewModel` as a loader. Option B chosen: extract the load path so selection can drive load headlessly, with documentation as a first-class deliverable.

---

## Evidence (why we're doing this)

Audited 8 local consumers. The model selector is the clearest re-implementation hotspot; chat and API config are already well-served.

- **Bundled `ModelManagementSheet` is wrong granularity.** It welds Select + Download + Storage into one sheet. Apps that want *just-select* rebuilt it: `fireside-night` (own grouped picker, foundation vs downloaded), `offgrid-ai` (quick-switch bottom sheet + settings detail). Apps that took the bundle did so for lack of a smaller option, not because they wanted three tabs.
- **Trapped recommendation/capability logic gets re-derived.** `fireside-night`'s `CuratedModel`/`ModelTier.classify` and `offgrid-ai`'s `CuratedModelCatalog`/`ModelCapabilityResolver` recompute device-fit and capability flags that MK already computes — but only inside `ModelSelectionTabView` / `ModelManagementViewModel` / `ModelCapabilityProbe`.
- **`ChatViewModel`-as-loader smell.** `idlewick` builds a whole `ChatViewModel` purely to load a model for its NPC runner — no chat. Because the load path (`ModelLoadCoordinator`) lives on `ChatViewModel`.
- **Named gaps in consumer code comments:** `#1298` (no public image-attachment API on `ChatViewModel`), `#1300` (no pin API on `SessionManagerViewModel`), `#1312` (consumers manually mirror `ChatViewModel.selectedModel` → `ModelRegistry.selectedModel`).

## Key internal findings (what we're actually building on)

The logic is **far less trapped than the consumer re-implementations imply** — it already lives in reusable services. This is a packaging/exposure job, not a reinvention.

- **One stored selection value, two write paths.** `ModelRegistry.selectedModel` is the single source of truth. `ModelRegistry.selectModel(_:) -> Bool` already exists and is commented *"Hook site for future logging / validation / auto-load wiring."* The dual path (`ChatViewModel.selectedModel` forwarding setter + a `withObservationTracking` re-install hack to retro-run endpoint sync) is the root of `#1312`.
- **Selection and load are deliberately separate.** Load orchestration is `ModelLoadCoordinator` (latest-wins task manager), owned by `ChatViewModel`, dispatched via `dispatchSelectedLoad()` → `currentLoadIntent` → `ModelLoadPlan.compute()` (the fit/admission check) → `inferenceService.loadModel(from:plan:)`. The coordinator genuinely needs only `InferenceService`, not chat *state* — it's entangled with chat *ownership*, which is what Option B unwinds.
- **Only one piece is truly view-trapped:** the `ModelSelectionSortOrder` enum + static `sortModels()` in `ModelSelectionTabView`. The fit/recommendation services exist (`ModelFitScorer`, `DeviceCapabilityService.recommendedModelSize()`, `ModelInfo.effectiveCapabilityTier`, `ModelManagementViewModel.rankedVariants/recommendedModel/compatibilityTier`) — **but see Correction A below: they don't all key off `ModelInfo`.**
- **Capability data is computed by `ModelCapabilityProbe` — but see Corrections B/C below for where it actually works and who consumes it.**

## Corrections from persona review (2026-06-14) — premises that were FALSE

Three adversarial reviewers (SDK-consumer, concurrency/architecture, docs/DX) verified the plan against source. Several load-bearing premises were wrong. These corrections are now part of the plan.

- **A. `ModelFitScorer` has no `ModelInfo` overload.** It scores `DownloadableModel` / resident profiles only (`Sources/ManifoldHardware/AppleSiliconBandwidth.swift:284,418,468`). `ModelRegistry.availableModels` is `[ModelInfo]`. So a `ModelSelection` over the registry **cannot run the fit scorer on what it selects from** — the recommendation surface would be empty and fireside-night's `ModelTier.classify` survives. **A `ModelInfo → ModelFitScore` bridge is a hard prerequisite, not a free compose.**
- **B. `ModelCapabilityProbe` can't read GGUF.** It hard-requires a sibling `config.json` and throws `configNotFound` otherwise (`ModelCapabilityProbe.swift:82-86`). GGUF models are single files → `supportsCode`/`supportsMultilingual` ship honest-false for the common local case. Auto-detection alone does **not** retire offgrid-ai's curated resolver; an explicit override/curation seam is required.
- **C. "Only MLX consumes the probe" is stale → it has ZERO in-repo consumers** (MLX moved to the companion package in v0.48). PR 1 is **wiring a probe from scratch into discovery/download**, not persisting an existing computation. Re-scope accordingly.
- **D. The `ModelLoadCoordinator` is ALREADY standalone** (`Sources/ManifoldUI/ViewModels/ModelLoadCoordinator.swift`, `init(inferenceService:)`, extracted in #329) — but its observable output is **8 `@MainActor` callback seams** into `ChatViewModel` (lines 38-59). "Compose the coordinator" really means "supply a headless replacement for that 8-closure side-effect contract." 2a is therefore near-cosmetic; all risk is in 2b.
- **E. Two coordinators over one `InferenceService` cross-talk.** `modelLoadProgress` is a single shared scalar; per-coordinator generation counters don't see each other. A headless `ModelSelection` that builds its *own* coordinator alongside a `ChatViewModel` leaks foreign-load progress into the chat phase. The service-level `LoadRequestToken` keeps *backend* state correct but not UI side-effects. **`ModelSelection` must SHARE the host's coordinator (one coordinator per `InferenceService`), not construct a second.**
- **F. The #1312 collapse via the observer is a race.** Endpoint-sync today runs **synchronously** in the `ChatViewModel.selectedModel` setter; the `withObservationTracking` observer path is **async** (Task hop). Making the observer canonical lets `dispatchSelectedLoad` read a stale `selectedEndpoint` via `currentLoadIntent` (`ChatViewModel+ModelLoading.swift:82-88`) and dispatch the **wrong `LoadIntent`**. The single entry (`ModelRegistry.selectModel`) must clear the mutually-exclusive selection **synchronously**. Removing the synchronous setter-clear without a synchronous replacement is a silent behavior break for binding-based consumers.
- **G. Doc snippet-gate blockers.** The snippet scaffold links only `ManifoldKit` + `ManifoldUI` (`extract-snippets-test.sh:96-101`); the umbrella deliberately excludes `ManifoldUIModelManagement` (`Sources/ManifoldKit/Exports.swift`). So `ModelPicker` snippets won't resolve, and `swift,no-build` is *blocked* under contract headings (`bring your own`/`quick start`/`headless`) by `check-readme.sh:229-237,300`. Also `extract-snippets.sh` uses a **hardcoded `INPUTS` list, not a glob** — a new `QUICKSTART-MODEL-SELECTION.md` triggers the workflow but is **never compiled** unless registered. And `ModelSelection`'s home module must be **ManifoldInference/Runtime, not ManifoldUI** — otherwise the headless guide imports a UI module, contradicting the whole premise.

## Doc surface findings (the uplift target)

- Snippet gate (`readme-snippets.yml` + `scripts/extract-snippets*.sh`) compiles every ` ```swift ` block in `README.md`, `docs/QUICKSTART-*.md`, `docs/WHY-MANIFOLDKIT.md`, and **every `.md` in `Sources/**/*.docc/`**. New doc code must compile or be tagged `swift,no-build`. Package.swift fragments auto-skip.
- `ManifoldUIModelManagement.docc` is nearly bare (landing + `DeviceAwareModelRecommendations.md`, which is scoped to *local-model browsing* only).
- `docs/QUICKSTART-BRING-YOUR-OWN-UI.md` covers headless *inference* (stream tokens from `InferenceService`) but **not** model selection/loading/capability routing. There is no "choose and load a model without ChatView" guide. This is the cavity to fill.

---

## Plan: 3 sequenced PRs + a conceptual doc spine

Sequencing rule (per CLAUDE.md): the signature-breaking PR merges first, the rest rebase. Each PR ships its own tests + docs (no doc follow-ups). PR 1 is independent of 2/3 and can land in parallel.

### PR 0 — Enablers (NEW, independent, merge first) — the bridges the façade can't exist without

Carved out because Corrections A/B/C/E mean two "free composes" are actually new code, and they're independently testable.

- **`ModelInfo → ModelFitScore` bridge** (Correction A): add `ModelFitScorer.score(_ model: ModelInfo, useCase:device:)` (or an adapter that derives the scorer's inputs from `ModelInfo`). Unit-tested against known models. Without this, PR 2's recommendation surface is empty.
- **Shared-coordinator seam** (Correction E): decide and implement how one `ModelLoadCoordinator` is shared per `InferenceService` so a headless surface and a `ChatViewModel` don't each build one. Options: (i) `InferenceService` vends/owns the coordinator; (ii) `ModelSelection` takes an injected coordinator (same instance the host uses). See Decision 5.
- **Headless load-status surface** (Correction D): define what replaces the 8 `ChatViewModel` callbacks for a non-chat host — a load-status enum and/or `AsyncStream` the coordinator emits, so idlewick can observe load success/failure instead of silent no-ops.
- No public view changes; no docs beyond symbol docs. This unblocks PR 2 and de-risks it.

### PR 1 — Model capability data layer (independent)

**Goal:** Stop consumers re-deriving capability flags MK already computes — *where it can*, honestly.

- Add `supportsCode`, `supportsMultilingual`, `supportsReasoning` to `ModelInfo` as **`Bool?` override-over-detected** (resolved as `curated ?? detected ?? false`), with an explicit curation/override seam (Correction B). Never silently honest-false without a way to override.
- **Wire `ModelCapabilityProbe` into discovery/download from scratch** (Correction C — it has no current in-repo consumer). Probe only where `config.json` exists (HF/MLX dir layout); GGUF single-file models fall back to curation (`CuratedModel`) — document this limit explicitly.
- `supportsReasoning`: `CloudModelManifestTable` for cloud; honest-`false` for local unless curated.
- Persist resolved flags in the catalog (`.manifold-catalog.json`).
- **API-break gate watch:** new stored properties on public `ModelInfo`; verify digester locally (`api-breakage-allowlist.txt` has NO `#` comments).
- **Docs:** `Capabilities.md` in **`ManifoldInference.docc/Articles/`** (Correction G — `ModelInfo` is re-exported there so snippets compile; `ManifoldModelCatalog` has no `.docc`). Must state the GGUF honest-false limit and the `supportsReasoning`-local footgun so routing snippets don't mislead.

### PR 2 — Headless `ModelSelection` + #1312 collapse (signature-breaking; merge first of the dependent set)

**Goal:** Option B. Make selection + load reachable without `ChatViewModel`.

- **New headless `ModelSelection`** in **`ManifoldInference` (NOT ManifoldUI** — Correction G): composes `ModelRegistry` (state + `selectModel`), the PR-0 `ModelInfo` fit bridge + `DeviceCapabilityService` (recommendation), and the **shared** coordinator (Correction E). Exposes the sorted/scored/**grouped** model list **as data** (the real product); auto-load is a synchronous `@MainActor` call into the shared coordinator. Hoist `ModelSelectionSortOrder` + `sortModels()` onto this type, and add a grouping seam (foundation vs downloaded) that fireside-night needs.
- **Injectability** (consumer review): provide a `protocol ModelSelecting` seam (or keep scorer/device-cap as free functions) so offgrid-ai can mock it without re-wrapping behind its own protocol.
- **Collapse the dual write path (`#1312`) SYNCHRONOUSLY** (Correction F): `ModelRegistry.selectModel` becomes the single entry and clears the mutually-exclusive selection **synchronously inside the registry** — not via the `withObservationTracking` Task. Keep a synchronous path for the public `selectedModel` binding setter; add a characterization test proving the setter still syncs endpoints. Migration note for binding-based consumers.
- **`ChatViewModel`** consumes the shared coordinator + `ModelSelection`; behavior preserved.
- **Docs:** new `docs/QUICKSTART-MODEL-SELECTION.md` — **register it in `extract-snippets.sh` `INPUTS` + an `extract_one` call** (Correction G; it will otherwise escape validation). Cover the three missing rungs: a worked `ModelLoadPlan.compute()` rejection, a per-family Foundation/local/cloud fork, and the `supportsReasoning`-honest-false callout.
- **Size risk / split:** 2a (relocate/expose coordinator — near-cosmetic per Correction D) is low-value as a safety split; the risk is all in 2b (façade + #1312 + the two new race-sensitive paths). Split only on review-size grounds, and only with the §Validation race/ordering tests attached to 2b. See Decision 2.

### PR 3 — `ModelPicker` sample view + UI rewire (+ gap closers)

**Goal:** A thin, styleable *sample* selector — the headless `ModelSelection` is the product (consumer + architecture review both said so).

- Promote `ModelSelectionTabView` → public `ModelPicker` as a **thin sample over `ModelSelection`**, with a section/grouping seam. Consumers are expected to render their own over `ModelSelection`; `ModelPicker` is the default, not the only path.
- Re-express `ModelManagementSheet` to compose `ModelPicker` (no behavior change).
- Fold in `ChatViewModel.attachImage(_:)` (`#1298`) and `SessionManagerViewModel.togglePin(_:)` (`#1300`).
- **Docs snippet-gate fix (Correction G):** EITHER (a) add `ManifoldUIModelManagement` as a third linked product in `extract-snippets-test.sh:96-101` (shipped in this PR), OR (b) keep `.docc` snippets to umbrella-reachable types and demote `ModelPicker` to prose/`<doc:>` links — and never under a `bring your own`/`quick start`/`headless` heading. See Decision 6.

### Conceptual doc spine — OWNED BY PR 2 (Correction G), not woven across

One prose doc — **"Choosing and Loading Models"** — lands whole in PR 2 (the conceptual center). PR 1 and PR 3 **link into it via `<doc:>`** rather than editing it, avoiding three-author conflict churn on a snippet-gated file. Covers cross-backend selection strategy, capability routing, device-fit, and the headless load path.

---

## Decisions

**Locked 2026-06-14:**

1. **`supportsReasoning`: included in PR 1** as `Bool?` override-over-detected. Cloud from `CloudModelManifestTable`; local honest-`false` unless curated.
2. **PR 2 splits only on review-size grounds.** Per Correction D the 2a split buys little safety (coordinator already standalone); keep as one PR unless it exceeds ~40 files / ~800 net lines, and attach the race/ordering tests to the façade half.
3. **`#1298`/`#1300` fold into PR 3.**
4. **Public names:** state object `ModelSelection` (+ `protocol ModelSelecting` seam), view `ModelPicker` (a thin sample, not the primary deliverable).

**Locked from persona review (2026-06-14):**

5. **Shared coordinator:** `InferenceService` vends/owns the single `ModelLoadCoordinator`; `ChatViewModel` and `ModelSelection` both receive that instance. "One coordinator per service" is structural, not a convention. (PR 0.)
6. **Doc gate fix:** add `ManifoldUIModelManagement` as a third linked product in `extract-snippets-test.sh:96-101`, shipped in PR 3 — `ModelPicker` gets compile-checked examples.

**Implementation call (decide during PR 0, no sign-off needed):**

7. **`ModelInfo → ModelFitScore` bridge shape** — scorer overload vs. separate adapter. Default to a `ModelFitScorer.score(_:ModelInfo,…)` overload unless the adapter proves cleaner in code.

## Validation

- `scripts/test.sh --profile local` before every push (full core surface + Macros).
- Optional-traits sweep (`swift build --build-tests --traits Server,Macros`) — PR 1 touches a switched-capability-shaped type.
- `readme-snippets` gate: run `scripts/extract-snippets.sh` + `scripts/extract-snippets-test.sh` locally first. **Confirm the new QUICKSTART file is actually extracted** (Correction G — it's a hardcoded `INPUTS` list, not a glob).
- API-break digester locally for PR 1 (`ModelInfo`) and PR 2/3 public additions.
- Grep ALL of `Tests/` for references to changed types (selection lifecycle, `ModelLoadCoordinator`, `ModelInfo`).

**New characterization tests required by the review (must be authored, not asserted):**
- **Two-surface topology (Correction E):** a `ModelSelection` and a `ChatViewModel` over one shared `InferenceService` — assert a headless load does NOT leak progress/phase into the chat surface. The existing `LoadDispatchCoordinationTests` / `InterleavingTests` all drive through `ChatViewModel.selectedModel =` and give zero coverage here.
- **Synchronous endpoint-clear (Correction F):** selecting a local model through `ModelRegistry.selectModel` clears `selectedEndpoint` **before** `dispatchSelectedLoad` reads `currentLoadIntent` — i.e. the load intent is the model, not the stale endpoint.
- **Public setter still syncs (Correction F migration):** `selectedModel = x` binding path still triggers endpoint-sync, or an explicit migration note documents the change.
- **Headless load latest-wins:** `ModelSelection`'s own load path resolves the latest selection (mirror of the existing `ChatViewModel` latest-wins guarantee).
- Keep green: `LoadDispatchCoordinationTests`, `InterleavingTests`, `CoordinatorClosureIsolationTests`.
