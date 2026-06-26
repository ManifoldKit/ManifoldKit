# `manifold-tools` — end-to-end tool-calling harness

`manifold-tools` is a CLI harness that proves tool calling works end-to-end on a real backend without spinning up a SwiftUI app. It ships:

- A fixed reference toolset (`now`, `calc`, `read_file`, `list_dir`, `http_get_fixture`) that every scenario can draw from.
- A declarative scenario format (JSON) so new test cases land as data, not Swift code.
- A `ToolRegistry`-driven runner that dispatches calls, feeds results back into the conversation, and asserts on the final answer.
- A JSONL transcript logger so regression diffs and CI dashboards can ingest runs without parsing stdout.

## Running

```sh
# Mock backend — no hardware, no Ollama. Useful for CI smoke and local sanity checks.
swift run --disable-default-traits manifold-tools --backend mock --scenario all

# Real Ollama — requires a local server with tool-capable models installed,
# (the Ollama path is always compiled in since v0.48 — no trait needed).
swift run --disable-default-traits manifold-tools --backend ollama --scenario 02-calc \
    --ollama-base-url http://localhost:11434 --model llama3.1:8b
```

Every run writes a transcript to `tmp/manifold-tools/<ISO timestamp>.jsonl` with one JSON row per event (`prompt`, `tool_call`, `tool_result`, `token_delta`, `final`, `assertion`).

Exit codes:

| Code | Meaning |
|------|---------|
| 0    | All scenarios passed. |
| 1    | At least one scenario or assertion failed (or a runtime error). |
| 2    | Bad CLI arguments. |

## Scenarios

Built-in scenarios live in `Scenarios/built-in/`. Each is a plain JSON file:

```json
{
  "id": "01-now",
  "systemPrompt": "You have tools. …",
  "userPrompt": "What time is it?",
  "requiredTools": ["now"],
  "assertions": [
    {"kind": "containsLiteral", "value": "2099-01-01T00:00:00Z"}
  ],
  "backend": {"kind": "ollama", "model": "llama3.1:8b", "temperature": 0.0}
}
```

Supported assertion kinds:

| Kind | Payload | Passes when |
|------|---------|-------------|
| `containsLiteral` | `"value": String` | `finalAnswer.contains(value)` |
| `equalsLiteral` | `"value": String` | `finalAnswer == value` |
| `containsAll` | `"values": [String]` | Every entry in `values` is present |
| `containsAny` | `"values": [String]` | At least one entry in `values` is present (use for contracts a correct model can paraphrase) |
| `toolInvoked` | `"value": String` | Tool `value` was dispatched at least once |
| `toolResultContains` | `"value": String`, `"values": [String]` | At least one result for tool `value` contains every entry in `values` |
| `toolResultErrorKind` | `"value": String`, `"values": [String]` | At least one result for tool `value` has `errorKind` equal to the first entry in `values` |

To add a scenario, drop a JSON file in `Scenarios/built-in/`. No Swift recompile needed — the loader enumerates the directory at runtime.

## Reference tools

| Name | Args | Behaviour |
|------|------|-----------|
| `now` | `{}` | Returns a fixture ISO-8601 timestamp (`2099-01-01T00:00:00Z`) deliberately outside any model's training distribution so scenario assertions can distinguish a real tool call from hallucination. Override via `MANIFOLD_TOOLS_NOW_FIXTURE`. |
| `calc` | `{a, op, b}` | Pure arithmetic. Returns `.invalidArguments` on division by zero or unknown operators. |
| `read_file` | `{path}` | Reads from `Tests/Fixtures/manifold-tools/` only. Path escapes (symlink or `..`) return `.permissionDenied`; missing files return `.notFound`. |
| `list_dir` | `{dir}` | Lists non-hidden filenames inside the same sandbox. |
| `http_get_fixture` | `{url}` | Returns canned JSON for well-known `https://fixture.manifold/…` URLs. Real network access is double-gated: pass `--real-network` *and* set `MANIFOLD_TOOLS_ALLOW_NETWORK=1`. Default CI mode cannot touch the public internet. |

## CI

`manifold-tools --backend mock --scenario all` runs in CI via `ManifoldToolsTests` (which exercises the same runner with a scripted backend — no `swift run` needed). A tiered workflow that also runs against local Ollama is deferred as follow-up work: the CI runner doesn't have Ollama installed and the maintainer prefers to gate tiered jobs on repository secrets that are added in a separate PR.

Local developers with Ollama can run the real-model E2E with:

```sh
ollama serve &                          # in another terminal
ollama pull llama3.1:8b
swift run --disable-default-traits manifold-tools --backend ollama --scenario all
```

## Why a dedicated harness?

Unit tests prove wire formats; replay fixtures prove parsing; neither proves that a real model will actually emit a `ToolCall` when the system prompt says it should. The harness closes that gap by running a genuine inference loop against real tool dispatch code and asserting on *the final text the model produced*. A passing assertion for an out-of-distribution literal (the `now` fixture, the `7823 * 41` product) is strong evidence the tool was invoked rather than guessed around.
