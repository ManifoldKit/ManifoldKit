# BFCL matcher calibration — canonical `bfcl-eval` cross-check

This directory holds a **one-time, local-only** cross-check of the Swift
`ASTMatcher` against the canonical Berkeley `bfcl-eval` scorer. It is **excluded
from the SwiftPM build and never wired into CI** (see the `exclude:` entry on the
`ManifoldTools` target in `Package.swift`) — the spike's value proposition is a
pure-Swift, zero-CI-Python evaluator. This Python exists only so the load-bearing
claim below can be reproduced by a skeptic.

## The question it answers

Our `manifold-tools bfcl` run reports an argument-level score far below the
name-only score (8/25 vs 23/25 for `llama3.1-8b` on `BFCL_v4_multiple`). Is that
gap *real model behaviour*, or is our matcher simply stricter than canonical BFCL
on edge cases (string-vs-int, list ordering, nested objects)? The cross-check
feeds canonical `ast_checker` **the exact calls our matcher already decoded**, so
any disagreement isolates *matcher strictness* from parser differences.

## Recorded result (2026-06-27, `bfcl-eval` 2025.8.6.2)

`llama3.1-8b:latest` via local Ollama, `BFCL_v4_multiple` 25-case slice:

| | ours | canonical |
|---|---|---|
| AST pass (of 23 scored) | 8 | 8 |
| Agree pass | 8 | |
| Agree fail | 15 | |
| **We stricter** (canonical passes, we fail) | **0** | |
| **We looser** (we pass, canonical fails) | **0** | |

**100% agreement — zero divergence.** Every one of the 15 wrong-argument fails is
also a `type_error:simple` under canonical BFCL, *including* the list-valued cases
(`multiple_10`, `multiple_23`) that were the prime suspects for over-strictness:
they fail canonically too, because the model emitted *stringified* lists
(`"['email', 'social_security_number']"`) rather than real arrays. The two
backend-errored cases (`multiple_7`, `multiple_24`) are fails under both scorers,
so the headline **8/25 = 32%** stands, calibrated. The earlier "~32–50%" hedge is
resolved: it is **32%**, and the matcher is faithful.

The cross-check was sabotage-verified: feeding canonical a corrected
integer-typed variant of `multiple_1` correctly flips it to `WE-STRICTER`
(`ours=False canonical=True`), proving the harness detects divergence rather than
agreeing vacuously.

## Faithfulness caveat

Our Ollama backend emits **JSON** tool calls, which we decode with `JSONDecoder`;
canonical BFCL's own decoder would produce the same `str`/`int` distinction from
the same JSON, so feeding our decoded dicts is faithful for this backend. A model
whose decoder does `ast.literal_eval` on Python-style call strings could coerce
types differently — out of scope here.

## Reproduce

```bash
# 1. Scratch venv (NOT in the repo) — pulls the canonical scorer + its deps.
python3 -m venv /tmp/bfcl-venv
/tmp/bfcl-venv/bin/pip install bfcl-eval soundfile   # soundfile satisfies a qwen_agent import

# 2. Capture a live run from the Swift harness.
swift run manifold-tools bfcl --category multiple --model llama3.1-8b:latest \
    --dump /tmp/run.jsonl

# 3. Cross-check the decoded calls against canonical bfcl-eval.
F=Sources/ManifoldTools/BFCL/fixtures
/tmp/bfcl-venv/bin/python Sources/ManifoldTools/BFCL/calibration/bfcl_crosscheck.py \
    --dump /tmp/run.jsonl \
    --questions $F/multiple_questions.jsonl \
    --answers   $F/multiple_answers.jsonl
```

Note the model is nondeterministic run-to-run, so absolute counts vary slightly;
the **agreement rate** (which is what this validates) is the stable quantity.
