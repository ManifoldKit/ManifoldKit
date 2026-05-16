# Foundation backend fixtures

The Foundation backend uses Apple's on-device language model via the
FoundationModels framework. Unlike file-based backends, there is no GGUF or
MLX model to load — the model is provided by the system (Apple Intelligence).

Fixtures for the `LocalBackendContractTests` Foundation participant are captured
via `scripts/record-fixture.sh` on a macOS 26 / iOS 26 device with Apple
Intelligence enabled and committed to this directory.

## Capturing fixtures

Run the following with `RUN_SLOW_TESTS=1` set on a macOS 26+ host with Apple
Intelligence enabled:

```
RUN_SLOW_TESTS=1 scripts/record-fixture.sh foundation streaming/simple-prompt
```

The script calls `generate(prompt: "Hello", systemPrompt: nil, config: GenerationConfig())`
through the backend and serialises each `GenerationEvent` as a JSON line into
`streaming/simple-prompt/expected.jsonl`. Example output:

```jsonl
{"event":"token","text":"Hello"}
{"event":"token","text":"!"}
{"event":"token","text":" How"}
```

## Nightly tier

The Foundation contract participant skips generation scenarios unless
`RUN_SLOW_TESTS=1` is set in the environment and the OS is macOS 26 / iOS 26+.
Per-PR CI does not set this variable, so these fixtures are only required in the
nightly tier where Apple Intelligence is available.
