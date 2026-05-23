# chat-cli archetype — iteration 4 (post-#1401)

**Date**: 2026-05-23
**MK version**: 0.33.0 + PR #1392 + PR #1393 + PR #1397 + PR #1401
**Agent model**: Opus 4.7 (all 3 runs)
**App outcome**: **3/3 reached working CLIs first try, no second wakes needed**

This is the first iteration where every run succeeded on the first attempt against three different backend paths.

## Backend coverage this iteration

Per the methodology lesson from iter-3 (variation across runs is signal), each agent was steered to a deliberately different surface:

| Run | Path | Time to working CLI | Cold build |
|---|---|---|---|
| 1 | §2 Llama-3.2-3B-Instruct | ~5 min after build | 234s |
| 2 | §2 Qwen3-0.6B (reasoning) | ~5 min after build | 252s |
| 3 | §3 Ollama (`llama3.1:8b`) | ~5 min after build | not measured |

All three verdicts called QUICKSTART-CLI "excellent" / "best-in-class" / "model of how to write a multi-backend quickstart."

## Closed findings

Zero re-hits of F1, F2, F3, F4, F8, F9, F13, F15, F16. Confirmed fixes:

- **F13 reasoning models** → Run-2 (Qwen3) followed the new "Reasoning models" subsection and got it working. The doc's guidance is functional.
- **F16 multi-turn threading** → Run-1 (Llama-3) used the new "Multi-turn conversations" subsection unchanged. Worked.
- **F15 brief symlink trick** → removed from the brief; no agent attempted it; cold builds completed in ~4 minutes anyway.

## Confirmed known issues

These reproduced as expected — the doc callouts warned the agents:

- **#1398 Llama-3 ChatML leak** → Run-1 turn-2 emitted `Red, Blue, Yellow.<|im_end|>\n<|im_start|>user\nWhat is the largest planet in our solar system?...` and hallucinated a third turn (Jupiter). The QUICKSTART callout I added in #1401 worked: the agent flagged it as "documented multi-turn issue #1398, ... honest credit: I was warned."
- **#1399 GGML/Metal stderr spam** → Run-1 hit it on first generation (kernel compile lines interleaving with `Paris` mid-stream). Now logged as a major finding in iter-4 too. Worth adding a callout in QUICKSTART-CLI §2 like the one for #1398, since #1399's fix may take longer.

## New findings (all papercut/minor)

### F22 — `.package(path:)` developer form not in QUICKSTART [3/3, papercut]

**The only unanimous finding.** All three agents had to bridge the brief's `.package(name: "ManifoldKit", path: ...)` form to the QUICKSTART's `.package(url:, from:)` form themselves. None of them had trouble doing the swap, but a one-line "evaluating locally? use `.package(name:"ManifoldKit", path:"/path/to/ManifoldKit")`" callout in QUICKSTART would eliminate the small dance.

This is *almost* a methodology bug (the brief forces a path-based dep) — but since path-based dependencies are also the natural shape for anyone evaluating MK pre-release or developing against a local checkout, it's still worth documenting.

### F21 — MK-internal deprecation warnings reach consumers [2/3, papercut]

Both run-2 and run-3 saw warnings during their first build:

- `MLX.GPU.set(cacheLimit:)' is deprecated` (in `MLXBackend` or similar)
- `'init(urlSession:)' is deprecated. ... add the Ollama trait to package dependencies` (in `ManifoldBackendsUmbrella/CloudBackends.swift`)
- `default will never be executed` (in `DefaultBackends.swift`)

The Ollama-trait warning is the most problematic: it fires for consumers who **are already using the Ollama trait**, so it looks like the user did something wrong when they didn't. Run-3: *"From a new consumer's perspective this looks like I'm doing something wrong."*

**Fix shape**: gate these deprecations behind `#if` traits so they only fire on direct usage, OR resolve the deprecations internally so they stop appearing at consumer build time.

### F20 — "Reasoning models" snippet I shipped in #1401 has a visual bug [run-2, papercut]

The doc-suggested handler emits `"[thinking] \(text)"` per **token**, producing `[thinking] Okay[thinking] ,[thinking]  the[thinking]  user...` in stderr. Functionally correct but visually noisy. A first-time reader copying the snippet won't realise until they run it.

**Fix**: track an `inThinking` flag and only emit `[thinking] ` on transitions from `.token` → `.thinkingToken`. One-line change to QUICKSTART-CLI §2's reasoning-models subsection.

### F19 — §3 `modelName: "llama3.2"` is a placeholder without a swap-this hint [run-3, papercut]

QUICKSTART-CLI §3 uses `modelName: "llama3.2"` but on most machines that exact tag isn't pulled. A `// swap this for an entry from `ollama list`` comment would prevent the copy-paste-then-confused experience.

### F18 (Run-3, methodology) — Brief↔doc form mismatch is the same as F22

Already covered above.

## Concordance map

| Finding | Runs | Severity | Action |
|---|---|---|---|
| F22 `.package(path:)` doc gap | 3/3 | papercut | One-line doc add |
| F21 MK-internal warnings leak | 2/3 | papercut | Source-side cleanup |
| F20 thinking-token snippet visual bug | 1/3 | papercut | One-line doc fix |
| F19 modelName placeholder | 1/3 | papercut | One-line doc comment |
| #1398 known issue confirmed | 1/3 | major (filed) | Wait for fix |
| #1399 known issue confirmed | 1/3 | major (filed) | Wait for fix |

## The categorical shift

Iter-3 predicted: "The remaining gaps are runtime composition bugs (F11 prompt template, F14 log spam, F12 trait-default brittleness) that no amount of documentation will fix. The next round of work shifts from docs to code."

Iter-4 confirms it. All new findings this round are either:

- **Papercuts** (F19, F20, F22) — small doc additions
- **Source-side cleanup** (F21) — internal warnings reaching consumers
- **Confirmed known issues** (#1398, #1399) — already filed, code fixes pending

**The documentation surface is now done.** Four iterations took it from "broken hello-world snippet" → "best-in-class quickstart" with 3/3 first-try success rate. The walkthrough's remaining utility is in **regression detection** (catching when a future change breaks the documented happy paths) and in **new archetypes** (SwiftUI, agentic) that exercise different surfaces.

## Diminishing returns from this archetype

Iteration deltas:

| Iter | Working CLIs | New blockers | New majors | Papercuts |
|---|---|---|---|---|
| 1 (baseline) | 3/3 | 0 | 2 (F1, F4) | 4 |
| 2 (post #1392) | 2/3* | 1 (F4 → blocker) | 2 (F8, F9) | 3 |
| 3 (post #1393, #1397) | 3/3 | 1 (F11) | 3 (F12, F13, F14) | 2 |
| 4 (post #1401) | 3/3 first-try | 0 | 0 (all new = papercut) | 4 |

The signal is converging. Future iterations of *this* archetype will produce mostly noise unless something new lands in MK that breaks a documented path.

## Recommended next moves

### Cheap and useful (~30 min total)
1. **Bundle F18/F19/F20/F22 into one tiny doc PR** — four one-line additions to QUICKSTART-CLI: `.package(path:)` callout, `modelName` swap-this comment, thinking-token `inThinking` flag fix, #1399 stderr callout. All papercut-level, all fast.

### Worth doing eventually (deferred)
2. **F21 internal-warning hygiene** — source-side work to resolve or trait-gate the deprecation warnings so they stop reaching consumers. Probably one or two small PRs.

### Bigger lift (different archetype)
3. **Move to archetype 2 (SwiftUI chat with persistence)** — different surface, will surface different bugs. The chat-cli archetype has converged.

### Walkthrough lifecycle
4. **Make this archetype a periodic regression check** — re-run quarterly (or pre-release) to catch when a refactor breaks the documented happy paths.

## Verdict

The chat-cli walkthrough did its job. 4 iterations, 12 agent runs, 22 catalogued findings, 4 merged PRs, 2 filed bugs. From "broken hello-world snippet" to "best-in-class quickstart" with 3/3 first-try success and zero new blockers in iter-4.

**Methodology proven, archetype exhausted.**
