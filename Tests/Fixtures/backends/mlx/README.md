# MLX backend fixtures

MLX generates non-deterministic token streams because the Metal GPU scheduler
does not guarantee bit-for-bit reproducibility across runs. Fixtures for the
`LocalBackendContractTests` MLX participant are therefore captured via
`scripts/record-fixture.sh` on a specific model against Apple Silicon hardware
and committed to this directory.

## Capturing fixtures

Run the following with `RUN_SLOW_TESTS=1` set and an MLX model checked out
at the path your test expects:

```
RUN_SLOW_TESTS=1 scripts/record-fixture.sh mlx streaming/simple-prompt
```

The script calls `generate(prompt: "Hello", systemPrompt: nil, config: GenerationConfig())`
through the backend and serialises each `GenerationEvent` as a JSON line into
`streaming/simple-prompt/expected.jsonl`. Example output (model-dependent):

```jsonl
{"event":"token","text":"Hello"}
{"event":"token","text":"!"}
{"event":"token","text":" How"}
```

## Nightly tier

The MLX contract participant skips generation scenarios unless
`RUN_SLOW_TESTS=1` is set in the environment. Per-PR CI does not set this
variable, so these fixtures are only required in the nightly tier where a
real model and Apple Silicon hardware are present.
