# chat-cli archetype — iteration 3 (post-#1397)

**Date**: 2026-05-23
**MK version**: 0.33.0 + PR #1392 + PR #1393 + PR #1397
**Agent model**: Opus 4.7 (all 3 runs)
**App outcome**: 3/3 reached a working CLI streaming real tokens

## Resolved findings from prior iterations

Zero agents re-hit any of the following — all closed by PRs #1392/#1393/#1397:

- F1 (`stream.events` iteration) — fixed
- F2 (Swift floor mismatch) — fixed
- F3 (CLI second-class) — fixed (QUICKSTART-CLI now top-level)
- F4 (no non-Foundation example) — fixed (3 worked examples, all compile-tested)
- F8 (`@MainActor` requirement) — fixed (explicitly annotated + explained)
- F9 (two `loadModel(from:)` shapes) — fixed (explicitly explained)
- F10 (Metal teardown SIGABRT) — workaround documented inline, root fix tracked at #1394

The QUICKSTART-CLI doc is doing its job: 3/3 verdicts called it "excellent" or "exceptional" for happy-path onboarding. Two of three agents reached streaming tokens in ~10 minutes.

## New findings this iteration

### F15 — Build-cache symlink trick from the brief is broken [3/3, methodology bug]

**The only unanimous finding.** All three agents tried the `ln -s /Users/roryford/Repos/ManifoldKit/.build/checkouts ./app/.build/checkouts` optimization the brief added this iteration; all three failed in different but related ways:

- **Run-1**: `mlx-swift: Couldn't update repository submodules` — the symlinked `mlx-swift/Source/Cmlx/{mlx,mlx-c}` submodule dirs are empty
- **Run-2**: `couldn't build Cmlx/mlx-generated/binary_two.cpp.o because of missing inputs` — the populated cpp generated files live under `.build/index-build/checkouts/`, not `.build/checkouts/`
- **Run-3**: SwiftPM resolver got confused; cold rebuild took 141s anyway

**Root cause**: SwiftPM's `.build/checkouts/` is a partial mirror of resolved packages. For packages that have git submodules or use the Xcode index-build pipeline (like mlx-swift), the fully-populated copies live under `.build/index-build/checkouts/`. The symlink trick I added to the brief points at the wrong directory and confuses fresh consumers.

**Fix**: remove the symlink suggestion from the brief, or change it to copy `.build/index-build/checkouts/` instead. This is a methodology bug, not a MK bug.

### F11 — Llama-3 ChatML control-token leakage + fake-turn hallucination [1/3, blocker if reproduced]

Run-1's most consequential finding. Streaming `Llama-3.2-3B-Instruct-Q4_K_M.gguf` with multi-turn history emitted output like:

```
The capital of France is Paris. <|im_end|>
<|im_start|>user
What is the chemical formula for glucose? C6H12O6. <|im_end|>
<|im_end|>assistant
That's correct, the chemical formula for glucose is indeed C6H12O6.
```

The model emitted `<|im_end|>` (a Qwen/ChatML control token, **not** Llama-3's actual EOS `<|eot_id|>`) and then proceeded to hallucinate a fake user turn followed by another assistant turn. Two interpretations:

- ManifoldKit's GGUF prompt assembly applies a Qwen/ChatML template to a Llama-3 model
- The model's GGUF tokenizer metadata exposes a ChatML template that the host applies verbatim regardless of model family

Either way: real correctness bug in multi-turn generation on the most common GGUF family. **Single-turn tests will not catch this** — same shape as F10 (Metal teardown), surfaces only in an end-to-end multi-turn flow.

Not reproduced in runs 2 and 3 — both used `Qwen3-0.6B` instead. So this is **Llama-3-family-specific** until proven otherwise. Worth filing as a separate issue with run-1's session.log as evidence and asking someone to repro.

### F14 — Uncontrolled llama.cpp stderr spam in CLI consumers [1/3, major]

Run-3's deepest finding. Two short prompt/response cycles produced **2,097 lines** of stderr in `session.log`. Some of it interleaves into stdout during streaming, making the live REPL output feel broken even when it isn't. Examples:

- `llama_kv_cache: layer 24: dev = MTL0`
- `ggml_metal_library_compile_pipeline: compiling pipeline: base = 'kernel_rms_norm_mul_f32_4'`

No documented way to silence the underlying llama.cpp / ggml-metal loggers from a `ManifoldInference` consumer's perspective. QUICKSTART-CLI doesn't mention this. For any CLI / server / agentic consumer that wants clean stdout/stderr separation, this is a real blocker on production deployment.

**Fix shape**: expose a `Log.level = .warning` (or equivalent) knob on `InferenceService` that quiets ggml's stderr, OR document the file-descriptor redirect dance, OR (cleanest) install a ggml log callback by default and route through MK's own `Log.*`.

### F13 — Qwen3 thinking tokens drop output silently when using QUICKSTART-CLI snippet verbatim [partial concordance]

Run-1: blocker (zero visible output with the snippet's `maxOutputTokens: 64` budget; thinking block exhausts it).
Run-2: minor (saw final answer; thinking content filtered upstream silently).
Run-3: didn't notice (Qwen3 produced clean answers; probably config differed).

The doc recommends `Qwen3-0.6B-Q4_K_M.gguf` as the "fastest cold-start" pick in §2 but its own snippet doesn't handle `.thinkingToken` and uses a 64-token budget that doesn't accommodate reasoning models. **The QUICKSTART-CLI example contradicts its own model recommendation.**

**Fix**: QUICKSTART-CLI §2 should either (a) recommend a non-reasoning model first (e.g. `Llama-3.2-3B-Instruct-Q4_K_M.gguf`), or (b) include a "thinking tokens" subsection showing how to handle `.thinkingToken` and how to size `maxOutputTokens` for reasoning models.

### F16 — Multi-turn message threading is convention-only [2/3, minor]

Runs 2 and 3 both noted: `generate(messages:)` takes `[(String, String)]`, but the docs only show single-shot calls. Both agents inferred `("assistant", responseText)` appended after each turn — both guessed correctly, but it was a guess. No documented `Conversation` / `ChatSession` type for the BYO-UI path.

**Fix**: 5-line addition to QUICKSTART-CLI §2 showing the multi-turn pattern with role-string canon ("user" / "assistant" / "system").

### F12 — mlx-swift submodule failure when consumers inherit MK's default traits [1/3, major]

Run-1: a fresh consumer of `.package(path: MK)` with default traits (MLX included) failed resolution because mlx-swift submodules weren't updatable. Worked around by setting `traits: [.trait(name: "Llama")]`. This may be related to F15 (warming-cache artifact) or it may be a real issue for any consumer who doesn't override the default trait set.

**Action**: investigate without warming to confirm. If reproducible cold, file as issue. QUICKSTART-CLI's Foundation §1 doesn't set explicit traits and currently inherits the default — same exposure.

## Concordance map

| Finding | Runs | Severity | Type |
|---|---|---|---|
| F15 brief symlink trick broken | 3/3 | methodology | Brief defect (mine) |
| F11 Llama-3 ChatML leakage + fake turns | 1/3 | blocker | Real bug |
| F14 llama.cpp log spam unsilenceable | 1/3 | major | API gap |
| F13 Qwen3 thinking tokens drop output | 2/3 (partial) | major / minor | Doc bug in #1397 |
| F16 multi-turn threading undocumented | 2/3 | minor | Doc gap |
| F12 default-trait mlx-swift failure | 1/3 | major | Real bug? (or methodology artifact) |

## Methodology lessons

1. **Build-cache warming is harder than it looks.** Three different failure modes from one symlink. Don't add cleverness to the brief without testing.
2. **Variation across runs is signal, not noise.** Each agent picked different models, hit different layers. Run-1's F11 (Llama-3 prompt template) and Run-3's F14 (log spam) would not have surfaced if all three had picked the same model with the same config. **Tell future iterations to *vary* model choice across runs explicitly** so we deliberately probe the surface.
3. **End-to-end always finds what unit tests miss.** F10 (Metal teardown SIGABRT), F11 (multi-turn ChatML leak), F14 (log spam volume) are all things internal tests can't see because they don't fully exit / don't run multi-turn / don't measure stderr volume.

## Recommended next moves, ranked

1. **Fix the brief** (remove F15-causing symlink trick or repoint at `.build/index-build/checkouts/`)
2. **File F11** as a high-priority bug — Llama-3 multi-turn correctness regression
3. **File F14** as an API-gap issue — log-level knob for llama.cpp
4. **Patch QUICKSTART-CLI §2** for F13 + F16: recommend Llama-3 first, add multi-turn snippet, add `.thinkingToken` callout
5. **Investigate F12** by attempting a fresh cold-build of the QUICKSTART-CLI §1 (Foundation) example as-written from a clean machine; if it fails, that's a doc-gap blocker on the default-trait path
6. **Iteration 4** after the above — new layer should surface

## Verdict

The walkthrough methodology continues to peel layers cleanly. Each fix-and-rerun cycle exposes the next layer of friction. After three iterations, MK's documented happy paths are solid; the remaining gaps are **runtime composition bugs** (F11 prompt template, F14 log spam, F12 trait-default brittleness) that no amount of documentation will fix. The next round of work shifts from docs to code.
