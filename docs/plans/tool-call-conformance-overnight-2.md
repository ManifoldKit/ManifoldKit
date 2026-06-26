# Overnight run brief #2 — tool-call conformance: re-measure clean + land Phase 0

**Purpose.** Self-contained brief for an unattended overnight session (use the `overnight-pipeline` skill). The measured spine, the scorer, and the cross-backend matrix all exist (see "What already shipped"). Two harness false-negatives were just removed (PR #2049). This run **re-measures the full matrix on a clean core** so the evidence base is trustworthy, then lands the single highest-value engineering fix (Phase 0, MLX structural tools / F3) and surfaces the latent Gemma delimiter contradiction (Phase 1a). Read top to bottom first.

**Locked decisions (carried from the 2026-06-23 brief; still valid):**
- Merge autonomy: **core PRs auto-merge (admin) on green CI; companion PRs auto-merge (admin) on green CI; release-please PRs stay for morning review — never auto-merge a release PR.**
- Re-measure depth: **broad × stable** — 5 repeats, d0 + full decoy ladder (+1/+3/+5/+10/+20) where the cell supports it.

---

## What already shipped (do NOT re-do)

- **The scorer is correct as of PR #2049.** Two false-negatives that *understated* scores are fixed and verified:
  - **No-tool F1 drag** — already handled before this run: no-tool scenarios carry `toolSelection: nil` and are excluded from the macro mean.
  - **llama.cpp TP attribution (F1=0.000)** — already fixed by #2043; the current scorer scores the retained llama-Mistral transcript at F1≈0.81, not 0.
  - **Bug A (#2049):** `oversize-tool-output` no longer demands the literal `"exceeds maxBytes"`/`"narrower"` — a `containsAny` kind accepts correct paraphrases. This flips `oversize` from 0-pass to pass for competent models on **every** backend.
  - **Bug B (#2049):** scenarios 06/07 now name `read_file` in backticks so companion (llama.cpp/MLX) transcripts that omit `requiredTools` score correct calls as TPs, not FPs.
- **Spine + first matrices:** `ConformanceScorer` + `ConformanceRecord` + `MatrixRenderer` + `manifold-tools score/matrix` (#2027/#2043/#2045/#2046). Prior matrices: `20260622-232839`, `overnight-20260624-212539`, `soak-20260626-100115`.
- **Mistral renderer fix (#2032/#2035)** is in core; llama.cpp-Mistral recovered (✅), MLX-Mistral did not (F3 still live).

---

## Precondition (gates everything)

**Re-measure on a core that includes PR #2049.** Every prior matrix predates the scorer fixes, so its `oversize` rows and its companion `read_file` rows are wrong-low. Before any measurement:

1. If PR #2049 is merged to `main`, build the eval binary from `origin/main`.
2. If it is **not** merged, either merge it first (green CI, admin) or pin the eval binary to its branch — do **not** re-measure on pre-#2049 core.
3. Pin companions to the matching released core minor (no path-pin); `swift build` the core eval binary, `xcodebuild` the MLX one (metallib requirement — see Setup).

Stamp every emitted `ConformanceRecord` with the actual `coreCommit`.

---

## Lane 1 — Full clean re-measure (DATA, local hardware; do first)

The first trustworthy matrix. 3 local backends + 1 cloud anchor.

1. **Ollama** (5 models: gemma3-4b-tools, gemma4-e4b, llama3.1-8b, mistral-7b-tools, qwen3.5-9b) × 9 scenarios × 5 repeats × d0. Decoy ladder (+1/+3/+5/+10/+20) for at least mistral (decoy-collapse confirmation) and qwen (decoy-robust control).
   - **Expected delta vs `soak-20260626`:** `oversize-tool-output` flips to pass for qwen/gemma4 (Bug A), lifting their scenario-pass counts. F1 means are unchanged on Ollama (Bug B doesn't touch it).
2. **llama.cpp** (Mistral-v0.3, gemma-3-4b-tools `.tooltmpl`, + re-download `llama3.1-8b.gguf` and `qwen3.5-4b.gguf` if absent). Same shape, serialize.
   - **Expected delta:** llama-Mistral reports its true F1 (~0.8–0.9, no longer scorer-suppressed); `parallel-readme-comparison` / `shopping-list-budget` `read_file` cells score correctly (Bug B).
3. **MLX** (Llama-3.2-3B ✅, Qwen3-8B ✅, Mistral-v0.3 ⚠️ F3) — text leg only; **serialize** (Metal deadlocks on concurrent runs; reap orphans; no `timeout` on macOS). Complete the qwen3-8b decoy ladder.
4. **OpenRouter** cloud anchor (`gpt-oss-120b`) as the delegated-reference control.
5. Emit an updated `MATRIX.md` in a new run dir — **matrix + scored records/CSVs only; prune raw JSONL/logs** (retain raw locally as the parse-back fixture source; exclude from commit — `git add` explicit paths, never `-A`).

## Lane 2 — Phase 0: MLX structural-tools threading (the F3 fix; COMPANION PR)

The one model failure an architecture change actually fixes, and the only remaining Mistral failure across the three local backends.

- **Root cause (pinned):** `MLXChatMessageEncoder.swift:238-305` (manifold-mlx) hand-builds a "You have access to the following functions…" text block into the system message and calls `prepare(messages:)` with **no tools parameter**. swift-transformers' structured `applyChatTemplate(messages:tools:)` is bridged but never called with tools (`TransformersTokenizerLoader.swift:63-74`). So Mistral's template never sees a `tools` field, never emits `[TOOL_CALLS]`, and answers in prose.
- **Change:** additively thread the structured `tools` through to `applyChatTemplate(messages:tools:)` for templates that declare a tools path; keep the prose fallback for templates that don't.
- **Shift-left (do FIRST):** build the Layer-1a **render golden** — assert the rendered prompt for a tool-bearing Mistral turn contains the structured tool block — so the change is provably safe deterministically before any model runs. This is the concrete guard against regressing the ✅ `llama-3.2-3b` MLX cell.
- **Prove:** re-run the MLX Mistral cell post-change; F3 closes if it emits `[TOOL_CALLS]` and scores > 0. Companion PR, auto-merge on green CI; companion enum-growth → `@unknown default`.

## Lane 3 — Phase 1a: adjudicate the taxonomy contradiction (CORE PR)

- **Write the cross-taxonomy parity test first** — it goes **red**: `ToolCallDialect.swift:14` says the Gemma close-delimiter is `<tool_call|>` while `ChatTemplateToolDescriptor.swift:157` says `<|/tool_call>`. These contradict; there is no single ground truth today.
- Adjudicate each disagreement against the **real Gemma template** (byte-render to verify — GBNF/delimiter rule names need hyphens, underscores break `parse_name`). Encode the adjudicated truth as a Layer-1b golden. This is **behaviour-defining**, not preserving.
- Core PR, auto-merge on green CI.

---

## Not in scope (model facts / backend gaps — document, don't grind)

- **gemma3-4b renders-no-call on both Ollama + llama.cpp** (F1 0.000). The template declares tools; the model emits none. A *model* fact — record it, don't chase a renderer fix unless `RenderConsistencyChecker` shows the tool block is dropped.
- **gemma4-e4b `Unsupported model architecture: gemma4` on llama.cpp** — upstream loader gap (tool-calls fine on Ollama). Document in the matrix + companion README; do not attempt an upstream arch port overnight.
- **Phases 1b–3 (dialect-aware grammar, measured arbiter, cross-repo write-path)** — explicitly gated on this run's re-measured failure count. Do NOT start them; the Mistral decoy-collapse (0.875→0.21 at +1) is their motivating case, but commit to them only after the clean matrix shows how many real failures remain. Track under umbrella **#2005**, not per-phase issues.
- **SwiftData `ToolCallConformance` persistence adapter** — the deferred Lane-3 follow-up from brief #1. If touched at all, it is a **draft PR for morning review** (schema migration is human-reviewed); design the cross-repo write-path before building.

---

## Setup (local hardware)

- **MLX needs the xcodebuild-built binary** (`swift build` aborts "Failed to load the default metallib"). `xcodebuild -scheme manifold-tools-mlx -configuration Release -derivedDataPath .build/tools-mlx-derived -destination 'platform=macOS,arch=arm64' build`; run `.build/tools-mlx-derived/Build/Products/Release/manifold-tools-mlx`. Driver: `manifold-mlx/scripts/tool-decoy-sweep.sh` (Bash-3.2-safe), `MTOOLS_BIN=…`.
- **Ollama:** server up, `OLLAMA_MODELS=/Users/roryford/Documents/Models`; `*-tools` template variants registered.
- **OpenRouter:** `OPENROUTER_API_KEY` in `~/.zshenv`; base `https://openrouter.ai/api`; paid anchor `openai/gpt-oss-120b`.
- **VL models** skip cleanly on MLX (manifold-mlx #89) — they won't run the text harness.

## Gotchas (load-bearing)

- Host contention overnight SIGTERMs local gates → lean on PR CI + the CI-watch loop; don't trust a killed local gate.
- `behavior change → grep ALL Tests/` and run the **full** affected target, not a `--filter` subset.
- CI is BLOCKED by branch protection → admin-merge green core/companion PRs (`gh pr merge --squash --admin`); `gh pr ready` first, never unconditional branch-delete after merge (use `--delete-branch` on the merge).
- Concurrent `test.sh` / MLX runs collide (TMPDIR / Metal) → serialize.
- `ScenarioLoader.loadBuiltIn()` resolves via `Bundle.module` now (CWD-independent) — but companions still vendor their scenario copies; if you reword a built-in assertion, re-vendor.
- Stage explicit paths on commit — `git add -A` sweeps `*.profraw` / digester / soak artifacts (#1970).

## Done =
Lane 1: clean matrix re-measured on ≥#2049 core across Ollama + llama.cpp + MLX + OpenRouter → `MATRIX.md` delta committed (matrix + records/CSVs only). Lane 2: Phase 0 MLX structural-tools threading shipped with a render golden, F3 re-measured (closed or still-live with evidence). Lane 3: Phase 1a parity test written (red→adjudicated→green) with the Gemma delimiter contradiction resolved. Morning summary: the clean matrix, which cells moved vs `soak-20260626`, F3 status, and the adjudicated delimiter — plus an explicit recommendation on whether the post-Phase-0 failure count justifies Phases 1b–3.
