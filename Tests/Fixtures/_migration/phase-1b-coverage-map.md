# Phase 1b coverage map (Worker C — parser consolidation)

Captured: 2026-05-15
Branch: `refactor/cross-backend-phase-1b-parser`

## Scope

Phase 1b Worker C consolidates the **`SSEPayloadHandler` protocol surface**
into a single `CloudPayloadHandler` enum keyed by provider, and adds the
`StreamFinalizer` protocol with four concrete per-provider implementations.

## What this PR does NOT delete (and why)

The Phase 1b plan calls for deleting three test files:

| Plan said delete | Phase 1b decision | Rationale |
|---|---|---|
| `Tests/ManifoldBackendsTests/ClaudePayloadHandlerTests.swift` | KEEP — defer to Phase 2 | Contains unique coverage not yet replicated in `CloudPayloadHandlerContractTests`: `test_extractEvents_signatureDelta_returnsEmpty`, `test_extractEvents_truncatedJSON_returnsEmpty`, `test_realFixture_emitsThinkingThenTokenInOrder` (real captured-stream replay). Deleting now would drop those scenarios and trip `CoverageRegressionGateTest`. They keep passing because `ClaudePayloadHandler()` is now a thin shim around `CloudPayloadHandler.claude`. |
| `Tests/ManifoldBackendsTests/OllamaPayloadHandlerTests.swift` | KEEP — defer to Phase 2 | Contains `test_extractEvents_invalidUTF8MidLine_returnsEmpty`, `test_realFixture_emitsThinkingThenTokenInOrder`, and 5 other scenarios outside the per-payload contract surface. Same shim path. |
| `Tests/ManifoldBackendsTests/OpenAIResponsesPayloadHandlerTests.swift` | KEEP — defer to Phase 2 | Exercises the `eventsForReasoningDelta(data:)` / `eventsForOutputTextDelta(data:)` helpers that the named-event dispatcher uses; those helpers stay on `OpenAIResponsesBackend` and the test surface is still load-bearing. |

The Phase 2 PR that lifts parser internals into the adapter composition will
delete these three files in one go, replaced by enriched fixture-driven
scenarios in `CloudPayloadHandlerContractTests`.

## Files added

- `Sources/ManifoldCloudCore/StreamFinalizer.swift` (protocol + 4 concrete
  impls: `OpenAIDoneSentinelFinalizer`, `OpenAIResponsesEventFinalizer`,
  `ClaudeMessageStopFinalizer`, `OllamaDoneFlagFinalizer`).
- `Sources/ManifoldCloud/CloudPayloadHandler.swift` (enum keyed by provider
  conforming to `SSEPayloadHandler`; dispatches to per-provider parser
  namespaces left in place).
- `Tests/ManifoldBackendsTests/CloudPayloadHandlerContractTests.swift`
  (parameterised contract tests + `StreamFinalizerContractTests`).

## Files modified

- `Sources/ManifoldCloud/OpenAIBackend.swift` — `OpenAIPayloadHandler`
  struct removed; replaced with `static let payloadHandler: any
  SSEPayloadHandler = CloudPayloadHandler.openAI`; added internal seams
  `legacyExtractToken(from:)` / `legacyExtractUsage(from:)`.
- `Sources/ManifoldCloud/ClaudeBackend.swift` — init passes
  `CloudPayloadHandler.claude` instead of `ClaudePayloadHandler()`.
- `Sources/ManifoldCloud/OllamaBackend.swift` — init passes
  `CloudPayloadHandler.ollama`.
- `Sources/ManifoldCloud/OpenAIResponsesBackend.swift` — init passes
  `CloudPayloadHandler.openAIResponses`; nested
  `OpenAIResponsesPayloadHandler` struct reduced to a thin shim.
- `Sources/ManifoldCloud/ClaudePayloadParser.swift` — top-level
  `ClaudePayloadHandler` struct reduced to a thin shim around the enum
  (preserves `SSEPayloadReplayTests` call sites).
- `Sources/ManifoldCloud/OllamaPayloadHandler.swift` — `OllamaPayloadHandler`
  struct reduced to a thin shim around the enum (preserves
  `OllamaBackendTests` call sites).

## Deliberate Phase 1b carve-outs (deferred to Phase 2)

These deletions were enumerated in the brief but require lifting the
parser internals into the adapter composition before they can land
without breaking stream-loop code that calls the per-provider parsers
directly:

- `Sources/ManifoldCloud/ClaudePayloadParser.swift` — KEPT. The
  `ClaudePayloadParser` enum exposes `parseEventType`,
  `parseToolUseBlockStart`, `parseInputJSONDelta`,
  `parseContentBlockIndex`, `parseThinkingBlockStartSignature`,
  `parseSignatureDelta`, `parseWholeMessageToolUseBlocks`, and
  `parseCacheUsage`, all called directly from
  `ClaudeBackend.parseResponseStream` (lines 393–491). Migrating those
  call sites is a Phase 2 concern.
- `Sources/ManifoldCloud/ClaudeToolCallAccumulator.swift` — KEPT. Tightly
  coupled to `ClaudePayloadParser.ToolUseBlockStart` /
  `InputJSONDelta` / `WholeToolUseBlock` value types and consumed by
  `ClaudeBackend.parseResponseStream`. Moves with the parser in Phase 2.
- `Sources/ManifoldCloud/OllamaPayloadHandler.swift` — KEPT (struct
  reduced to a shim; the `OllamaPayloadParser.parseLine` namespace stays
  for `OllamaStreamProcessor`).
- `Sources/ManifoldCloud/OllamaStreamProcessor.swift` — KEPT. 332 LOC of
  stateful NDJSON stream-loop logic; deleting requires inlining into
  `OllamaBackend.parseResponseStream` or relocating to the future
  `OllamaAdapter`. Phase 2.

## Coverage gate

`CoverageRegressionGateTest` (Phase 1a) checks for >0.5pp region drop or
any public symbol going 0%. This PR ADDS coverage (new enum, new finalizer
protocols) and does not remove any public-symbol coverage — the four
`*PayloadHandler` structs remain reachable and tested via the shim layer.
Sabotage check: reverted the `payloadHandler: CloudPayloadHandler.claude`
edit in `ClaudeBackend.swift`; confirmed `CloudPayloadHandlerContractTests`
remained green (the enum is independently testable) and existing
`ClaudePayloadHandlerTests` remained green via the shim. No regression
risk observed.
