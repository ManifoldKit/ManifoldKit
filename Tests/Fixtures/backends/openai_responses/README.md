# OpenAI Responses API fixtures

Synthetic-shape fixtures matching the OpenAI Responses streaming wire
format. Used by `InferenceBackendContractTests` (the Responses
participant) and the `OpenAIResponsesStreamEventExtractorTests` parity
suite.

Each scenario folder contains:

- `request.json` — synthesised request body (for documentation; not
  driven through the network in the contract tests).
- `response.sse` — raw SSE bytes with `event:` + `data:` lines, blank
  line between events. Mirrors what the Responses API emits.
- `expected.jsonl` — `[FixtureEvent]` projection of the
  `GenerationEvent`s the extractor should emit while replaying the
  fixture.

These were authored by hand (not captured against a live endpoint) and
use placeholder model names (`gpt-5-fixture`) plus synthetic IDs. The
`FixtureRedactionAuditTest` will fail the build if a real credential,
account ID, or PII pattern leaks in.

## Scenarios

- `streaming/simple-prompt/` — two `response.output_text.delta` events
  bracketed by a terminal `response.completed`; exercises the visible-
  text token path.
- `tool-calls/simple/` — one `response.output_item.added` (function_call),
  one `response.function_call_arguments.delta`, one
  `response.function_call_arguments.done`, then `response.completed`;
  exercises the item_id → call_id tool-call path.
- `reasoning/summarized/` — two
  `response.reasoning_summary_text.delta` events, then an
  `response.reasoning_summary_text.done`, then an
  `response.output_text.delta`; exercises the summarized-thinking
  handoff (no Anthropic-style signed thinking).
- `usage/basic/` — minimal `response.output_text.delta` +
  `response.completed` with `response.usage.{input_tokens,
  output_tokens}`; exercises usage extraction.
