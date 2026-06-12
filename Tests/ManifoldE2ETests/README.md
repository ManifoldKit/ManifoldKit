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
ollama pull qwen3.5:4b   # for thinking tests
ollama pull llama3.2:3b  # for general tests
```

The tests skip automatically when `localhost:11434` is unreachable.
