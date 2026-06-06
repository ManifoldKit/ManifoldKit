# Anthropic Claude (Messages API) fixtures

Synthetic-shape fixtures matching the Anthropic Messages API streaming
wire format. Used by `InferenceBackendContractTests` to drive the
parameterised contract suite over the Claude participant, and by
`ClaudeStreamEventExtractorTests` to assert per-stream event extraction
matches the inline `ClaudeBackend.parseResponseStream` behaviour.

Each scenario folder contains:

- `request.json` — synthesised request body (for documentation; not driven
  through the network in the contract tests).
- `response.sse` — raw SSE bytes the upstream would emit. Anthropic's SSE
  shape carries `event: <name>` lines before each `data: …` payload line;
  for tooling parity with the OpenAI fixtures the contract tests parse
  only the `data: …` lines.
- `expected.jsonl` — `[FixtureEvent]` projection of the `GenerationEvent`s
  the backend should emit while replaying `response.sse`.

These were authored by hand (not captured against a live endpoint) and
therefore use placeholder model names (`claude-sonnet-fixture`) and never
contain real `x-api-key` values, organisation IDs, or PII. Re-captures
via `scripts/record-fixture.sh` should keep that invariant — the
`FixtureRedactionAuditTest` will fail the build if a real credential
leaks in.

## Scenarios

- `streaming/simple-prompt/` — `message_start` → `content_block_start`
  (text) → two `content_block_delta` (text_delta) → `content_block_stop`
  → `message_delta` (with `output_tokens`) → `message_stop`. Exercises
  the token extraction + finalizer path.
- `tool-calls/simple/` — `message_start` → `content_block_start` with
  `type: tool_use` (id + name) → two `content_block_delta`
  (`input_json_delta` fragments) → `content_block_stop` → `message_stop`.
  Exercises the Anthropic block tool-call path including the input-JSON
  delta accumulator and per-block finalisation.
- `thinking/with-signature/` — `message_start` → `content_block_start`
  (type=thinking) → `content_block_delta` (`thinking_delta`) →
  `content_block_delta` (`signature_delta` carrying the opaque signature)
  → `content_block_stop` → `content_block_start` (text) →
  `content_block_delta` (text_delta) → `content_block_stop` →
  `message_stop`. Exercises the `.thinkingSignature` emission and the
  open-thinking → text handoff (`.thinkingCompleted`).
- `usage/basic/` — `message_start` (with `input_tokens`) → text deltas
  → `message_delta` (with `output_tokens`) → `message_stop`. Exercises
  the split-usage extraction; both halves must be merged before the
  extractor emits `.usage`.
