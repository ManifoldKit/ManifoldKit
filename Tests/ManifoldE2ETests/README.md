# ManifoldE2ETests

Hardware-gated end-to-end tests. **These do not run in CI** (`.github/workflows/ci.yml`
runs only the mock-friendly suites). They exist for developer pre-push verification
and skip cleanly when the required hardware/fixtures are missing.

Each test guards itself with one of:

- `XCTSkipUnless(HardwareRequirements.isAppleSilicon)` — Metal / llama.cpp tests.
- `XCTSkipUnless(HardwareRequirements.isPhysicalDevice)` — simulator lacks Metal.
- `XCTSkipUnless(HardwareRequirements.hasOllamaServer)` — Ollama-driven tests.
- A direct fixture-path probe (e.g. `LlamaThinkingE2ETests`).

## Running

```bash
# All E2E tests; most will skip when their fixture / server isn't present.
swift test --filter ManifoldE2ETests --disable-default-traits

# Targeted: just the Llama thinking pipeline.
swift test --filter ManifoldE2ETests/LlamaThinkingE2ETests --disable-default-traits

# Llama-trait-gated tests (Apple Silicon required).
swift test --filter ManifoldE2ETests --traits Llama
```

## Test fixtures

### GGUF models (`LlamaE2ETests`, `LlamaBackendLoadSerializationCharacterizationE2ETests`)

Place any quantized GGUF >= 50 MB in `~/Documents/Models/`. The first matching file is
picked up by `HardwareRequirements.findGGUFModel()`. SmolLM2 or Qwen2.5 fixtures are
sufficient for non-thinking tests.

### Thinking GGUF (`LlamaThinkingE2ETests`)

`LlamaThinkingE2ETests` exercises the `LlamaGenerationDriver` thinking-parser
integration, so it needs a model that actually emits `<think>...</think>` blocks.
The Qwen3 family is the canonical fixture (Qwen3-0.6B is the smallest and runs on
machines with as little as 8 GB RAM).

**Canonical path** (preferred):

```
~/Library/Caches/ManifoldKit/test-models/qwen3-thinking.gguf
```

The test also falls back to any GGUF discovered by `findGGUFModel()` in
`~/Documents/Models/` and skips cleanly when the discovered model does not emit
thinking tokens (e.g. when it picks up a non-Qwen3 fixture).

**Recommended download** — Qwen3-0.6B-Instruct-GGUF (Q4_K_M quant is ~440 MB):

```bash
mkdir -p ~/Library/Caches/ManifoldKit/test-models
curl -L \
  "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf" \
  -o ~/Library/Caches/ManifoldKit/test-models/qwen3-thinking.gguf
```

> **Note:** verify the exact file name on HuggingFace before downloading — the Qwen
> team occasionally renames quants. Any Qwen3 GGUF that emits `<think>` blocks works;
> the test does not depend on a specific quant or size.

### MLX models (`ModelSelectionE2ETests`, etc.)

Place an MLX snapshot directory (containing `config.json`, `*.safetensors`, and a
tokenizer file) under `~/Documents/Models/`. `HardwareRequirements.findMLXModelDirectory()`
discovers it.

### VLM models (`VisionE2ETests`)

`VisionE2ETests` requires an MLX Vision-Language Model (a model whose `config.json`
contains a `vision_config` key — e.g. LLaVA, Phi-3.5-Vision, Qwen2-VL). Because
MLX inference requires Metal shader compilation, these tests cannot run via plain
`swift test`; they run inside Xcode via `scripts/test-mlx-integration.sh`.

**Setup:**

1. Download an MLX VLM snapshot, e.g. `mlx-community/llava-1.5-7b-hf-4bit`:

   ```bash
   huggingface-cli download mlx-community/llava-1.5-7b-hf-4bit \
     --local-dir ~/Documents/Models/llava-1.5-7b-hf-4bit
   ```

2. Add the `MLX_VLM` slot to the manifest:

   ```bash
   mkdir -p ~/Library/Caches/ManifoldKit/test-models
   # Edit manifest.json to add:
   # { "slots": { "MLX_VLM": "~/Documents/Models/llava-1.5-7b-hf-4bit" } }
   ```

3. Run via the integration script:

   ```bash
   scripts/test-mlx-integration.sh
   ```

The test skips cleanly when the `MLX_VLM` slot is absent, when the directory
does not satisfy `MLXModelProbe.requiresVLMFactory`, or when no Metal GPU is
available (headless / SSH sessions).

### Operational tests (`QualityBaselineTests`, `ThroughputBaselineTests`)

Both suites require `RUN_OPERATIONAL_TESTS=1` in addition to the `MID_THINKING`
manifest slot:

```bash
# Record quality baseline (first run):
RUN_OPERATIONAL_TESTS=1 swift test --traits Llama \
  --filter ManifoldE2ETests/QualityBaselineTests

# Measure throughput:
RUN_OPERATIONAL_TESTS=1 swift test --traits Llama \
  --filter ManifoldE2ETests/ThroughputBaselineTests
```

`QualityBaselineTests` writes a character-level baseline to
`~/Library/Caches/ManifoldKit/test-models/quality/` on first run.  Re-run to
compare; delete the file and re-run to record an intentional change.

### Ollama (`OllamaE2ETests`, `OllamaThinkingE2ETests`, `OllamaToolCallingE2ETests`)

Run Ollama locally:

```bash
brew install ollama
ollama serve &
ollama pull qwen3.5:4b   # for thinking tests
ollama pull llama3.2:3b  # for general tests
```

The tests skip automatically when `localhost:11434` is unreachable.
