# Overnight run brief — tool-call conformance: act on the matrix

**Purpose.** Self-contained brief for an unattended overnight session (use the `overnight-pipeline` skill). The measured spine and the first cross-backend eval are **done** (see "What already shipped"). This run **converts the matrix findings into fixes** and closes the two genuinely-deferred pieces. Read top to bottom first.

**Locked decisions (planning session 2026-06-23):**
- Merge autonomy: **core PRs auto-merge (admin) on green CI; companion PRs auto-merge (admin) on green CI now that v0.60.0 is released; release-please PRs stay for morning review — never auto-merge a release PR.**
- Re-measure depth: the cells flagged *re-measure pending* in `MATRIX.md` → broad × stable (5 repeats, d0 + decoy ladder where it was incomplete).

---

## What already shipped (do NOT re-do)

The 2026-06-22 train landed almost all of the original build-out:

- **v0.59.0:** `ModelInfo.toolCallClaim` static capability (#2009), `RenderConsistencyChecker` render round-trip (#2022), templateless image/tool-result threading (#2014).
- **v0.60.0 (cut 2026-06-22):** `ToolCallConformance` port + value type + **in-memory** cache (#2030, Step 3 — *SwiftData adapter still deferred*), tool-call **dialect** on `BackendCapabilities` (#2029, Step 4 core seam), transcript attribution + `ConformanceScorer` + `manifold-tools score` (#2027), `openai-compat` backend + `--extra-tools` decoy flag (#2031), parallel concurrent-safe tool dispatch + transient-error retry (#2026), public JSON-Schema → GBNF surface (#1992/#2025), **Mistral system-prompt-fold renderer fix (#2032)**.
- **Eval:** the first full cross-backend matrix ran — `docs/plans/archive/runs/20260622-232839/MATRIX.md` (+ scored CSVs) in PR **#2033**. Lane 2, the decoy ladder (Lane 3a), the OpenRouter cloud lane (3b), and the failure taxonomy (3d) are all in it.
- **Companions on v0.60.0:** manifold-llama `0.2.12` + manifold-mlx `0.2.10` release PRs are staged (changelogs rewritten); the MLX VL-SIGSEGV graceful-error fix merged as manifold-mlx **#89**.

So the spine exists and has been measured. This run acts on what it found.

---

## The findings to act on (source: `MATRIX.md`)

| # | Finding | Cell(s) | Class |
|---|---------|---------|-------|
| F1 | **gemma3-4b-tools renders-no-call on BOTH Ollama and llama.cpp** (F1 0.000, 0/45 × 5 repeats each) | Ollama + llama.cpp | model never emits a tool call under either tool-capable template |
| F2 | **qwen35-9b GGUF renders-no-call on llama.cpp** while Ollama (1.000) + MLX qwen3 (0.917) tool-call cleanly | llama.cpp | renderer/template gap, not a model limit |
| F3 | **MLX Mistral-v0.3 no-call** — renders fine via swift-transformers but emits 0 tool calls | MLX | distinct from llama's render-refusal |
| F4 | **gemma4-e4b GGUF load-fail** (`Unsupported model architecture: gemma4`) | llama.cpp | backend/upstream arch gap (tool-calls fine on Ollama) |
| F5 | **Pre-#2032 cells** — llama.cpp Mistral (render-fail) + MLX Mistral were measured before the #2032 fix | llama.cpp, MLX | re-measure pending |
| F6 | **MLX qwen3-8b decoy ladder incomplete** — only d0 scored; d1 transcript exists unscored, d3–d20 missing | MLX | data gap |

---

## Lane 1 — Re-measure (DATA, local hardware; fast, do first)

Confirms which findings are already fixed before spending effort diagnosing them.

1. **Re-run the pre-#2032 cells (F5)** against current core (v0.60.0 is released — pin companions to it, no path-pin needed):
   - llama.cpp Mistral-v0.3-Q4 — **expected to recover** now that #2032 folds the system turn. If it does, the cell flips ✅ and F5/llama is closed.
   - MLX Mistral-v0.3-4bit — #2032 is a *core* `JinjaPromptRenderer` fix; MLX renders via swift-transformers, **not** core, so the no-call likely persists → that confirms F3 is a separate MLX-side issue, not the renderer bug.
2. **Complete the MLX qwen3-8b decoy ladder (F6)** — score the existing d1 transcript and run d3/d5/d10/d20 (serialize — MLX Metal deadlocks on concurrent runs; reap orphans; no `timeout` on macOS).
3. Emit an updated `MATRIX.md` delta (new run dir) — keep it light: **matrix + scored CSVs only, prune raw JSONL/logs** (per #2033's trim convention; raw transcripts are ~12 MB and not worth committing).

## Lane 2 — Diagnose + fix the real conformance bugs (CORE + COMPANION PRs)

Each is a real finding, in-theme, independently shippable. Diagnose first (read the rendered prompt vs the model's reply in the transcript), then fix the smallest seam.

- **F1 — gemma3 renders-no-call on both local backends.** The tool-capable gemma3 template (`gemma3-4b-tools` uses gemma4's spliced Jinja) declares tools but the model emits none. Check: does the rendered prompt actually contain the tool block, or is it dropped (an (a)-class render gap that `RenderConsistencyChecker` should already flag)? If the template renders tools but the model still won't call — record it as a **model capability gap** in the matrix (not a bug); if the render drops them — that's a core renderer fix.
- **F2 — qwen35-9b on llama.cpp.** Ollama + MLX qwen tool-call; only the llama.cpp GGUF path is silent. Compare the llama.cpp rendered prompt against Ollama's server-side template for the same weights — the divergence is the bug. Likely a core `JinjaPromptRenderer` / GGUF-template-extraction gap. Core PR.
- **F3 — MLX Mistral-v0.3 no-call.** Diagnose in the companion (manifold-mlx). Mistral-v0.3's MLX template requires strict user/assistant alternation; the system+tool message shape may still be tripping it even post-#2032 (which is core-side). Companion PR.
- **F4 — gemma4 arch unsupported by llama.cpp.** This is an upstream llama.cpp loader limit, not ours. Verify against the current vendored llama.cpp build; if genuinely unsupported, **document it as a known backend gap** in the matrix + companion README rather than forcing a fix. Do not chase an upstream arch port overnight.

**Companion work is now real PRs, not drafts** — v0.60.0 is released and both companions track it, so the core `ToolCallDialect` API is available. Also land the originally-deferred Step-4 companion change: make `LlamaBackend`/`MLXBackend` `supportsToolCalling` **conditional** and surface the dialect already selected internally (`LlamaToolMarkers` / `MLXToolDialect`) instead of the hardcoded `true` (LlamaBackend.swift:149/:463, MLXBackend.swift:~149). Companion enum-growth/switch-exhaustiveness: `@unknown default`.

## Lane 3 — Persist measured cells (CORE; the deferred follow-up)

#2030 shipped the in-memory `ToolCallConformance` cache; the SwiftData adapter is the deliberate human-reviewed follow-up. `MATRIX.md` is currently a static doc — the spine was built to *store* these cells.

- Add the SwiftData adapter + a new schema version (analog of `BenchmarkCache`), keyed `(model × quant × backend)`, fields: capability `supported|unsupported|unknown`, observed `dialect`, `source: templateExpressible|renderConsistent|measured`, P/R/F1, `measuredAt`, sample count. Lazy/backgrounded; `unknown` until measured; never a cold-start tax.
- **Design the write-path FIRST (the flagged derail risk):** the artifact lives in core but the soak runs in *three repos*. How does a companion hand a measured cell back to core's cache? Spike this before building. **SwiftData schema migrations are human-reviewed — open this as a PR for morning, do not auto-merge.**

---

## Setup (still valid from prior session; VL-SIGSEGV now fixed)

- **MLX generation needs the xcodebuild-built binary** (plain `swift build` aborts "Failed to load the default metallib"). Build: `xcodebuild -scheme manifold-tools-mlx -configuration Release -derivedDataPath .build/tools-mlx-derived -destination 'platform=macOS,arch=arm64' build`, run `.build/tools-mlx-derived/Build/Products/Release/manifold-tools-mlx`. Canonical driver: `manifold-mlx/scripts/tool-decoy-sweep.sh` (Bash-3.2-safe), pass `MTOOLS_BIN=…`.
- **VL-model SIGSEGV is FIXED (manifold-mlx #89)** — `manifold-tools-mlx` now detects a `preprocessor_config.json`/`processor_config.json` marker and errors gracefully instead of crashing. The sweep no longer needs to hand-pre-filter, but VL models still won't *run* (text harness) — they'll just skip cleanly.
- **MLX text leg:** Mistral-v0.3 (alternation quirk), Llama-3.2-3B ✓, Qwen3-8B ✓. gemma on MLX unavailable (VL builds / `gemma-2` system-role template error).
- **Ollama:** server up, `OLLAMA_MODELS=/Users/roryford/Documents/Models`; models registered incl. the `*-tools` template variants (`gemma3-4b-tools`, `mistral-7b-tools`).
- **OpenRouter cloud anchors** (key in `~/.zshenv` as `OPENROUTER_API_KEY`): paid fallback `openai/gpt-oss-120b`; free `nemotron-3-super`, `owl-alpha`, `gemma-4-31b:free`, `laguna` (reasoning — give generous `max_tokens`). MK base URL = `https://openrouter.ai/api`.

## Gotchas (load-bearing)
- Host contention overnight SIGTERMs local gates → lean on PR CI + the CI-watch loop; don't trust a killed local gate.
- `behavior change → grep ALL Tests/ for the old contract` and run the **full** affected target, not a filtered subset (#2026 auto-retry broke ScenarioRunnerTests across targets).
- CI is BLOCKED by branch protection → admin-merge green core/companion PRs (`gh pr merge --squash --admin`).
- Concurrent `test.sh` / MLX runs collide (TMPDIR / Metal) → serialize.
- `ScenarioLoader.loadBuiltIn()` is CWD-relative — companions vendor scenarios (already done).
- **Companion release sequencing:** v0.60.0 is already released; companion release PRs (llama 0.2.12, mlx 0.2.10) are staged for morning merge. Companion fixes this run roll into the *next* companion patch — they re-cut automatically via release-please on merge to companion main.

## Done =
Lane 1: re-measured pre-#2032 cells + completed MLX qwen3-8b ladder → `MATRIX.md` delta committed (matrix + CSVs only). Lane 2: F1–F4 each diagnosed and either fixed (green-CI PR, core auto-merged / companion auto-merged) or documented as a known gap with rationale; companion `supportsToolCalling` made conditional + dialect surfaced. Lane 3: SwiftData `ToolCallConformance` adapter + write-path as a **draft PR for morning review** (schema migration). Morning summary: which findings flipped on re-measure, fixes merged, gaps documented, and the persistence PR awaiting review.
