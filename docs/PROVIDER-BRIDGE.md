# Provider bridge (AnyLanguageModel)

ManifoldKit ships native backends for MLX, llama.cpp/GGUF, Apple Foundation Models, OpenAI (Chat + Responses), Anthropic, and Ollama. Providers without a native backend are reached through the **AnyLanguageModel bridge** — a single `InferenceBackend` adapter over HuggingFace's [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) package.

AnyLanguageModel operates at the model-access altitude (one protocol, many providers). ManifoldKit operates at the application-framework altitude and consumes it as one more backend, so a bridged provider plugs into the same `ChatViewModel`, conversation runtime, and persistence path as a native backend.

## Providers unlocked

The bridge is the supported path for providers ManifoldKit does not implement natively, including:

- Google **Gemini**
- **xAI** (Grok)
- **Groq**
- **Mistral**
- **OpenRouter** (and any OpenAI-compatible `/responses` endpoint)
- Any OpenAI- or Anthropic-API-compatible endpoint

OpenAI, Anthropic, and Ollama also resolve through the bridge, but the native `CloudSaaS` / `Ollama` backends are preferred for those — they add certificate pinning, retry, circuit-breaking, and latest-wins cancellation that the bridge does not.

## Enabling the trait

The bridge lives behind the opt-in `AnyLanguageModel` trait. Enable it from the consumer manifest:

```swift
.package(
    url: "https://github.com/roryford/ManifoldKit.git",
    from: "0.43.0",
    traits: ["AnyLanguageModel"]
)
```

## Configuring a provider

Models are resolved from a URL whose scheme selects the provider. The model identifier is the host/path; credentials and overrides are query items.

| Scheme | Example | Required query items |
|--------|---------|----------------------|
| `gemini` | `gemini://gemini-2.0-flash?apiKey=KEY` | `apiKey` |
| `openai` | `openai://gpt-4o?apiKey=KEY` | `apiKey` |
| `openai-responses` | `openai-responses://gpt-4.1?apiKey=KEY` | `apiKey` |
| `anthropic` | `anthropic://claude-3-5-sonnet?apiKey=KEY` | `apiKey` |
| `ollama` | `ollama://llama3.2?baseURL=http://localhost:11434` | — |
| `openresponses` | `openresponses://x-ai/grok-2?apiKey=KEY` | `apiKey` |

Common optional query items: `baseURL` (override the provider endpoint — point `openai`/`openai-responses` at xAI, Groq, or Mistral's OpenAI-compatible URL), `apiVersion`, and provider-specific overrides documented inline in `AnyLanguageModelURLResolver`.

```swift
import ManifoldBackends

let backend = AnyLanguageModelBackend()
let url = URL(string: "gemini://gemini-2.0-flash?apiKey=\(key)")!
try await backend.loadModel(from: url, plan: plan)
let stream = try backend.generate(prompt: prompt, systemPrompt: system, config: config)
```

## Capabilities and limits

The bridge advertises a conservative capability floor — `isRemote = true`, streaming on, and tool calling / structured output / native JSON mode / thinking tokens / grammar-constrained sampling all **off**. `generate()` fail-closes (throws) on a tool, JSON-mode, or grammar request rather than silently dropping it, so the capability router never routes those requests here. This floor is uniform across wrapped providers because the bridge streams plain text only.

Requests routed through the bridge do **not** inherit ManifoldKit's certificate pinning, retry strategy, circuit breaker, or latest-wins cancellation — AnyLanguageModel owns those concerns internally. `stopGeneration()` maps to `Task.cancel()`, so stop promptness depends on AnyLanguageModel's implementation.

When a bridged provider grows enough demand to justify reasoning-token fidelity or operational parity, the path is to promote it to a native backend. See [`SCOPE_DECISION.md`](SCOPE_DECISION.md) for the recorded Gemini native-vs-bridge decision.

## Testing

`AnyLanguageModelConformanceTests` runs the universal backend contract and the capability meta-contract against the bridge offline (no network) whenever the trait is enabled. A live tier exercises a real provider end-to-end, gated behind an env var like the other live E2E suites:

```bash
RUN_ANYLM_E2E=1 \
ANYLM_E2E_URL='gemini://gemini-2.0-flash?apiKey=YOUR_KEY' \
swift test --traits AnyLanguageModel \
  --filter AnyLanguageModelConformanceTests/test_live_streamsRealCompletion
```

Without `RUN_ANYLM_E2E=1` and `ANYLM_E2E_URL`, the live test skips cleanly.
