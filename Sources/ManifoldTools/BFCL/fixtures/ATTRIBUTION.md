# BFCL fixtures — attribution & provenance

These fixtures exercise the **argument-level** tool-call scorer (`ASTMatcher`),
the axis the name-only `ConformanceScorer` is blind to.

## Vendored slices

### `multiple` — real BFCL data (the one we evaluate against)

`multiple_questions.jsonl` / `multiple_answers.jsonl` are a **verbatim contiguous
subset (first 25 cases) of upstream `BFCL_v4_multiple`** (Apache-2.0), fetched
from the gorilla repo. Each case advertises several candidate functions (mostly
dot-namespaced, e.g. `triangle_properties.get`) of which exactly one is correct —
so it exercises **function selection among distractors *and* argument
correctness**, which is where capable models actually trip. This is the slice the
`manifold-tools bfcl` demonstration scores by default.

No transformation was applied beyond selecting the first 25 id-aligned records;
the question/function/ground_truth content is upstream verbatim.

### `simple` — illustrative, hand-authored

A small `simple`-category slice authored in the **exact on-disk format** of the
Berkeley Function Calling Leaderboard (BFCL):

- `simple_questions.jsonl` — one case per line: `{ id, question, function }`,
  where `function` is an OpenAI-style schema using BFCL's `"type":"dict"` spelling.
- `simple_answers.jsonl` — the parallel `possible_answer` file: one line per id,
  `{ id, ground_truth: [{ functionName: { param: [accepted, values…] } }] }`.

The two files are keyed by a shared `id` and must stay in lockstep
(`BFCLCaseLoader` throws if a question has no matching answer).

## Provenance — read this

The **`multiple`** slice is upstream BFCL data verbatim (Apache-2.0). The
**`simple`** slice is **illustrative and hand-authored** in BFCL's format — not a
verbatim copy — and exists only to validate the easy path; its per-case numbers
are not leaderboard scores.

**Follow-on (deferred):** vendor the remaining categories (`parallel`,
`parallel_multiple`, harder `live_*`) — note `parallel*` needs multi-call scoring
(every ground-truth call matched), which `ASTMatcher.scoreCase` does not yet do —
and cross-check this Swift `ASTMatcher` once against canonical `bfcl-eval` to
confirm the two scorers agree on the same transcripts.

## Upstream

- Dataset & scorer: <https://github.com/ShishirPatil/gorilla> (Apache-2.0)
- Dataset mirror: <https://huggingface.co/datasets/gorilla-llm/Berkeley-Function-Calling-Leaderboard>
- Leaderboard: <https://gorilla.cs.berkeley.edu/leaderboard.html>

BFCL conventions reproduced here: a per-parameter **list** of accepted values
(any one is correct), and the empty string `""` in an accepted-value list as the
**"optional / may be omitted"** marker.
