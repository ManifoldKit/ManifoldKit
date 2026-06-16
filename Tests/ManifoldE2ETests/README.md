# ManifoldE2ETests

Hardware-gated end-to-end tests. **These do not run in CI** (`.github/workflows/ci.yml`
runs only the mock-friendly suites). They exist for developer pre-push verification
and skip cleanly when the required hardware/fixtures are missing.

Each test guards itself with one of:

- `XCTSkipUnless(HardwareRequirements.isAppleSilicon)` — Metal-dependent tests.
- `XCTSkipUnless(HardwareRequirements.isPhysicalDevice)` — simulator lacks Metal.
- `XCTSkipUnless(HardwareRequirements.hasOllamaServer)` — Ollama-driven tests.
- A direct fixture-path probe.

## Running

```bash
# All E2E tests; most will skip when their fixture / server isn't present.
swift test --filter ManifoldE2ETests
```

The MLX / llama.cpp E2E suites (LlamaE2ETests, LlamaThinkingE2ETests, the
family conformance/baseline suites, VisionE2ETests, …) moved to the
manifold-mlx / manifold-llama companion packages with the backends
(v0.48, PR C2, #1749) — run them from those repos.

## Test fixtures


GGUF / MLX / VLM model fixtures (and the Llama-driven operational baseline
suites) moved to the manifold-llama / manifold-mlx companion repos with the
backends — see each repo's test README for fixture setup.

### Ollama (`OllamaE2ETests`, `OllamaThinkingE2ETests`, `OllamaToolCallingE2ETests`)

Run Ollama locally:

```bash
brew install ollama
ollama serve &
ollama pull llama3.1:8b   # general + tool-calling tests
```

`OllamaE2ETests` / `OllamaThinkingE2ETests` select via
`HardwareRequirements.findOllamaModel()`, whose default `preferredSizeRange`
is `6.5...9.0` (B params) — so they pick an **8B-class** model. A 3–4B pull
(`llama3.2:3b`, `qwen3.5:4b`) is ignored unless it's the only model installed,
which is why the recommended pull above is 8B-class.

`OllamaToolCallingE2ETests` **auto-discovers a tool-capable model** by probing
each installed model's `/api/show` `capabilities` for `"tools"` — no fixed
name list — so any installed native tool-caller (e.g. `llama3.1:8b`,
`qwen3.5`, `gemma4`) works. It skips cleanly when none advertise `"tools"`.

To pin a specific model across these suites, set `OLLAMA_TEST_MODEL` (it must
be installed; for the tool-calling suite it must also be tool-capable):

```bash
OLLAMA_TEST_MODEL=qwen3.5:latest swift test --filter ManifoldE2ETests
```

The tests skip automatically when `localhost:11434` is unreachable.
