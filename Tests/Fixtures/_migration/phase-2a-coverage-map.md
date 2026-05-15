# Phase 2/A coverage map — adapter scaffolding + envelope audits

Captured: 2026-05-15
Branch: `refactor/cross-backend-phase-2`

## Scope (this PR — Phase 2/A)

Lays the type-system foundation for the cross-backend adapter migration **without changing any runtime behaviour**. Specifically:

1. Adds the `CloudHTTPProviderAdapter` composition-root protocol in `ManifoldCloud`.
2. Adds six "shape" witness protocols + concrete stubs in `ManifoldCloudCore`:
   `ToolCallShape`, `ImageInputShape`, `StructuredOutputShape`,
   `ToolResultEncoding`, `PromptCacheShape`, `ErrorBodyDecoder`.
3. Adds `FramedTransport` protocol (concrete `SSETransport`/`NDJSONTransport`
   land in Phase 2/B alongside the parser-loop migration).
4. Adds `CredentialToken` opaque wrapper that redacts in
   `description`/`debugDescription`.
5. Adds `OpenAIAdapter` as the first concrete composition (no consumer yet —
   it exists so the witness composition is exercised at compile time and the
   `CloudSeamUsageAuditTest` allowlist has a concrete migrated file to point
   at by Phase 2/B).
6. Adds three Phase 2 envelope audit tests:
   - `SessionConstructionAuditTest` (cloud-scoped `URLSession(` allowlist).
   - `DNSRebindingCoverageAuditTest` (guard reference allowlist).
   - `CloudSeamUsageAuditTest` (each `*Backend.swift` either composes
     `CloudHTTPProviderAdapter` or is in a TODO-allowlist).

## Deliberately deferred to Phase 2/B (next PR)

The original Phase 2 brief bundled the following into one PR. They are
**not** in this PR because each carries non-trivial behavioural risk and
the unblocking foundation here is independently shippable. The plan's
"Pivot freedom" clause permits splitting when the diff would otherwise
exceed reviewability.

| Deferred item | Why deferred | Tracks in |
|---|---|---|
| Widen `SSECloudBackend` to consume an `CloudHTTPProviderAdapter` | Touches the envelope-level retry / cancel / stream lifecycle. Needs the full pre-push gate to validate parity. | Phase 2/B |
| Route `OpenAIBackend.buildRequest` through `OpenAIAdapter` | 580 LOC of tool-call accumulation, prefill progress, reasoning-delta handling. Shrinking 781→200 LOC without losing functionality needs careful test parity work. | Phase 2/B |
| Delete `ClaudePayloadParser.swift`, `OllamaPayloadHandler.swift`, `OllamaStreamProcessor.swift`, `ClaudeToolCallAccumulator.swift` | Phase 1b/C's deferral assumed the adapter-routed backend would no longer call these directly. Today each backend still does. Deletion is unblocked once Phase 2/B routes the calls through the adapter. | Phase 2/B |
| Delete `ClaudePayloadHandlerTests.swift`, `OllamaPayloadHandlerTests.swift`, `OpenAIResponsesPayloadHandlerTests.swift` | Mapped in `phase-1b-coverage-map.md` as Phase 2 deletion. Their replacement (enriched `CloudPayloadHandlerContractTests` fixtures) is part of the contract-suite scaffolding deferred below. | Phase 2/B |
| `InferenceBackendContractTests` scaffold + initial OpenAI fixtures (`tool-calls/simple/`, `streaming/simple-prompt/`, `usage/basic/`) | Parameterised contract suite needs fixtures recorded against a stable provider; capability-gated dispatch needs the adapter path operational. Trivially follows once Phase 2/B lands. | Phase 2/B |
| `CancellationLivenessContractTest` | Requires instrumenting each backend's driver with a test-visible observed-flag counter. Cross-cutting change touching all four cloud backends; safer to land alongside the adapter routing that introduces a uniform cancel path. | Phase 2/B |
| `CloudErrorSanitizerCoverageTest` | Requires sentinel instrumentation on `CloudErrorSanitizer` plus per-adapter forced-error paths. Both arrive cleanly when the adapter owns the throw site. | Phase 2/B |
| `SSETransport` / `NDJSONTransport` concrete impls | The protocol shape is fixed in this PR; concrete impls wrap `SSEStreamParser` (currently `package`-scoped to `ManifoldInference`). Wiring them up touches the parser visibility and is best done in the same PR that consumes them (Phase 2/B). | Phase 2/B |

## Files added (this PR)

- `Sources/ManifoldCloudCore/CredentialToken.swift`
- `Sources/ManifoldCloudCore/FramedTransport.swift` (protocol only)
- `Sources/ManifoldCloudCore/ProviderShapes.swift` (six witness protocols + 14 stub conformers)
- `Sources/ManifoldCloud/CloudHTTPProviderAdapter.swift` (composition-root protocol)
- `Sources/ManifoldCloud/OpenAIAdapter.swift` (first concrete composition; no runtime consumer yet)
- `Tests/ManifoldBackendsTests/SessionConstructionAuditTest.swift`
- `Tests/ManifoldBackendsTests/DNSRebindingCoverageAuditTest.swift`
- `Tests/ManifoldBackendsTests/CloudSeamUsageAuditTest.swift`
- `Tests/Fixtures/_migration/phase-2a-coverage-map.md` (this file)

## Files NOT modified

No runtime call paths are changed. `OpenAIBackend`, `ClaudeBackend`,
`OllamaBackend`, `OpenAIResponsesBackend`, and `SSECloudBackend` are
untouched. `CloudMessageEncoder` and `CloudPayloadHandler` are
untouched.

## Sabotage verification

Each new audit was sabotage-verified locally before commit; the violating
edits are listed below so they can be reproduced from the test source:

| Audit | Sabotage edit that should fail it | Confirmed |
|---|---|---|
| `SessionConstructionAuditTest` | Add `let _ = URLSession(configuration: .default)` to `OpenAIBackend.swift` | Yes — fails with "Unauthorized URLSession construction" |
| `DNSRebindingCoverageAuditTest` | Add `try await DNSRebindingGuard.validate(url: url)` to `OpenAIBackend.swift` | Yes — fails with "DNSRebindingGuard referenced outside the envelope" |
| `CloudSeamUsageAuditTest` | Create `Sources/ManifoldCloud/GeminiBackend.swift` with no `CloudHTTPProviderAdapter` mention | Yes — fails with "Cloud backend file(s) neither compose…" |
