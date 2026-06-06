# ``OutputParserSession``

Unified, chunk-safe streaming markup pipeline shared by every local and inline
text-scanning backend.

## Overview

`OutputParserSession` replaces the four hand-rolled streaming parsers each
backend used to maintain independently (`ThinkingParser`, `MLXToolCallParser`,
`LlamaToolCallParser`, plus the Ollama content-field scan). It is an **ordered
chain of transforms**: each chunk is wrapped as `[.token(chunk)]` and piped
through the stages in declaration order. Every stage re-scans **only the
`.token` payloads** it receives and passes structured events
(``GenerationEvent/thinkingToken(_:)``, ``GenerationEvent/thinkingCompleted``,
``GenerationEvent/toolCall(_:)``, …) straight through untouched.

```swift,no-build
var session = OutputParserSession([
    .thinking(ThinkingTransform(markers: .qwen3)),
    .tool(ToolCallTransform(markers: LlamaToolMarkers.markers())),
])

for chunk in tokenStream {
    for event in session.ingest(chunk) {
        continuation.yield(event)
    }
}
for event in session.finalize() {
    continuation.yield(event)
}
```

### Destination-model mapping

The session never invents a new output vocabulary — destination is the existing
tagged ``GenerationEvent`` case, exactly as each backend already emitted:

| Source text | Emitted event |
|-------------|---------------|
| Text outside any marker block | ``GenerationEvent/token(_:)`` |
| Text inside a thinking block | ``GenerationEvent/thinkingToken(_:)`` |
| Thinking block close (depth 1→0) | ``GenerationEvent/thinkingCompleted`` |
| Completed tool-call body | ``GenerationEvent/toolCall(_:)`` |

### Stage order is chain order

The order maps directly to "what does each dialect see first". The two local
backends keep their historical order, so behavior is unchanged by construction:

| Backend | Stages | Rationale |
|---------|--------|-----------|
| MLX     | `[.tool, .thinking]` | Tool tags stripped first; thinking re-scans the remaining visible text. |
| Llama   | `[.thinking, .tool]` | Thinking stripped first; tool calls never appear inside a thinking block. |
| Ollama  | `[.thinking]` | Content-field scan only — Ollama tool calls arrive via structured fields. |

### N-candidate tool dialects

A single ``ToolCallTransform`` carries an array of ``ToolCallMarker`` dialects
and resolves them **earliest-open-wins**, with ties broken by array order. This
is how Llama folds its two competing open tags — Gemma-4 native `<|tool_call>`
and the JSON fallback `<tool_call>` — into one stage: list Gemma-4 first and it
wins a positional tie, preserving the original parser's preference.

```swift,no-build
ToolCallTransform(markers: [
    ToolCallMarker(open: "<|tool_call>", close: "<|end_of_turn>") { body in /* … */ },
    ToolCallMarker(open: "<tool_call>",  close: "</tool_call>")   { body in /* … */ },
])
```

The dialect-specific body parsing stays in the family targets
(`ManifoldMLX`, `ManifoldLlama`) as injected `@Sendable` closures, keeping the
session core free of MLX/Llama dependencies.

### Chunk-boundary holdback

Both transforms hold back the longest suffix of the buffer that could be the
start of a marker, using the shared `overlap` primitive (llama.cpp's
`string_find_partial_stop` / Ollama's `overlap`). A `ToolCallTransform` with
several candidate opens holds back the *max* overlap across all of them, so a
partial form of any dialect's open tag is never leaked as visible text. This is
the one place holdback math lives.

### Finalize discard rule

`finalize()` flushes each stage's held-back tail in chain order and feeds every
flushed event through the stages downstream of it before they finalize in turn:

- An **unterminated thinking block** flushes as ``GenerationEvent/thinkingToken(_:)``.
- A **trailing partial open tag** flushes as plain ``GenerationEvent/token(_:)``.
- An **unterminated open tool block is discarded** — a partial body cannot form
  a valid ``ToolCall`` — matching the silent-drop behavior of both legacy
  tool parsers.

## Topics

### Building a session

- ``OutputParserSession/init(_:)``
- ``Stage``

### Driving a stream

- ``OutputParserSession/ingest(_:)``
- ``OutputParserSession/finalize()``

### Transforms

- ``ThinkingTransform``
- ``ToolCallTransform``
- ``ToolCallMarker``
- ``StreamTransform``
