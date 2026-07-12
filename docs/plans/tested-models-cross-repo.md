# Tested Local Models — Cross-Repo Consolidated View

**Status:** Reference snapshot, not a live gate — re-derive from the sources below when in doubt.

**Compiled:** 2026-06-26 · **Scope:** ManifoldKit (Ollama) + `manifold-llama` (llama.cpp/GGUF) + `manifold-mlx` (MLX) companion repos.

This doc consolidates which **local models** have been exercised against each backend family, pulling together signal that is otherwise scattered across two `MATRIX.md` conformance runs in this repo and the native test suites of the two companion repos. It is a snapshot, not a live gate — re-derive from the sources below when in doubt.

## Sources

| Source | What it covers |
|--------|----------------|
| `docs/plans/archive/runs/20260622-232839/MATRIX.md` (PR #2033) | Cross-backend tool-call conformance, **pre-#2032** (Mistral cells flagged re-measure-pending) |
| `docs/plans/archive/runs/overnight-20260624-212539/MATRIX.md` | **Re-measure** on post-#2035 core — authoritative for tool-calling cells |
| `manifold-llama` `Tests/ManifoldLlamaTests/Conformance/` | 5-family GBNF + tool-call E2E, embeddings, tokenization |
| `manifold-mlx` integration tests + `MLXModelProbe.swift` | Text, vision/VLM, image-gen/diffusion |

> **The headline principle (from the matrices):** tool-calling capability is a property of the **(model × quant × backend × renderer)** cell, not of the model. The same weights can pass on one backend and emit nothing on another. The cross-backend matrix exists precisely to surface those divergences.

---

## 1. Cross-backend tool-calling matrix

The only place the **same models** run head-to-head on all three local backends, against a shared 9-scenario reference toolset. Figures are from the latest re-measure (`overnight-20260624`); F1 = macro tool-selection.

### Ollama (server-side templates — cleanest leg)

| Model | F1 | Verdict |
|-------|----|---------|
| mistral-7b-tools | 0.778 | ✅ |
| gemma4-e4b | 0.889 | ✅ |
| qwen3.5-9b | 0.889 | ✅ |
| llama3.1-8b | 0.667 | ✅ |
| gemma3-4b-tools | 0.000 | ⚠️ renders-no-call (model fact — never tool-calls) |

### llama.cpp / GGUF (all Q4_K_M)

| Model | Verdict |
|-------|---------|
| Mistral-7B-Instruct-v0.3 | ✅ **recovered** post-#2032/#2035 (correct tool every scenario; reported F1=0 is a **scorer attribution bug**, not a model failure) |
| gemma-3-4b-it `.tooltmpl` | ⚠️ renders-no-call (model fact) |
| gemma-4-E4B | 💥 load-fail — `gemma4` arch unsupported by the prebuilt xcframework |
| llama3.1-8b | 🚫 not measured this run (GGUF absent; last good = **0.622** on Jun 22) |
| qwen3.5-4b | 🚫 not measured (GGUF absent) |

### MLX (4-bit)

| Model | F1 | Verdict |
|-------|----|---------|
| Llama-3.2-3B | 1.000 | ✅ |
| Qwen3-8B | 0.917 | ✅ (most decoy-robust local cell — flat across +1…+20 distractors) |
| Mistral-v0.3 | 0.000 | ⚠️ **no-call — F3 confirmed** (MLX injects tools as system-prompt prose, never calls `applyChatTemplate(messages:tools:)`) |

### Cloud anchor / control (OpenRouter)

`gpt-oss-120b` (0.864, latest run). The Jun 22 run also scored `owl-alpha`, `gemma4-31b`, `nemotron3-super`, `laguna`.

### The Mistral 3-way split (the whole point)

**Same Mistral-v0.3 weights, three outcomes:** ✅ Ollama (0.778, server template) · ✅ llama.cpp (recovered via the #2032 alternation-fold) · ⚠️ MLX (still emits nothing). The MLX case is failure mode **F3**, which gates Phase 0 of the tool-calling architecture plan (`docs/plans/tool-calling-architecture.md`).

---

## 2. manifold-llama — native suites (beyond the matrix)

llama.cpp owns the **5-family GBNF + tool-call conformance** surface. Per-family dialect and grammar support:

| Family | Models exercised | Tool dialect | GBNF grammar | 9-scenario pass |
|--------|------------------|--------------|--------------|-----------------|
| **Llama** | 3.1-8B | Hermes | ✅ | 1–4/9 |
| **Qwen** | 2.5-7B, 3-0.6B, 3-4B-Q4_K_M | Qwen JSON | ✅ (+ thinking) | 4/9 |
| **Mistral** | 7B-Instruct-v0.3 | `[TOOL_CALLS]` array | ✅ | 4/9 |
| **Gemma** | 3 / 3n / 4 (+ 4-E4B) | native `<\|tool_call\|>` | ❌ **carve-out** | 3/9 (gemma3) |
| **Phi** | 3 / 3.5 | generic JSON | ✅ | — |

**Also exercised:** SmolLM2, TinyLlama (tokenization/template tests). **Embeddings:** `nomic-embed-text-v1.5` (Q8_0), plus bge/minilm/jina patterns; reranking via `bge-reranker-v2-m3`.

---

## 3. manifold-mlx — native suites (beyond the matrix)

Much broader than tool-calling — MLX owns vision and image-gen, neither of which has a tool-calling story yet.

**Text (real weights, 4-bit):** Qwen2.5-0.5B, Llama-3.2-3B, Mistral-7B-v0.3. Grammar-constrained sampling E2E on Qwen2.5.

**Text — blocked / crashing (known upstream bugs):**
- Qwen3.5-4B — gated-DeltaNet broadcast mismatch (mlx-swift-lm #157)
- Gemma-4 (all variants) — sliding-window/KV-shared broadcast mismatch (#282/#802)

**Vision / VLM (integration tests):** Qwen2-VL, Qwen2.5-VL, Qwen3-VL, PaliGemma, SmolVLM, LLaVA-Qwen2, Pixtral, FastVLM, IDEFICS3, Gemma-3 vision.

> `MLXModelProbe.swift` declares 30+ LM and 15+ VLM architectures as *supported in code*, but only the handful above are run against real weights.

**Image-gen / diffusion:** FLUX.1-schnell (4-bit), stable-diffusion-2-1-base, sdxl-turbo.

---

## 4. Net read

- The **cross-backend matrix** (§1) is the only head-to-head surface; the companion repos test much wider surfaces individually (§2 grammar, §3 vision + image-gen).
- **Recurring cast everywhere:** Llama-3.x, Qwen (2.5/3/3.5), Mistral-7B-v0.3, Gemma-3/4.
- **Gemma is the consistent problem child:** no GBNF on llama.cpp (deliberate carve-out), `gemma4` arch won't load on llama.cpp at all, Gemma-4 crashes MLX, and gemma3-4b-tools renders-no-call on every backend that *can* load it. It only tool-calls cleanly on Ollama (gemma4-e4b, 0.889).
- **Two MLX gaps trace to upstream mlx-swift-lm bugs**, not ManifoldKit — re-measure when those land.

## 5. Caveats

- §1 cells marked 🚫 reflect GGUFs absent from `~/Documents/Models/` at run time — re-download to re-measure; they are not regressions.
- The llama.cpp Mistral **F1=0 is a scorer attribution bug** (`toolTP=0, toolFP=1` on correct calls); trust the `verdict=pass` (24/45), not the aggregate F1. A scorer fix is a follow-up, not a tool-calling defect.
- Decoy-ladder F1s (§1 robustness claims) are 1 run each except d0 — directional, not tight.
