# Overnight run brief — local tool-calling **capability surface** (+ close/triage F3)

**Purpose.** Self-contained brief for an unattended overnight session (use the `overnight-pipeline` skill). It will be run from a *separate* session that does NOT have the originating conversation — so this brief is the only context. Read top to bottom first. Spans 3 repos: `ManifoldKit` (core), `manifold-mlx`, `manifold-llama`.

**Theme.** Make MK *honestly communicate, per-cell, which (model × quant × backend) combinations support tool calling* — what works, what won't, and known issues — so consumer apps/devs don't ship a model that silently no-calls. This is predominantly a **local-inference** problem (cloud + Ollama self-report and already work); the value is the local matrix (MLX, llama.cpp), and the measured verdict can only come from **real Apple-Silicon soaks** — which is why this is overnight-shaped.

---

## Open decisions — LOCK THESE before the run (planning session 2026-06-25)

> These are the genuine forks. The originating session left them for the human to lock. Defaults in **bold** are the recommendation; the runner should treat the locked answer as authoritative.

1. **F3 investment.** Two soaks have now shown MLX-Mistral-v0.3-4bit *emits but does not parse* (`[TOOL_CALLS]` sentinel + JSON quotes dropped by the MLX detokenizer; structural threading #102 + the quote-normalizer #104 both insufficient). Options: **(a) one more bounded attempt** — extend the normalizer/marker to recover the *sentinel-dropped* case (calls that arrive with no `[TOOL_CALLS]` prefix), re-soak once; if still F1=0, **mark MLX-Mistral a documented known-issue and stop** — vs (b) declare it a known-issue now and spend zero more soak time. **Default: (a), single bounded attempt then document.**
2. **#104 fate.** Draft PR `ManifoldKit/manifold-mlx#104` (Mistral `[TOOL_CALLS]` quote-normalizer) is correct, tested (11 parse-back tests green), and regression-free, but does NOT close F3 alone. **Default: merge #104 on its own merits** (it's a building block + the deterministic safety net for the sentinel work), with the PR body stating F3 remains open. Alternative: fold it into the sentinel fix as one PR.
3. **Capability-surface breadth.** Tool-calling only, or all capabilities (vision / guided-generation / thinking / streaming / context-window)? **Default: build the surface tool-calling-first but design the registry + API extensibly** (an enum of capability dimensions), so other dimensions slot in later without a rewrite. Tool-calling is the only dimension with the *measured* machinery today.
4. **Merge autonomy** (carry-over, re-confirm): **core + companion PRs auto-merge (admin) on green CI; release-please PRs NEVER auto-merge — leave for morning review.**

---

## What shipped tonight (2026-06-24/25) — do NOT re-do

- **core #2039** (merged `3c8ac5da`): Gemma tool-call **close delimiter** adjudicated to `<|end_of_turn>` (both old taxonomies were wrong) + `CrossTaxonomyDialectParityTests` (per-PR cross-taxonomy tripwire).
- **core #2040** (merged `648257d2`): `ConformanceScorer` now recovers expected tools from dispatch-requirement assertions when a transcript's `prompt` record omits `requiredTools` (the llama.cpp soak emitter does) — fixes the false-FP scoring that made the recovered llama.cpp-Mistral cell read F1=0.
- **core #2038** (merged `ba936494`): the tool-calling architecture proposal doc itself.
- **manifold-mlx #101** (merged `f3f72bd`): first MLX **render-side golden** corpus (model-free, byte-exact) — the deterministic regression net.
- **manifold-mlx #102** (merged `862be1b`): **additive structural-tools threading** into `applyChatTemplate(messages:tools:)` + `supportsToolCalling` now `dialect != .unknown` + sorted JSON keys + Mistral prose gated off. Soak-verified: Llama-3.2 byte-identical (no regression); MLX-Mistral flipped silent→**emitting** `[TOOL_CALLS]`.
- **manifold-mlx #104** (OPEN draft): Mistral `[TOOL_CALLS]` quote-normalizer (see decision #2).
- **Matrix re-measure**: `docs/plans/archive/runs/overnight-20260624-212539/MATRIX.md` — post-#2032/#2035. **llama.cpp-Mistral recovered** (render-fail→✅); **MLX-Mistral F3 confirmed still failing**; gemma3 renders-no-call (model fact); gemma4 still load-fails on llama.cpp (arch); `llama3.1-8b` + `qwen3.5-4b` GGUFs were **absent from disk** (not measured).
- **Companion issue comments**: manifold-llama #67/#45, manifold-mlx #82/#100/#97 carry fresh re-measured evidence.

---

## Workstreams (priority + dependency order)

Each is an independently shippable green-CI PR unless noted. Stage explicit paths, draft-PR early, orchestrator owns CI-watch + merge.

### A. F3 — sentinel-drop fix or documented-known-issue (per decision #1)
- Root cause (verified): the MLX streaming detokenizer drops the `[TOOL_CALLS]` **sentinel token** inconsistently, *and* the inner JSON quotes/spaces. `MLXToolMarkers.mistral` + the #104 normalizer both key on the sentinel to engage — so a sentinel-dropped emission (`02-calc` arrived as `325087\n\n[{function:calc,…}]`, no prefix) never parses. Same family as issue #59 (`MLXLlamaPythonTagNormalizer`).
- Bounded attempt: extend recovery to the sentinel-absent case (detect a bare `[{…}]` tool-array in the Mistral channel and treat as a call), repair quotes via #104's normalizer, parse. Add parse-back fixtures for the sentinel-dropped shape. **Then one live re-soak** (see soak lane) — expect Mistral F1>0. If still 0, write it up as a known-issue (workstream C) and STOP — do not loop indefinitely.
- Re-soak the missing/recovered cells while Metal is up: re-download `llama3.1-8b` + `qwen3.5-4b` GGUFs to `~/Documents/Models/`, re-measure on llama.cpp; re-confirm llama.cpp-Mistral now reads F1>0 with the #2040 scorer fix.

### B. Cross-repo write-path (HARD PREREQUISITE for the consumer surface)
- Today companion soaks **cannot reach** core's `ToolCallConformance` SwiftData cache (`ManifoldRuntime`/`ManifoldPersistenceSwiftData` are test-target-only deps in the companions — plan Phase 3 / P3b / #1784). So no companion-measured cell can populate a consumer-facing answer.
- Build: **soak emits JSONL → a core-side importer upserts the cache** (mirrors the existing `manifold-tools score` file flow; keeps SwiftData in core). Define the JSONL contract once; have `tool-decoy-sweep` / `manifold-tools` emit it; add the importer + an integration test (in-memory SwiftData store — do NOT mock persistence).

### C. Known-issues registry (fastest standalone win; the "what won't work + why")
- Structured per-cell data (NOT prose): `{ model, quant, backend, status, reason, tracking-URL, workaround }`. Seed from tonight's MATRIX.md + the issue comments: gemma4×llama.cpp (load-fail, arch, #67, use Ollama); Mistral×MLX (emit-but-unparseable, #104/sentinel, link); gemma3×any (renders-no-call, model fact, none). Lives in core; feeds both the API (D) and the doc (E).

### D. Runtime capability query API (depends on B + C)
- A typed `ToolCallingSupport` fusing the derived claim (`ChatTemplateToolDescriptor`) + measured verdict (`ToolCallConformance`) + registry (C): `.supported(f1,decoyCeiling)` / `.unsupported(reason,tracking)` / `.unverified(claim)` / `.knownIssue(summary,tracking,workaround)`. Mirrors Apple's `LanguageModelCapabilities` + throw-on-unsupported. **Per-cell** (model × quant × backend), never per-model. Three-state honesty: never conflate "template can express it" with "it works."

### E. Generated capability matrix doc (depends on B)
- Productionize `MATRIX.md` as a **generated** artifact from the conformance cache (per release), not hand-maintained (the LiteLLM-drift trap). The cross-backend table, published for devs.

> Sequencing: **A** (Metal, do first while soaking) ∥ **C** (no deps) → **B** (prereq) → **D**, **E**. Don't start D/E before B populates the cache, or they'll have nothing real to show.

---

## The live soak lane (project-specific, Metal-bound)
- Models in `~/Documents/Models/mlx-community/{Llama-3.2-3B-Instruct-4bit, Mistral-7B-Instruct-v0.3-4bit, Qwen3-8B-4bit}`; llama.cpp GGUFs in `~/Documents/Models/`.
- **MLX eval needs the xcodebuild-bundled metallib** — `swift build` binaries abort at model load. Build from the worktree: `xcodebuild -scheme manifold-tools-mlx -configuration Release -derivedDataPath .build/tools-mlx-derived -destination 'platform=macOS,arch=arm64' build`, then `MTOOLS_BIN=.build/tools-mlx-derived/Build/Products/Release/manifold-tools-mlx DECOY_LADDER=0 scripts/tool-decoy-sweep.sh <model-dirs>`.
- **Soaks are SERIAL — Metal is exclusive.** Never run two MLX evals (or an MLX eval + MLX integration test) concurrently; xcodebuild deadlocks. Run each soak in the background to a logfile and wait.
- Rebuild the eval binary FROM the branch under test (tonight's matrix used a stale prebuilt binary — a trap). Don't clean/rebuild the *core* eval binary mid-eval; re-score from raw JSONL.

---

## HARD GUARDRAILS (the run is unattended — these are non-negotiable)
- **Worktree discipline**: each task gets its OWN worktree off `origin/main`, named branch, PR. Companion tasks make their own worktree *inside the companion repo* — NEVER `isolation:worktree` for companion work (cross-repo hazard). Never edit a shared checkout from parallel workers.
- **NEVER `git add -A`** — it sweeps `default.profraw`, `soak-out/`, `tmp/` transcripts, and digester artifacts into the commit (this bit #102 tonight; caught only by inspecting the commit). Stage EXPLICIT paths every time.
- **Draft-PR the moment it compiles**; the orchestrator (not the worker) owns CI-watch + merge. Workers return early from long gates.
- **Squash-merge; `--admin` on green** (core has branch protection requiring review — `gh pr ready` then `gh pr merge --squash --admin --delete-branch`). Mark the draft ready before merging.
- **Stacked-PR squash hazard**: after squash-merging a base PR, a child stacked on it goes CONFLICTING (inherited pre-squash commits diverge from the squashed main). Recover by rebasing the child onto the new `origin/main` via patch-reapply (`git diff origin/main HEAD > p; git reset --hard origin/main; git apply p; add explicit paths; commit; push --force-with-lease`).
- **Soaks serial** (Metal exclusive — above).
- **Don't open GitHub issues** for follow-ups — use the known-issues registry (C) or code comments. Add to umbrella **#2005**.
- **Don't hand-tag companions** — pin bumps are automated via `core-bump.yml`. Release-please PRs are never auto-merged.
- **Conventional Commits** (PR titles are linted — squash-merge reads the PR title). `feat`→MINOR, `fix`→PATCH.
- **CI runners ship Bash 3.2** — test any shell-script edits under `/bin/bash` (no `declare -A`).
- **Don't mock persistence** — in-memory SwiftData stores; a test hitting SwiftData is an integration test.
- **Run the affected target locally** before push; CI is the authoritative gate, not the iteration loop (macOS 10× billing).

## Non-goals (do NOT do)
- Don't touch the cloud / Ollama legs — they're the clean delegated reference.
- Don't force grammar-constrained decoding on the MLX Mistral path (a grammar can't un-drop a token the detokenizer strips post-generation; #104 chose the normalizer for this reason).
- Don't attempt the full `ChatProfile` consolidation (architecture-doc Phases 1b–3) — that's a separate, larger decision, out of scope for this run.
- Don't loop indefinitely on F3 — one bounded attempt (decision #1), then document.

## Definition of done
- F3: either MLX-Mistral re-soaks to F1>0 (recovered), or it's a documented known-issue entry (C) — not an open loop.
- #104 resolved per decision #2.
- Cross-repo write-path (B) merged + an integration test proving a companion-emitted JSONL upserts the core cache.
- Known-issues registry (C) seeded from MATRIX.md, merged.
- D and E only if B lands with time to spare; otherwise leave them scoped for the next run.
- Every PR green-CI-merged (per autonomy decision) or left as a clean draft with a status note. Morning summary written to a run log.
