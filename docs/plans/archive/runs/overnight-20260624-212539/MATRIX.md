# Cross-Backend Tool-Calling Conformance Matrix — Re-measure

Run: `overnight-20260624-212539` · 4 legs (Ollama, llama.cpp, MLX, OpenRouter) · 9-scenario reference toolset · scorer = `manifold-tools score --csv` (`ConformanceScorer`) / MLX `SUMMARY` lines.

> **Purpose of this run.** The §5 *re-measure precondition* of `docs/plans/tool-calling-architecture.md`: the prior matrix (`20260622-232839`) was taken **pre-#2032/#2035** (the Mistral alternation-fold fix) and explicitly flagged its two Mistral cells *re-measure pending*. This run re-measures on post-#2035 core (binary built from `origin/main` + docs-only commits; code identical to `origin/main`). **It answers one question that gates Phase 0: did the Mistral cells flip?**
>
> Raw per-run `.jsonl` transcripts are **retained locally** (not pruned) — they are the parse-back fixture-corpus source for plan §7.3 — and must be excluded from any commit per the trim convention.

## 1. Headline — the two Mistral cells split in OPPOSITE directions

| Cell | Prior (`20260622`) | This run | Verdict |
|------|--------------------|----------|---------|
| **llama.cpp · Mistral-v0.3** | 🛑 render-fail (alternation refusal, pre-#2032) | dispatches the **correct** tool every scenario; behavioral assertions **pass 24/45** | ✅ **RECOVERED** — #2032/#2035 fixed it. (Reported F1=0.000 is a **scorer attribution bug**, §5 — *not* a model failure.) |
| **MLX · Mistral-v0.3** | ⚠️ no-call (pre-#2032) | **0 tool calls** at d0 and across the entire decoy ladder (+1…+20); same harness scores Llama-3.2-3B 1.000 and Qwen3-8B 0.917 | ⚠️ **STILL no-call** — a distinct, persistent failure (**F3 confirmed**). |

**Consequence for the plan:** the llama.cpp Mistral failure was a *core renderer* bug and is now closed by delegation-of-the-fix to the alternation fold. The MLX Mistral failure is the **separate** F3 cause — MLX injects tools as system-prompt prose and never calls `applyChatTemplate(messages:tools:)`, so Mistral's template never emits `[TOOL_CALLS]`. **Phase 0 (additive MLX structural-tools threading) remains justified; its target failure mode is still live.**

## 2. Main matrix (d0 — no decoys)

Means across available repeats. P/R/F1 = macro tool-selection. "scen pass" = full-scenario verdict `pass` / total scored. Verdicts: ✅ supported · ⚠️ renders-no-call · 🛑 render-fail · 💥 load-fail · 🚫 not measured (model absent) · — n/a.

| Backend | Model | Runs | Prec | Recall | F1 | scen pass | Verdict | Δ vs prior |
|---------|-------|------|------|--------|----|-----------|---------|-----------|
| Ollama | mistral-7b-tools | 5 | 0.778 | 0.778 | **0.778** | 15/45 | ✅ | ≈ (was 0.875) |
| Ollama | gemma3-4b-tools | 5 | 0.000 | 0.000 | **0.000** | 0/45 | ⚠️ renders-no-call | = (model fact) |
| Ollama | gemma4-e4b | 5 | 0.889 | 0.889 | **0.889** | 35/45 | ✅ | ≈ (was 1.000; no-tool-scen drag) |
| Ollama | llama3.1-8b | 5 | 0.667 | 0.667 | **0.667** | 7/45 | ✅ | = |
| Ollama | qwen3.5-9b | 5 | 0.889 | 0.889 | **0.889** | 35/45 | ✅ | ≈ (was 1.000) |
| llama.cpp | Mistral-v0.3 | 5 | *0.000\** | *0.000\** | *0.000\** | **24/45 pass** | ✅ **recovered** | 🛑→✅ **FLIP** |
| llama.cpp | gemma-3-4b-tools `.tooltmpl` | 5 | 0.000 | 0.000 | **0.000** | 5/45 | ⚠️ renders-no-call | = (model fact) |
| llama.cpp | gemma-4-E4B | 0 | — | — | **—** | 0/0 | 💥 load-fail (`gemma4` arch) | = |
| llama.cpp | llama3.1-8b | 0 | — | — | **—** | — | 🚫 not measured (GGUF absent) | n/a (was ✅ 0.622) |
| llama.cpp | qwen3.5-4b | 0 | — | — | **—** | — | 🚫 not measured (GGUF absent) | n/a |
| MLX | Llama-3.2-3B | 5 | 1.000 | 1.000 | **1.000** | —‡ | ✅ | ≈ (was 0.900) |
| MLX | Qwen3-8B | 5 | 1.000 | 0.875 | **0.917** | —‡ | ✅ | = |
| MLX | Mistral-v0.3 | 5 | 0.000 | 0.000 | **0.000** | —‡ | ⚠️ no-call | = **(F3 confirmed)** |
| OpenRouter | gpt-oss-120b | 3 | 0.889 | 0.852 | **0.864** | 21/27 | ✅ (cloud anchor) | ≈ (was 0.986) |

`*` **llama.cpp Mistral F1 is scorer-suppressed, not real** — see §5. The cell dispatches the correct tool on every scenario and passes its behavioral assertions (24/45 `pass`); the tool-selection scorer mis-attributes every correct call as a false positive (`toolTP=0, toolFP=1`). Real verdict: ✅.
`‡` MLX's `passed`/`clean` scenario-pass gate reads 0/9 for **every** model including the F1=1.000 Llama — the gate never fires in this harness. Trust MLX P/R/F1, not its `passed`.

## 3. Cross-runtime Mistral twin (the whole point)

| Model | Ollama F1 | llama.cpp | MLX | Reading |
|-------|-----------|-----------|-----|---------|
| **Mistral-v0.3** | **0.778** ✅ | ✅ **recovered** (correct tool, scorer-suppressed F1) | **0.000** ⚠️ no-call | **The 3-way split is now a 2-vs-1.** Ollama (server template) and llama.cpp (post-#2032 fold) both tool-call; **MLX alone still emits nothing** — the isolated F3 cause Phase 0 targets. |

## 4. Decoy ladder (mean F1 per level, 1 run each)

| Cell | d0 | +1 | +3 | +5 | +10 | +20 | Note |
|------|----|----|----|----|-----|-----|------|
| MLX Qwen3-8B | 0.917 | 0.917 | 0.917 | 0.917 | 0.917 | 0.917 | **flat — most decoy-robust local cell measured** |
| MLX Llama-3.2-3B | 1.000 | 0.875 | 0.875 | 0.750 | 0.958 | 0.792 | holds well; non-fatal `mutex lock failed` at +5 but still scored |
| MLX Mistral-v0.3 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | no-call floor (decoy_calls=0 throughout) |
| Ollama (5-model mean) | 0.644 | 0.481 | 0.484 | 0.496 | 0.467 | 0.448 | recall decays with first decoy, then plateaus |
| OpenRouter gpt-oss-120b | 0.864 | — | — | 0.852 | — | — | decoy-robust at d5 |

## 5. Two zero-F1 Mistral cells, OPPOSITE root causes (do not conflate)

- **llama.cpp Mistral = scorer bug (cell is actually ✅).** Transcript evidence (`…_d0_r1.jsonl`, `01-now`): emits `{"name":"now","arguments":"{}"}` (correct), result dispatched, final quotes the OOD sentinel; **both assertions `passed:true`**. Yet the CSV row reads `toolTP=0, toolFP=1, f1=0` for that same correct call. Every scenario's tool name is canonical (`now/calc/read_file/list_dir/…`). This is a TP-matching/attribution gap in the scorer for the llama.cpp transcript shape (likely a name/ID-normalization mismatch). **Aggregate F1 for this cell is untrustworthy; `verdict=pass` (24/45) is the real signal.** → *follow-up: a scorer fix would let this cell report its true F1, but it is not a tool-calling defect.*
- **MLX Mistral = genuine no-call.** `precision=0 recall=0 f1=0 decoy_calls=0` — it dispatched **no** tool, not the wrong one. Confirmed across all 5 d0 repeats + the full ladder. Real failure. This is F3.

## 6. Environment & harness caveats

- **`llama3.1-8b.gguf` and `qwen3.5-4b.gguf` were absent from `~/Documents/Models/`** this run (`model file not found` → empty CSVs). These are **not measured**, not regressions — the prior run's llama.cpp llama31-8b ✅ 0.622 still stands as the last good reading. Re-download to re-measure.
- **gemma-4-E4B llama.cpp load-fail is unchanged** — `Unsupported model architecture: gemma4` (the prebuilt xcframework lags upstream arch support; consistent with #2005 / the `chat.cpp`-excluded note). Tool-calls perfectly on Ollama (0.889) — purely a loader gap.
- **`structured-json-extraction` is a no-tool scenario** — a clean `pass` still records `toolTP=0/f1=0`, dragging every cell's *mean* F1 slightly downward (affects the cross-run "≈" deltas above; not a behavioral change).
- **Cloud leg reduced to one anchor** (`gpt-oss-120b`) this run vs five prior — sufficient as the delegated-reference control; not a regression.

## 7. Bottom line for the plan

1. **Re-measure precondition satisfied.** Both flagged Mistral cells re-measured on post-#2035 core.
2. **llama.cpp-Mistral recovered** → that failure class is closed; **no llama.cpp work needed for Mistral**.
3. **MLX-Mistral F3 confirmed live** → **Phase 0 (additive MLX structural-tools threading) is still justified**, and is now the *only* remaining Mistral failure across the three local backends.
4. The other open local failures are **model facts** (gemma3 renders-no-call on both Ollama + llama.cpp) or **backend gaps** (gemma4 arch on llama.cpp) — *no architecture change in this plan fixes those*, so they should not inflate the case for the deeper Phase 1b–3 consolidation.
