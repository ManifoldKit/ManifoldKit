# Prompt/template render-path fidelity (Opportunity 1, slices A+B)

_Scoped 2026-06-20. Tracks the render-path consolidation surfaced by the open-issue
cluster #1961 / #1909 / #1938 / #1944 / #1932 / #1957-Tier3._

## Problem

ManifoldKit renders a chat prompt for prompt-template backends through two paths with
**different capabilities**, and silently degrades between them:

- `JinjaPromptRenderer` (the model's real embedded GGUF `chat_template`) — threads
  `tools`, `tool_calls`, `tool_call_id`; hard-codes `documents: []`; drops `.image`/`.audio`.
- `PromptTemplate` enum fallback via `GenerationHistoryInstaller.flatten()` — text-only
  `(role, textContent)`; renders tools only for `.gemma4`.

`PromptRenderer.render()` picks Jinja-first, enum-fallback. The degradation is silent in
the cases that matter:

| Transition | Logged today? | Consequence |
|---|---|---|
| Jinja `throw` (malformed template) | yes (`JinjaPromptRenderer.swift` catch) | falls to enum, tools may vanish |
| Jinja **empty output** → nil | **no** | falls to enum |
| Jinja nil → enum fallback **with non-empty tools** | **no** | tools silently dropped → ~0% tool-calling |
| `.image` parts on **either** path | **no** | vision-template placeholders never render |

So "tool-calling rate is 0% on model X" (the #1961/#1909 shape) keeps recurring one model
at a time: nothing fails loudly when capability is lost, and nothing locks the rendered
bytes against drift.

## In scope (this work)

### Slice A — fail-loud on capability loss
Make the silent degradations observable, **without changing the rendered prompt**:
- `PromptRenderer.render()`: when Jinja returns nil **and** `!tools.isEmpty` **and** the
  enum fallback is not `rendersToolsNatively`, emit `Log.inference.warning` naming the
  count of tool definitions that will not render.
- Warn once when messages carry `.image`/`.audio` parts that neither path will render.
- `JinjaPromptRenderer`: log the empty-output miss (today only the `catch` logs).

### Slice B — byte-match golden tests (#1938)
Lock the already-shipped #1909 fix and catch future drift. Today
`JinjaPromptRendererTests` only asserts `rendered.contains(...)` against **synthetic**
templates; there are zero byte-exact goldens.
- `Tests/ManifoldInferenceTests/Fixtures/ChatTemplates/`: real embedded `chat_template`
  strings for 4 in-use families (Qwen2.5, Llama-3.2, a native-tool template, Mistral) +
  golden rendered outputs for canonical conversations (text; user+assistant+tool turn;
  tools-declared turn).
- Oracle of record: `transformers.apply_chat_template` output, committed as the golden.
  `regenerate.py` documents/automates regeneration (run via `uv`, no test-time Python dep).
- Test asserts `XCTAssertEqual(render(...), golden)` exact. Sabotage check perturbs one
  golden by a single special token to prove it is not a `contains`-style false pass.

### Bug found by Slice B — `trim_blocks` / `lstrip_blocks` whitespace drift
The byte-match goldens immediately caught a production fidelity bug:
`JinjaPromptRenderer` constructed `Template(trimmed)` with swift-jinja's default
options, where `lstripBlocks` and `trimBlocks` both default to **false**. But
`transformers.apply_chat_template` — the renderer every GGUF's `chat_template`
was authored/trained against — always uses `trim_blocks=True, lstrip_blocks=True`.
So any template relying on block trimming (the Hugging Face default, common in
real templates) was rendered by MK with spurious newlines/indentation the model
never saw. Templates using explicit `{%-`/`-%}` controls (Qwen2.5, Llama-3.2)
were unaffected, which is why it went unnoticed. Fix: construct
`Template(trimmed, with: .init(lstripBlocks: true, trimBlocks: true))`. This is
the kind of silent drift Slice B exists to surface — it paid for itself on the
first run.

## Explicitly out of scope (deferred, separate issues)

- **Slice C — thread images + RAG `documents` through Jinja.** Renderer feature work that
  overlaps vision (#1710) and RAG. Slice B leaves `XCTExpectFailure`-wrapped tests (with a
  `// FIXME:` issue link) documenting the gap; threading lands in its own issue.
- **Slice D — typed `Template` owning formatting + stop sequences (#1944).** Stop sequences
  are modeled nowhere in core today (no `GenerationConfig`/`PromptTemplate` field; backends
  infer them internally). Owning them in a typed `Template` means a contract change honored
  by every backend incl. companion manifold-mlx / manifold-llama — a `feat!:` across 3
  repos. Blocked on a stop-sequence-contract decision; start only after A+B land so the
  byte goldens give the rewrite a safety net.

## Sequencing

A and B ship as **one core-only PR** (same files/tests; B without A leaves degradation
silent, A without B leaves it unlocked). No contract change, no companion-repo blast radius.

## Key file map (verified 2026-06-20)

| Component | Location |
|---|---|
| `PromptRenderer.render()` | `Sources/ManifoldInference/Services/PromptRenderer.swift:134-153` |
| `JinjaPromptRenderer.render()` / nil branches | `Sources/ManifoldInference/Services/JinjaPromptRenderer.swift:70,104,105-113` |
| `jinjaMessage` (drops .image/.audio) | `JinjaPromptRenderer.swift:118-157` |
| `flatten()` (text-only projection) | `Sources/ManifoldInference/Services/GenerationHistoryInstaller.swift:14-16` |
| `PromptTemplate.rendersToolsNatively` | `Sources/ManifoldHardware/PromptTemplate.swift:73-78` |
| Render callers (hot path) | `GenerationQueue.swift:505`, `GenerationPreflightTrimmer.swift:74` |
| Existing tests (contains-only) | `Tests/ManifoldInferenceTests/JinjaPromptRendererTests.swift` |
