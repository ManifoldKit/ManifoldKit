# Phase 2/B/i coverage map — transports, contract scaffold, envelope guards

Captured: 2026-05-15
Branch: `refactor/cross-backend-phase-2b`

## Scope (this PR — Phase 2/B/i)

The Phase 2/A brief deferred a large bundle of work to Phase 2/B. The
SSECloudBackend widen + OpenAIBackend shrink together would produce an
unreviewable diff (the brief itself flags this in its "Pivot freedom"
clause), so 2/B is split:

- **2/B/i (this PR)**: lower-risk, independently-shippable foundations
  — concrete transports, contract test scaffold, two envelope guards,
  coverage map.
- **2/B/ii (next PR, draft)**: the SSECloudBackend widen + OpenAIBackend
  routing through `OpenAIAdapter`. High-risk diff; tracked separately so
  reviewers can focus.

### What 2/B/i ships

1. `Sources/ManifoldCloudCore/SSETransport.swift` — concrete
   `FramedTransport` wrapping `SSEStreamParser` (`package`-scoped, reachable
   from `ManifoldCloudCore` over the unconditional dep edge).
2. `Sources/ManifoldCloudCore/NDJSONTransport.swift` — concrete
   `FramedTransport` for line-delimited JSON with per-line + total-bytes
   bounds.
3. `OpenAIAdapter.framedTransport` now defaults to `SSETransport()`.
4. `Tests/ManifoldBackendsTests/InferenceBackendContractTests.swift` —
   parameterised contract scaffold over a `[Participant]` array. Phase
   2/B/i ships the OpenAI participant only; Phase 3 adds Claude, Ollama,
   and OpenAIResponses as their adapters land. Capability-gated scenarios
   for streaming, usage, tool-call shape, and stream finalization.
5. `Tests/ManifoldBackendsTests/CancellationLivenessContractTest.swift` —
   source-level audit that every `*Backend.swift` observes
   `Task.isCancelled` (or composes a helper that does, e.g.
   `OllamaStreamProcessor`). Phase 3 upgrades this to a runtime liveness
   contract once the adapter owns the cancel path.
6. `Tests/ManifoldBackendsTests/CloudErrorSanitizerCoverageTest.swift` —
   source-level audit that every `*Backend.swift` routes errors through
   `CloudErrorSanitizer` either directly, via `parseCloudErrorMessage`,
   or by inheriting `SSECloudBackend`'s envelope-level error surface.

## Deferred to Phase 2/B/ii (next PR, draft)

| Deferred item | Why deferred | Tracks in |
|---|---|---|
| Widen `SSECloudBackend` to consume `CloudHTTPProviderAdapter` end-to-end | Touches envelope-level retry / cancel / stream lifecycle. Highest-risk diff in the entire refactor; needs full pre-push gate + behavioural parity tests. | Phase 2/B/ii |
| Route `OpenAIBackend.parseResponseStream` through `OpenAIAdapter` and `SSECloudBackend`'s adapter path | ~580 LOC of tool-call accumulation + prefill progress + reasoning-delta handling. Shrinking 781→200 LOC without losing functionality needs careful parity work. | Phase 2/B/ii |
| Wire `OpenAIAdapter`'s composed witnesses (`toolCallShape` et al.) to actual provider behaviour | The witnesses are compile-only stubs today. Phase 2/B/ii adds behavioural bodies as the OpenAIBackend logic moves into them. | Phase 2/B/ii |
| Promote `CancellationLivenessContractTest` to a runtime liveness test | Requires per-backend driver instrumentation (a test-visible observed-flag counter). The source-level audit catches the failure mode it's there to prevent (copy-pasted backend without cancellation check) at zero instrumentation cost. Runtime upgrade follows once each backend's cancel path runs through the envelope. | Phase 3 |
| Promote `CloudErrorSanitizerCoverageTest` to a runtime test | Same shape — needs a sentinel `CloudErrorSanitizer` hook the test installs and asserts observed. Runtime upgrade follows the adapter's ownership of the throw site. | Phase 3 |
| Record on-disk OpenAI fixtures under `Tests/Fixtures/backends/openai/` | Capture-against-live needs a stable, reproducible runner step + `FixtureRedactionAuditTest` pass per fixture. Phase 2/B/i keeps the contract test inline-fixture-driven so the scaffold ships now; recording is the first step of Phase 2/B/ii. | Phase 2/B/ii |

## Deferred to Phase 3 (per-backend adapter migrations)

The Phase 2/A coverage map enumerated four legacy parser/handler source files
as candidates for deletion in 2/B. After re-checking the call sites:

| File | Status | Rationale |
|---|---|---|
| `Sources/ManifoldCloud/ClaudePayloadParser.swift` | KEEP — defer to Phase 3 | `ClaudeBackend.parseResponseStream` (lines ~393–491) still calls `ClaudePayloadParser.parseEventType`, `parseToolUseBlockStart`, `parseInputJSONDelta`, `parseContentBlockIndex`, `parseThinkingBlockStartSignature`, `parseSignatureDelta`, `parseWholeMessageToolUseBlocks`, `parseCacheUsage`. Migrates with `ClaudeAdapter` in Phase 3. |
| `Sources/ManifoldCloud/ClaudeToolCallAccumulator.swift` | KEEP — defer to Phase 3 | Coupled to `ClaudePayloadParser`'s value types; moves with the parser. |
| `Sources/ManifoldCloud/OllamaPayloadHandler.swift` | KEEP — defer to Phase 3 | The `OllamaPayloadParser.parseLine` namespace is still consumed by `OllamaStreamProcessor`. Struct is already a shim around `CloudPayloadHandler.ollama`; full removal needs `OllamaAdapter`. |
| `Sources/ManifoldCloud/OllamaStreamProcessor.swift` | KEEP — defer to Phase 3 | 332 LOC of stateful NDJSON stream-loop logic still driven by `OllamaBackend.parseResponseStream`. Moves with `OllamaAdapter`. |

The three per-handler test files (`ClaudePayloadHandlerTests`,
`OllamaPayloadHandlerTests`, `OpenAIResponsesPayloadHandlerTests`) are
also kept for the same reason — the unique scenarios catalogued in
`phase-1b-coverage-map.md` (signature-delta returns-empty, real-fixture
thinking-then-token ordering, invalid-UTF-8-mid-line, reasoning-delta
helper assertions) are not yet replicated in
`CloudPayloadHandlerContractTests` and removing them would drop scenarios
the migration explicitly promised to preserve.

`CloudSeamUsageAuditTest`'s OpenAI allowlist entry **stays** in 2/B/i because
the envelope widen + OpenAI routing happens in 2/B/ii. The entry comes off
the allowlist in 2/B/ii.

## Sabotage verification

Each new audit was sabotage-verified locally before commit:

| Audit | Sabotage edit that should fail it | Confirmed |
|---|---|---|
| `CancellationLivenessContractTest` | Add `Sources/ManifoldCloud/SabotageBackend.swift` with `class SabotageBackend { func parseResponseStream() {} }` and no `Task.isCancelled` reference | Yes — fails with "Backend file(s) do not reference cancellation observation" |
| `CloudErrorSanitizerCoverageTest` | Add the same Sabotage backend file but with a `Task.isCancelled` reference and no sanitizer route | Yes — fails with "Backend file(s) do not route errors through CloudErrorSanitizer" |

The contract scenarios in `InferenceBackendContractTests` were not
sabotage-verified individually — each scenario is structurally simple
(extract event → assert non-empty, extract usage → assert > 0) and lives
or dies with the underlying `CloudPayloadHandler` enum already
contract-tested in 1b/C.
