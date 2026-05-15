# OpenAI Chat Completions fixtures

Synthetic-shape fixtures matching the OpenAI Chat Completions streaming
wire format. Used by `InferenceBackendContractTests` to drive the
parameterised contract suite over the OpenAI participant.

Each scenario folder contains:

- `request.json` — synthesised request body (for documentation; not driven
  through the network in the contract tests).
- `response.sse` — raw SSE bytes the upstream would emit. Each `data: …`
  line is one event payload.
- `expected.jsonl` — `[FixtureEvent]` projection of the `GenerationEvent`s
  the backend should emit while replaying `response.sse`.

These were authored by hand (not captured against a live endpoint) and
therefore use placeholder model names (`gpt-4o-mini-fixture`) and never
contain bearer tokens, organisation IDs, or PII. Re-captures via
`scripts/record-fixture.sh` should keep that invariant — the
`FixtureRedactionAuditTest` will fail the build if a real credential
leaks in.

## Scenarios

- `streaming/simple-prompt/` — one-payload `delta.content` emission;
  exercises the token extraction path.
- `tool-calls/simple/` — single streaming `tool_calls[]` delta with
  `index=0`, `id`, `function.name`, and a complete `function.arguments`
  payload; exercises the OpenAI delta-shape tool-call path.
- `usage/basic/` — terminal `usage:{prompt_tokens, completion_tokens}`
  frame; exercises usage extraction.
- `finalizer/terminal/` — `[DONE]` sentinel; exercises the
  `OpenAIDoneSentinelFinalizer` recognition.
