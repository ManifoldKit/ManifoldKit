# chat-cli archetype — post-fix rerun

**Date**: 2026-05-23 (post PR #1392 merge)
**MK version**: 0.33.0 + PR #1392 doc fixes
**Agent model**: Opus 4.7 (all 3 runs)
**App outcome**: 3/3 reached a working CLI on second-wake builds. Notably, **run-2 is the first agent in any session to actually load a local GGUF** (Qwen3-0.6B). It discovered the construction shape by reading `Tests/ManifoldInferenceTests/ModelLoadPlanTests.swift` — technically allowed by the brief (only `Sources/Manifold*/**` was off-limits), but the methodology now has a tightening to make: tests should also be off-limits for "public docs only" runs, since they routinely document the public surface that markdown doesn't.

## What the reruns proved

### F1 (`stream.events`) and F2 (Swift 6.2 floor) — gone

Across 6 friction entries written before stalls, **zero agents re-hit F1 or F2**. The PR #1392 doc fixes landed and are doing their job. Concordance on the fix == 3/3.

### F8 (NEW) — BYO-UI snippet needs `@MainActor` but isn't annotated [DOC-WRONG, major]

Run-1 (the one that completed) found this only after fixing F1 unblocked the next compile attempt: pasting the QUICKSTART BYO-UI snippet into a CLI `@main` entry point produces two Swift 6 errors — `register(with:)` and `generate(messages:...)` are main-actor-isolated. The snippet has no `@MainActor` annotation and gives no hint that the caller scope must be main-actor-bound. SwiftUI users never notice because `App.body` is already `@MainActor`.

**Fix**: Either annotate the snippet's enclosing scope (`@MainActor func run() async throws { ... }`) or add a one-line callout: "The BYO-UI surface is `@MainActor`-isolated — call from a main-actor context."

This is a textbook **next-layer-down** finding: F1 was hiding F8. The methodology surfaced it on the very next run after F1 landed — both completed reruns hit it. 2/2 concordance among runs that got past the build.

### F9 (NEW from run-2) — Two `loadModel(from:)` shapes with different parameter types [API-ERGONOMICS, major]

`InferenceService.loadModel(from: ModelInfo, plan:)` vs `BackendProtocol.loadModel(from: URL, plan:)`. Same name, two layers, different `from:` types. README's "Custom Backends" section documents the URL form (the protocol shape), so an agent following the README to load a model on the service ends up passing a `URL` to a method that wants `ModelInfo` and has to reconcile.

**Fix shape**: rename one of them, or document the layering explicitly in README ("the `URL` form is the backend-protocol contract; consumers call the `ModelInfo` form on `InferenceService` and `ModelInfo` wraps the URL").

### F10 (NEW from run-2) — SIGABRT on clean exit after `unloadModel()` [API-GAP / real bug, major]

This is not a docs bug, it's an actual defect. After `inference.unloadModel()` and program exit, the process aborts during `__cxa_finalize`:

```
ggml-metal-device.m:618: GGML_ASSERT([rsets->data count] == 0) failed
```

SIGABRT (exit 134). The user-visible output prints fine, but the process exits uncleanly. The Metal residency set still has entries when the C++ destructor for the device vector runs at process teardown. Agent worked around with a 500ms `Task.sleep` after `unloadModel`.

This is the most valuable finding from the entire walkthrough: a real Llama-backend teardown bug that internal tests don't catch because they don't exit the process. It deserves its own issue. **Suggested fix**: `unloadModel()` should block until the Metal residency drain completes, or `InferenceService` should expose an async `shutdown()` that does so explicitly.

### F4 escalation — blocker on macOS 15 (the n-1 floor MK officially supports)

Run-3 sharpened F4: with `.builtInFoundation` as the only working documented backend, **any evaluator on macOS 15 is blocked at the docs** — and macOS 15 is MK's stated n-1 platform floor per `CLAUDE.md`. The framework officially supports macOS 15, but its only documented working example requires macOS 26. That's a documentation-vs-stated-support-policy contradiction, not just a docs gap.

Bonus from same run: `generate(messages:)`'s real signature has 8 parameters (systemPrompt, temperature, topP, repeatPenalty, maxOutputTokens, maxThinkingTokens, jsonMode, …). The tuple-literal form works via bridging but the wider surface isn't documented. Minor on its own; corroborates F4.

### F3 (CLI is second-class) and F4 (backend factories) — now dominant

With F1 out of the way, the structural problems became the *first* thing every agent logged:

- 3/3 agents flagged within their first 1-2 entries: "the only BYO-UI snippet uses `.builtInFoundation` + `.cloud()` — no example of loading a local GGUF or pointing at Ollama"
- 3/3 agents pivoted to Foundation Models because it's the only documented backend, despite a brief explicitly offering Ollama + 11 local GGUF files

This is exactly what `ROOT_CAUSES.md` predicted: with the surface bugs fixed, the structural ones surface immediately. The two one-line fixes were necessary but not sufficient.

### New finding: F7 — first-build cold-time blows agent budgets

All 3 reruns stalled in `swift build` of their freshly-scaffolded consumer packages. The build wasn't broken — `swift-frontend` was actively compiling `swift-huggingface`, MLX, llama, etc. at the moment the agents hit their budget. Three parallel cold builds on one machine made it worse, but a single fresh consumer pulling MK's full transitive dependency set already approaches the 30-min limit on this hardware.

**This is the most consequential finding from the rerun.** For agents building apps with MK in the wild:

- Cold first build is multi-minute even on Apple Silicon
- Parallel runs (e.g. multiple worktrees, multiple agents) compound it
- A 30-minute budget is a thin margin for "scaffold + build + run + iterate"
- Agents that haven't seen the build complete will report "the framework is broken" or "I gave up" — false negatives in the DX walkthrough, real negatives in production

**Category**: API-ERGONOMICS / first-impression-cost
**Severity**: major

## Recommended fixes (updated, ranked)

1. **Tighten `no-build` policy + Swift floor lint** — *in progress*, dispatched as worker B
2. **First-class headless quickstart** — `docs/QUICKSTART-CLI.md` with full `Package.swift` + `main.swift`, compile-tested. Should include 2-3 backend variants (Foundation + Ollama + local GGUF) so backend-discoverability isn't dependent on guessing factory names. **Closes F3 + F4 in one move.**
3. **Document the cold-build expectation in README** — "First build pulls ~N transitive deps and takes ~T minutes; subsequent builds are cached." Sets expectations so an evaluator doesn't think the build hung. Doesn't fix F7 but blunts it.
4. **Investigate trait-gated minimal-deps profile** — can a CLI consumer opt out of MLX/llama via traits to get a faster cold build? If yes, document it loudly. This is the real structural fix for F7.

## Methodology note

The walkthrough methodology surfaced something it wasn't designed to test (F7, build-time DX). That's a feature of the constraint, not a bug — forcing an agent to actually build the app exposes friction that pure code review misses.

For future reruns:
- Increase budget to 45-60 min, OR
- Allow agents to use a warm MK build (i.e. seed `.build/checkouts/` from the repo's own resolved deps), OR
- Run reruns serially instead of parallel to avoid compounding cold-build contention

I'd recommend warming the build as the cleanest fix: it isolates "DX friction in the docs/API" from "MK has heavy deps." The latter is real but is a separate optimization track from documentation work.

## Verdict

PR #1392's two one-line fixes worked exactly as intended. The next leverage point is the structural CLI quickstart (item 2 above) — every rerun confirmed it's the biggest remaining DX gap. Worker B's `no-build` policy lint should land before drafting the CLI quickstart so the new content can't regress via the same `no-build` failure mode.
