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

`BFCL_v4_multiple` 25-case slice, two backends running the **same** llama3.1-8b:

| backend | ours AST | canonical AST | agreement |
|---|---|---|---|
| Ollama (llama-server, grammar-constrained) | 8/25 (32%) | 8/25 | 23/23 scored, **0 divergence** |
| companion `LlamaBackend` (direct llama.cpp + native template) | 16/25 (64%) | 17/25 | 24/25, **1 divergence** |

### Matcher is faithful

On the Ollama run, **every** one of the 15 wrong-argument fails is also a
`type_error:simple` under canonical BFCL — *including* the list-valued cases
(`multiple_10`, `multiple_23`) that were the prime over-strictness suspects: they
fail canonically too, because the model emitted *stringified* lists
(`"['email', 'social_security_number']"`) rather than real arrays. Zero
divergence. The earlier "~32–50%" hedge is resolved: it is **32%**.

The cross-check is sabotage-verified: feeding canonical a corrected integer-typed
variant of `multiple_1` correctly flips it to `WE-STRICTER` (`ours=False
canonical=True`), proving the harness detects divergence rather than agreeing
vacuously.

### One known matcher gap — nested objects

The single divergence across both runs is `multiple_8` on the `LlamaBackend` run:
the model emitted a **correct** nested object `budget:{min:300000, max:400000}`,
which canonical passes but our matcher fails — it compares the whole object as one
value and cannot unwrap BFCL's per-key accepted-value-list encoding
(`{max:[400000], min:[300000]}`). This is exactly the nested-object structural
matching `ASTMatcher` documents as deferred. Impact is small (1/25 here) and only
bites when a model emits nested-object arguments *correctly* — but it means our
score is a slight **lower bound** on backends good enough to produce them.

### Cross-backend finding

The same model scores **32% (Ollama) vs 64% (`LlamaBackend`)** purely on backend
tool-call handling: Ollama's grammar-constrained path stringifies numerics
(`{"a":"5"}`), which fail BFCL's type check, while the native-template
`LlamaBackend` preserves them (`{"a":5}`). This is the kind of backend-robustness
gap a name-only scorer renders completely invisible — and the reason the
argument-level scorer earns its keep. The `LlamaBackend` numbers were produced by
`manifold-tools-llama bfcl` in the companion repo (driver pending a release-gated
PR); reproduce with the same `--dump` + cross-check flow.

### MLX — a third failure mode (generation-termination, not arguments)

Run via `manifold-tools-mlx bfcl` (companion, `Llama-3.2-3B-Instruct-4bit`), MLX
exposed something neither Ollama nor llama did: on `multiple`, **21/25 cases never
emitted a stop token** and hit the per-case timeout; the **4 that completed were
all argument-correct** (4/4, canonical-confirmed). On `simple` the hangs were
intermittent (2/8 one run, 0/8 another). So MLX's low score here is a
*generation-termination* pathology, **not** wrong arguments — and the per-case
timeout (now in `BFCLRunner`) is what lets the harness produce a number at all
instead of hanging indefinitely. The lesson: an argument-level scorer plus a
per-case timeout separates "can't form the call" from "won't stop generating" —
two failure modes a name-only pass/fail collapses into one.

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
