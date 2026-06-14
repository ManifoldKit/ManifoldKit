# swiftui-chat archetype — iteration 1 (v0.50.0)

**Date**: 2026-06-14
**MK version**: 0.50.0 (git `v0.50.0-6-ge929ca40`)
**Agent model**: Opus 4.8 (all 4 runs)
**App outcome**: run-3 working (with workaround), run-4 partial (MLX), run-1 & run-2 incomplete (no final verdict — see caveat)

First SwiftUI walkthrough since the v0.48 split + P-series cleanup. Steered across
the drop-in vs hand-assembled vs MLX axes.

> **Data caveat**: run-1 (Ollama + drop-in ChatView) and run-2 (Foundation) did
> not return final verdicts within the window — their cold builds finished but no
> completion report arrived, and their on-disk `FRICTION.md` logs cover only the
> doc-reading phase (2 and 1 entries respectively). Their early findings are
> included below and flagged `[partial-log]`. The synthesis-grade signal comes
> from run-3 and run-4, which completed.

## Backend / path coverage this iteration

| Run | Path | Outcome | Persistence verified? |
|---|---|---|---|
| 1 | Ollama + drop-in `ChatView` | ◻️ incomplete | not reported |
| 2 | Apple Foundation Models | ◻️ incomplete | not reported |
| 3 | **BYO-assembly** (own views → MK view models) + Ollama | ✅ working (workaround) | yes (manual bootstrap) |
| 4 | MLX via `manifold-mlx` companion | ⚠️ partial | **yes — verified same-UUID restore** |

## Blockers (must-fix)

### B1 — Canonical multi-session §6 recipe doesn't compile: `DefaultBackends` unreachable [run-3, blocker]
This is the **SwiftUI-side manifestation of chat-cli's B1** (same root cause,
RC-1). `docs/SWIFTUI-MULTI-SESSION.md` §6 (the recommended manual-bootstrap path
"for control") shows `import ManifoldKit` as the only import, then calls
`DefaultBackends.register(with: bootstrap.inferenceService)` (doc lines 142, 353).
It does not compile: `cannot find 'DefaultBackends' in scope`. The umbrella's
`@_exported import ManifoldBackends` does **not** surface `DefaultBackends` to
consumers, and there is no `ManifoldBackends` `.library` product to depend on
directly — so `DefaultBackends` is genuinely unreachable from any external
consumer. The agent confirmed it by inspecting `Package.swift`'s product list (a
forced-blindness near-miss). `quickStart()` users dodge this (they never name
`DefaultBackends`); it bites exactly the manual path the doc recommends.

**Fix**: same as chat-cli B1 — vend a product or rewrite the recipe to
`import ManifoldOllama` + `OllamaBackends.register(with:)` (which the agent
verified works). Sweep the `DefaultBackends` references at doc lines 142/170/353/482.

### B2 — MLX cannot generate under plain `swift build` [run-4, blocker]
Cross-confirms chat-cli B2 (RC-2). The SwiftUI app **compiled cleanly, launched,
rendered the multi-session UI, and persisted/restored sessions** — but MLX
generation aborted at the same unbuilt-`default.metallib` boundary. `swift build`
produces an app that cannot load MLX's Metal kernels; MLX generation requires an
Xcode-built `.app` bundle that **no doc mentions**.

## Major

### M1 — Cold-build FS desync surfaces as a misleading MK-internal error [run-3, major]
First cold build aborted near the end with
`error closing '.../ManifoldHardware.build/ModelLoadPlan.swift.o' ... No such
file or directory` — the `.build`/workspace-state desync class CLAUDE.md documents
(`scripts/clean-build.sh` territory), likely aggravated by a path-dependency into
a live, churning checkout. A re-run recovered. But the error names an
*MK-internal* object file and reads like an MK bug; the recovery isn't
discoverable from the error text. (Partly an eval-harness artifact of building
against a live worktree — see RC-4.)

### M2 — MLX model acquisition: zero hand-holding [run-4, major]
README says MLX = "directory with config.json + .safetensors, auto-discovered from
`~/Documents/Models`", but no doc names a concrete MLX model id or gives an
`hf download` command, and `seed: .recommendedSmallModel()` only covers the GGUF
starter. MLX adopters must already know `mlx-community` exists. (Agent used
`mlx-community/Qwen2.5-0.5B-Instruct-4bit`.)

### M3 — No headless `ModelInfo` for MLX [run-4, major]
Same gap as chat-cli M3 (RC-2): `ModelInfo(ggufURL:)` is the only documented
constructor; the MLX path is discovery-only.

### M4 — Companion + local-path identity warning [run-4, major]
Same as chat-cli minor (RC-5), rated higher here: `Conflicting identity for
manifoldkit` between the companion's URL pin and the app's local-path pin —
"will be escalated to an error in future versions of SwiftPM." Undocumented; a
real hazard for the local multi-checkout dev setup CLAUDE.md itself calls out.

## Minor / papercut

- **QuickStartResult shape disagreement** [run-4, minor] — multi-session guide reads `kit.sessionManager`; README "Key Types" documents `QuickStartResult` as `{ bootstrap, viewModel }` (no `sessionManager`). Compiler arbitrated in the guide's favor; docs disagree.
- **`quickStart(backends:configuration:)` arg order** [run-4, minor] — no doc shows the two args used together; `backends` must precede `configuration`, but the guide shows `configuration:` alone first, so a 50/50 guess fails to compile.
- **MLX wiring scattered across 3–4 docs** [run-4, minor] — correct but no single MLX-quickstart page.
- **No documented local-path form for companion packages** [run-4, minor] — docs only show the GitHub-URL form.
- **No "custom views + persistence" recipe** [run-3, minor] — BYO-UI doc explicitly drops SwiftData; multi-session doc assumes MK's `ChatView`. The "bind your own views to the shared view models" path is an inference, not a documented recipe.
- **No SwiftPM-executable SwiftUI guidance** [run-1, minor, partial-log] — every quickstart routes through Xcode; running a `@main App` from an `executableTarget` (fast for headless/CI eval) is undocumented.
- **Hardcoded `llama3.2:3b` in §6** [run-1, papercut, partial-log] — doc pre-seeds a model the reader may not have pulled, with no "list your models" hint.
- **SwiftPM-executable window has no bundle identity** [run-3, papercut] — complicates `screencapture`/automation; a `MinimalExample` shipped as an `.xcodeproj` would smooth this.

## Positives (worth preserving)

- **SwiftUI persistence DX is genuinely polished** — run-4 verified same session UUID restored across quit+relaunch with no duplicate; run-3 kept persistence via the manual bootstrap path. This is a real strength.
- **BYO view-model binding shines** [run-3] — `chatVM.inputText = …; await chatVM.sendMessage()`, `chatVM.messages` directly `ForEach`-able, `@MainActor @Observable` view models bind idiomatically. ~80 lines for a working multi-session chat.
- **`docs/SWIFTUI-MULTI-SESSION.md` is otherwise high-quality** [run-2 positive, partial-log] — filename matched the task, covered bootstrap/sidebar/persistence/Foundation wiring; discoverability "effortless." The blocker is the one stale `DefaultBackends` recipe, not the doc's structure.

## Follow-up for next iteration

- Re-run run-1 (Ollama drop-in `ChatView`) and run-2 (Foundation) to completion — the drop-in `ChatView` path (the headline "easy mode") has **no completed data point** this iteration. Whether `ChatView` + `quickStart` compiles and runs end-to-end on v0.50.0 is currently unverified here.
