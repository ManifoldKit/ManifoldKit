# Ollama capture version

- **Pinned version:** `0.3.12` (directory name)
- **Model used for capture:** `llama3.1:8b` (also works with `qwen2.5:7b-instruct`)
- **Capture date:** 2026-04-22
- **Capture environment:** Synthesised from observed Ollama NDJSON wire
  traces (see note below); re-capture against a live server before
  publishing any telemetry derived from these fixtures.

## Capture status

These fixtures were **hand-crafted** to match the NDJSON shapes produced
by Ollama 0.3.12 at the time of writing. The `chat-fuzzing` session
(`feedback_fuzzer` memory, April 2026) already validated the non-tool
paths (thinking, usage, done) against a live 0.3.12 server. The tool-call
shapes here mirror what that same build emits when invoked with a `tools`
array in `/api/chat` — but this was *not* re-captured live for this PR
because the worker environment has no Ollama daemon.

### Re-capture procedure (live)

```bash
# 1. Confirm version
ollama --version   # expect: ollama version is 0.3.12

# 2. Run capture script
swift run manifold-tools capture-ollama-tool-calls \
    --model llama3.1:8b \
    --out Tests/Fixtures/ollama/tool-calls/0.3.12/

# 3. Or capture manually with curl
curl -N http://localhost:11434/api/chat \
  -d '{"model":"llama3.1:8b","messages":[{"role":"user","content":"What'\''s the weather in Paris?"}],"tools":[{"type":"function","function":{"name":"get_weather","description":"Gets weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]}' \
  > simple-tool-call.sse
```

## Pinning in CI

The tiered Ollama CI workflow (see `TESTING.md §Ollama-E2E`) passes
`OLLAMA_VERSION=0.3.12` to the job. The job fails fast when
`ollama --version` doesn't contain that string. Update this file and
the workflow together when bumping Ollama.
