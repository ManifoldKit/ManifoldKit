# Plan — `BaseChatServer` (#744)

OpenAI-compatible HTTP server target that exposes any `BaseChatInference.InferenceBackend` over `/v1/chat/completions`. Lets users point Cursor, Continue, and any OpenAI-SDK client at a local Mac running BaseChatKit.

This is a **plan document**, not implementation. It records the decisions taken before code lands so reviewers can argue with the design, not the diff.

## Status

- Tracking issue: #744
- v2 deferrals umbrella: #807
- Branch: `feat/744-server-plan`
- Target release: `0.14.0` (`0.13.0` ships the tool-calling track close-out per #753 PR-C; the server gets its own headline release because the network surface is the more dangerous surface and deserves concentrated reviewer attention)
- Greenfield work — no prior server code in the repo (`grep -r "Hummingbird\|Vapor\|NIOHTTP" Sources/` returns nothing).

> **Update (#949):** The original three-target shape (`BaseChatServerCore` library + `BaseChatServerBackends` library + `BaseChatServer` executable) has been collapsed into a single `BaseChatServer` executable target. All routing, adapters, trait-aware backend provider, and the CLI entry point now live under `Sources/BaseChatServer/`. The `BaseChatServerCore` and `BaseChatServerBackends` library products no longer exist. References to those module names in the sections below are historical — the `Server` trait still gates the entire surface and the dependency boundaries (`BaseChatInference` only, `BaseChatBackends` only inside the executable wiring) are unchanged.

## What we are building

A new opt-in SwiftPM target `BaseChatServer` (executable) plus `BaseChatServerCore` (library, `package`-visible, where the routing lives). Together they implement:

- `POST /v1/chat/completions` — streaming (SSE) and non-streaming JSON. Tools, tool_choice, temperature, top_p, max_tokens, seed, stream supported.
- `GET /v1/models` — lists the single loaded model.
- `GET /health/live` and `GET /health/ready` — process liveness vs model-readiness.
- Bearer-token auth (`ApiKeyMiddleware`), conservative CORS, request-cancellation on client disconnect.
- CLI entry point with `--port`, `--bind`, `--api-key-file`, `--backend mlx|llama|foundation`, `--model <id>`, `--log-format json|text`.

Everything inference-shaped (protocols, `GenerationEvent`, cancellation, `BackendRegistrar`) already exists and is reused as-is.

## Non-goals (v1)

Tracked on #807:

- `/v1/embeddings` — depends on a real `EmbeddingBackend` (#684 was closed without one shipping).
- `/v1/completions` (legacy non-chat).
- `/metrics` Prometheus exporter — structured logs only in v1.
- Multi-model swap on the request `model:` field — single backend / single model per process in v1.
- Cloud / Ollama backend pass-through (would proxy OpenAI to OpenAI; ship-ready but pointless as a v1 headline).
- `response_format: json_schema` cross-backend — depends on #108 `StructuredOutputStrategy`.
- `n > 1`, `logprobs`, `logit_bias`, `frequency_penalty`, `presence_penalty` — return `400 invalid_request_error` rather than silently ignoring.
- `--parallel` CLI flag — dropped from v1; reintroduce alongside cloud/Ollama pass-through in v2 when there's something observable to assert.
- Pre-built signed binary distribution / Homebrew formula.
- Multi-tenant / per-key quotas / rate limiting beyond the in-process semaphore.
- Lifting `OpenAIToolEncoding` to a shared `BaseChatOpenAIWire` Codable module — duplication is real, but the extraction is a cross-cutting refactor that touches `CloudBackend` and the new server simultaneously and deserves its own PR. Plan v2 hand-rolls narrow Codable models for v1; #807 captures the convergence work.
- `case finished(reason: FinishReason)` extension to `GenerationEvent` — same reasoning. Server's private `FinishReasonDeriver` is small and isolated; v2 protocol churn collapses it cleanly to a passthrough.

## Pre-PR-A blockers

These must land **before** any source files exist under `Sources/BaseChatServer*` on disk. Discovering them at PR-A review time is the bad outcome.

1. **Extend `Tests/BaseChatInferenceTests/TrafficBoundaryAuditTest.swift` with an inbound-listener rule.** The audit today only enumerates outbound `URLSessionProvider`-style I/O. Hummingbird is the repo's first inbound networking surface. Either (a) extend the audit's allowlist with an explicit `BaseChatServerCore` scope and the reviewer sign-off the audit demands, or (b) add a sibling `InboundTrafficBoundaryAuditTest` that enforces "only `BaseChatServerCore` may bind a socket; only `BaseChatServer` (executable) may construct it." Either path is acceptable; both must precede PR-A.
2. **`MockInferenceBackend` enhancements** in `Sources/BaseChatTestSupport/`: ability to emit scripted `.usage(prompt:completion:)` events, controlled parallel tool-call lane interleaving (out-of-order `index`), throttle-then-resume semantics. `SlowMockBackend`, `ChaosBackend`, and `MidStreamErrorBackend` already exist (`Sources/BaseChatTestSupport/MidStreamErrorBackend.swift`, etc.) and are referenced as-is. Pulling these into PR-A scope so PR-B isn't bloated by test-support churn.

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Module shape: library `BaseChatServerCore` + thin executable `BaseChatServer`.** | SwiftLM's 3,068-line `Server.swift` (with documented type-checker timeouts) is a warning. Library form lets routes be unit-tested via Hummingbird's `Application.test()` against `MockInferenceBackend` from `BaseChatTestSupport` — no socket, no flake. |
| 2 | **`BaseChatServerCore` is `package`-visible**, not `public`. | Premature `public` is a one-way door — it locks routing/middleware shapes we'll want to refactor between v1 and v2. The menubar-embedding ask (#807) is the trigger for promotion to `public`; promote then. |
| 3 | **HTTP framework: Hummingbird, pinned `.upToNextMinor(from: "2.22.0")`.** | Apache 2.0, NIO-native, Swift-async-first, no Vapor ORM/templating bulk. Minor-version pin in the library; exact version locks in `Package.resolved` of the executable. Library-exact-pin is hostile to downstream consumers. `ExistentialAny` + `InternalImportsByDefault` strict-settings smoke must pass before committing the dep. |
| 4 | **CLI: `swift-argument-parser`.** | Apple-stack standard. Keeps CLI surface readable next to `bck-tools` / `fuzz-chat`. |
| 5 | **New SPM trait `Server` (opt-in, not default).** | Default dependency graph stays Hummingbird-free. Mirrors the `Fuzz` / `MCPBuiltinCatalog` precedent. Trait gating is enforced by CI lints (see CI section), not just convention. |
| 6 | **`BaseChatServerCore` depends on `BaseChatInference` only**, not `BaseChatBackends`. | The executable wires `BackendRegistrar` and concrete backends. Preserves the same one-way edge CLAUDE.md enforces for UI; unblocks #807 menubar embedding without dragging Hummingbird through anyone's default graph. |
| 7 | **v1 backends: `mlx`, `llama`, `foundation` only.** | `cloud` and `ollama` would proxy OpenAI shape to OpenAI shape — the value is local backends. Cloud pass-through is on #807. |
| 8 | **Single backend, single loaded model per process.** | Local backends serialize through one Metal context anyway. `/v1/models` returns the one. Multi-model swap is a v2 feature with real complexity (LRU eviction, memory budget). Route handlers wired against `InferenceService`, not a captured `InferenceBackend` reference, so v2 multi-model is a clean migration. |
| 9 | **Tool calling is pass-through; orchestrator disabled.** | OpenAI clients dispatch tools themselves. Server emits `tool_calls` and stops. `ToolCallLoopOrchestrator` is for in-app agent loops, not the wire protocol. |
| 10 | **`finish_reason` uses OpenAI-spec values only: `stop \| length \| tool_calls \| content_filter \| function_call`.** Errors emit `finish_reason: "stop"` plus an `error` object on the chunk. | Custom `"error"` value risks rejection by strict third-party clients (Cursor, Continue). Worker review caught this; spec-conformant from day one. |
| 11 | **Finish-reason derived in the server**, not added to `GenerationEvent`. | Keeps the protocol untouched for v1. Server's private `FinishReasonDeriver` is small and isolated. v2 may extract `case finished(reason:)` (#807) — deriver collapses to a passthrough at that point. |
| 12 | **Usage estimation for local backends via `TokenizerProvider`.** | Cloud backends populate `.usage(prompt:completion:)` from the wire; local backends don't. Estimating from the tokenizer is honest enough — better than omitting the field, which breaks OpenAI client billing/observability paths. Source declared via `x-basechat-usage-source: tokenizer-estimate` response header. |
| 13 | **Drop thinking blocks from server output for v1.** | OpenAI shape has no home for them; clients won't render them. `?include=thinking` extension lives on #807. |
| 14 | **Default bind `127.0.0.1`.** | Binding `0.0.0.0` by default is a footgun on machines that move between networks. `--bind 0.0.0.0` (or `[::]` for IPv6) must be explicit and refuses to start without `--api-key-file` or `--unsafe-no-auth`. |
| 15 | **API key sourced from `--api-key-file <path>`**, not `--api-key <value>`. | Process-table leaks via `ps` are real. `--api-key` is accepted with a deprecation note (dev-only). Comparison via `constantTimeEquals`. |
| 16 | **No `--parallel` flag in v1 CLI.** | Local backends serialize through one Metal context; flag would have no observable effect and can't be tested honestly. The internal `AsyncSemaphore` exists structurally for v2 cloud/Ollama pass-through. CLI surface re-added cleanly when there's something to assert. |
| 17 | **Unsupported OpenAI fields: 400 `invalid_request_error` with the field name.** | Silent ignore is the worst possible behavior — clients spend hours tracing "why doesn't `seed` work" when the server quietly dropped it. Loud failure beats quiet drift. |
| 18 | **Two health endpoints: `/health/live` and `/health/ready`.** | Single `/health` is ambiguous for Kubernetes / launchd / `pgrep`-style supervisors. Liveness vs readiness is a 5-LOC distinction with real value. |
| 19 | **Hand-roll narrow Codable models for `ChatCompletionRequest` / `Chunk` / `Response`.** | No shippable Swift OpenAI SDK exists that would fit. The surface we use is small (~150 LOC). `OpenAIToolEncoding` (outbound, in `Sources/BaseChatBackends/`) uses `[String: Any]` and the `#if CloudSaaS` gate is the only thing making it un-shareable; extraction to a shared `BaseChatOpenAIWire` Codable module is a real refactor but cross-cuts `CloudBackend` and the server simultaneously. **Lift on #807** as a separately-revertible PR. |
| 20 | **`AsyncSemaphore` is injectable**, not a singleton. | v2 per-model semaphores aren't a rewrite. Pass it into the route handler factory; mock-substitute in tests. |
| 21 | **Use `SSEStreamLimits` from `BaseChatInference` for response-side budget caps.** | Same defensive limits the parser enforces inbound apply outbound. One bad request shouldn't stream 50MB. Note: `SSEStreamLimits` does not enforce flow-control backpressure — Hummingbird's writer backpressure is the relevant mechanism for slow consumers (covered in test strategy). |

## Module structure

```
Sources/
  BaseChatServerCore/          # library — package-visible, routes/models/middleware, no socket
                                # depends on BaseChatInference + Hummingbird only
    Models/
      ChatCompletion+Request.swift
      ChatCompletion+Response.swift
      ChatCompletion+Chunk.swift
      OpenAIError.swift           # invalid_request_error / authentication_error / etc.
    Routes/
      ChatCompletionsRoute.swift  # POST /v1/chat/completions (streaming + non-streaming)
      ModelsRoute.swift           # GET  /v1/models  (loaded model only)
      HealthRoute.swift           # GET  /health/live, /health/ready
    Middleware/
      ApiKeyMiddleware.swift      # constantTimeEquals
      CORSMiddleware.swift
    Streaming/
      SSEEncoder.swift            # data: …\n\n framer + [DONE] sentinel
      EventMapper.swift           # GenerationEvent → ChatCompletionChunk
      FinishReasonDeriver.swift   # stream-end → spec-only "stop"|"length"|"tool_calls"
    Concurrency/
      AsyncSemaphore.swift        # injectable actor (~30 LOC; v2 swaps in per-model variant)
    Server.swift                  # buildApplication(config:) -> Hummingbird.Application

  BaseChatServer/                # executable — wires BaseChatBackends + BackendRegistrar
                                  # depends on BaseChatServerCore + BaseChatBackends + ArgumentParser
    main.swift                   # @main, parses CLI, calls buildApplication, .run()
    CLI.swift                    # ArgumentParser surface
    BackendBootstrap.swift       # selects/loads backend by --backend flag, hands InferenceService to Core

Tests/
  BaseChatServerCoreTests/
    Routes/
      ChatCompletionsRouteTests.swift
      ChatCompletionsStreamingTests.swift
      ChatCompletionsToolsTests.swift              # parallel tool-call interleaving
      ChatCompletionsUnsupportedFieldsTests.swift  # 400 per-field
      ModelsRouteTests.swift
      HealthRouteTests.swift                       # ready returns 503 before loadModel
    Middleware/
      ApiKeyMiddlewareTests.swift
      CORSMiddlewareTests.swift                    # preflight OPTIONS, --unsafe-cors-any
    Streaming/
      SSEEncoderTests.swift
      EventMapperTests.swift                       # decision-vs-test mapping (see test strategy)
      FinishReasonDeriverTests.swift               # spec values only
      MidStreamErrorTests.swift                    # backend throws mid-stream → SSE error frame
      BackpressureTests.swift                      # slow consumer respects Hummingbird writer backpressure
      RequestParsingEdgesTests.swift               # malformed JSON, oversize body, ragged UTF-8
    Concurrency/
      AsyncSemaphoreTests.swift
    Integration/
      ClientDisconnectCancellationTests.swift     # parameterized over 5 race windows
      WireCompatReplayTests.swift                  # byte-replay against canonical openai SDK fixtures
      EndToEndOpenAIClientTests.swift              # gated; vendored-wheel python -m venv (see strategy)
    Performance/
      ServerThroughputBaselines.swift              # XCTMeasure: TTFT, full-stream wall, parse+auth overhead
```

`BaseChatServerCore` deps: `BaseChatInference`, `Hummingbird`. **No `BaseChatBackends` dep.**
`BaseChatServerCoreTests` deps: `BaseChatServerCore`, `BaseChatTestSupport` (for `MockInferenceBackend`, `MidStreamErrorBackend`, etc.), Hummingbird's `XCTHummingbird` test product.
`BaseChatServer` (executable) deps: `BaseChatServerCore`, `BaseChatBackends`, `swift-argument-parser`.

## Wire mapping

`GenerationEvent` → OpenAI SSE chunks. **Primary tool-call path is whole-call `.toolCall(_)`.** Among v1 backends, `MLXBackend` is the only one with `supportsToolCalling: true` (`LlamaBackend` and `FoundationBackend` both declare `supportsToolCalling: false`). MLX's `BackendCapabilities` literal at `Sources/BaseChatBackends/MLXBackend.swift:57` does not set `streamsToolCallArguments`, so it defaults to `false` and MLX emits whole calls. The streamed-delta path exists for Ollama / cloud (`OllamaBackend.swift:123`, `OpenAIBackend.swift:81`, `ClaudeBackend.swift:93`) and is exercised by the expansion path below — gated out of v1 by decision 7.

| `GenerationEvent` case | OpenAI chunk |
|---|---|
| `.token(s)` | `choices[0].delta.content = s` |
| `.toolCall(call)` *(primary v1 path)* | Single chunk: `choices[0].delta.tool_calls[idx] = {id, type: "function", function: {name, arguments: <full JSON>}}`, immediately followed by stream end with `finish_reason: "tool_calls"` |
| `.toolCallStart(id, name)` *(expansion path)* | `choices[0].delta.tool_calls[idx] = {id, type: "function", function: {name}}` |
| `.toolCallArgumentsDelta(id, frag)` *(expansion path)* | `choices[0].delta.tool_calls[idx].function.arguments = frag` |
| `.usage(p, c)` | `usage = {prompt_tokens: p, completion_tokens: c, total_tokens: p+c}` on final chunk if `stream_options.include_usage = true` |
| `.prefillProgress(nPast, nTotal, tokensPerSecond)` | `event: prefill_progress\ndata: {n_past, n_total, tokens_per_second}\n\n` — emitted only when request has `X-BaseChat-Prefill-Progress: true` header (per #804 contract) |
| `.thinkingToken(_)` / `.thinkingComplete` / `.thinkingSignature(_)` | dropped (v1) |
| `.toolResult(_)` | dropped (server is pass-through; client owns dispatch) |
| `.kvCacheReuse(_)` / `.diagnosticThrottle(_)` | dropped (internal signals) |
| `.toolLoopLimitReached(_)` | derive `finish_reason: "length"` |
| stream end clean | derive `finish_reason: "stop"` (or `"tool_calls"` if any tool-call event seen) |
| stream error | emit `data: {"choices":[{"finish_reason":"stop"}], "error": {…}}\n\n` then close — spec-conformant `finish_reason` plus diagnostic |

## Operability

- **Signal handling.** `SIGTERM`: graceful shutdown — stop accepting new connections, drain in-flight streams up to a `--shutdown-grace 30s` deadline, then force-close. `SIGINT`: same as `SIGTERM` but with a 5s grace for foreground use. Document that long-running generations may be cut off; clients see clean SSE disconnect.
- **Logging.** `--log-format text` (default, human-readable) or `--log-format json` (one structured object per line, machine-parseable). Include request id, route, status, duration, backend, model. No request bodies, no API keys, no full prompts at default log level.
- **Crash visibility.** Uncaught errors in route handlers surface via `OSLog` with category `com.basechatkit.server` so they're visible in Console.app and `log stream`. Stack traces only at `--log-level debug`.
- **Bind errors.** Friendly message on `EADDRINUSE`: `port 8080 is already in use; pass --port to choose another` (not the default NIO error). Same for permission-denied on low ports: `binding to port 80 requires elevated permissions; consider --port 8080 with a reverse proxy`.
- **README honesty checklist.** Quarantine attribute (`xattr -d com.apple.quarantine`) for downloaded builds, App Translocation surprises when run from `~/Downloads`, plaintext `--api-key-file` posture (recommend `chmod 600`), no built-in TLS — point to Caddy / cloudflared for HTTPS termination.

## Cancellation

The framework already has the contract: `stopGeneration()` cancels the in-flight stream and resets backend state, and structured concurrency propagates from Hummingbird's per-request task. When the client disconnects mid-stream:

1. Hummingbird cancels the response task.
2. The route handler's `for try await event in stream.events` throws `CancellationError`.
3. `defer { backend.stopGeneration() }` fires.
4. `MLXBackend.stopGeneration()` (or whichever) tears down state and is ready for the next request.

This needs **parameterized acceptance tests** (`ClientDisconnectCancellationTests`) — five race windows enumerated:

1. Disconnect between tokens.
2. Disconnect during a token (mid-byte on the wire).
3. Disconnect during tool-call argument streaming (expansion path only).
4. Disconnect after `[DONE]` but before connection drain.
5. `stopGeneration()` itself throws or hangs — assert no deadlock and the response task still completes.

## Test strategy

Per CLAUDE.md: real `async/await`, no fixed timeouts, sabotage check on every assertion (temporarily break the code path, confirm test fails) before commit.

### Suites

All 13 suites listed in the module structure above. Highlights:

- **Routes:** happy paths, plus malformed JSON, oversize body (>1 MiB cap), ragged UTF-8, empty messages, `max_tokens: 0`, system-prompt-only requests, missing/wrong-scheme auth header, header injection attempts.
- **Streaming:** `EventMapperTests` drives a synthetic `AsyncStream<GenerationEvent>` and asserts SSE bytes. Includes the parallel-tool-call expansion case (`index=1` deltas before `index=0` start, deltas without preceding start, conflicting authoritative `.toolCall` after streamed deltas).
- **Backpressure:** `BackpressureTests` writes faster than the test client reads; assert Hummingbird's writer backpressure pauses the producer rather than buffering unbounded.
- **Mid-stream errors:** `MidStreamErrorTests` uses `Sources/BaseChatTestSupport/MidStreamErrorBackend.swift` to throw at token N; assert clean SSE error frame and `stopGeneration()` invoked exactly once.
- **`stream_options.include_usage`:** explicit suite — present + true emits final chunk with `usage`; absent or false omits.
- **Auth/CORS:** matrix over (header missing, wrong scheme, valid, invalid), and CORS preflight `OPTIONS` with single-origin and `--unsafe-cors-any`.
- **Cancellation:** five parameterized race windows above.
- **Performance:** `XCTMeasure` baselines for TTFT (time-to-first-token), full-stream wall time, and parse+auth overhead per request. Set baselines in PR-B; cheaper than retroactive.

### Decision-vs-test mapping

Every behavioral decision needs a test that fails on regression. The sparse cells in this table are the gaps the plan fills.

| Decision | Test that would fail on regression |
|---|---|
| 10 — `finish_reason` spec values only | `FinishReasonDeriverTests.testNeverEmitsCustomErrorValue` |
| 12 — usage estimation for local backends | `EventMapperTests.testLocalBackendEmitsTokenizerEstimate` + `x-basechat-usage-source` header assertion |
| 14 — default bind 127.0.0.1; refuse `0.0.0.0` without auth | `CLITests.testBindZeroRequiresApiKeyOrUnsafeFlag` |
| 15 — `--api-key-file` preferred | `CLITests.testApiKeyOnCliEmitsDeprecationWarning` |
| 17 — 400 on unsupported fields | `ChatCompletionsUnsupportedFieldsTests` per-field cases (n>1, logprobs, logit_bias, frequency_penalty, presence_penalty) |
| 18 — `/health/ready` 503 before model load | `HealthRouteTests.testReadyReturns503BeforeLoadModel` |

### Wire-compatibility strategy

Plan v1 said "shell out to `python -c 'from openai import OpenAI'`". Replaced for v2:

- **Primary:** `Tests/BaseChatServerCoreTests/Integration/WireCompatReplayTests.swift` — Swift byte-replay suite mirroring `Tests/BaseChatBackendsTests/CloudBackendSSETests.swift` (which validates outbound parsing). Same fixture format, opposite direction. SDK-version-independent, deterministic, runs in CI.
- **Sanity:** one `EndToEndOpenAIClientTests` gated on `RUN_SERVER_E2E=1`. Uses `python -m venv` + a vendored wheel (pinned `openai==1.x.y`) to avoid depending on contributor Python state. Not in default CI.
- **Cursor / Continue / strict-client compatibility:** manual smoke checklist in the PR-C README. Not testable in CI; document it honestly.

## Security posture

- Default bind `127.0.0.1` (IPv6 equivalent: `--bind ::1`). `--bind 0.0.0.0` or `--bind [::]` requires either `--api-key-file` to be set OR `--unsafe-no-auth` to be passed explicitly. Refuse to start otherwise.
- API key compared with `constantTimeEquals` to avoid timing oracles. (Statistical timing test for the constant-time-compare primitive itself lives on #807 — single-sample timing tests are noise; needs a proper microbenchmark harness.)
- CORS disabled by default. `--cors-origin <origin>` accepts a single origin; `--unsafe-cors-any` is required to allow `*`.
- Request body size capped at 1 MiB (configurable via `--max-request-bytes`). Defends against accidental large pastes.
- Response stream capped using `SSEStreamLimits` defaults (50 MiB total, 5000 events/sec).
- Errors funneled through `OpenAIError` enum with explicit code mapping — never leak Swift type names or stack traces.
- No file paths, model names, or backend identifiers logged at default level — only at `--log-level debug`.
- **No built-in TLS.** HTTP only; document Caddy / cloudflared / nginx as the recommended path for HTTPS. v1 is opinionated about staying out of the certificate-management business.
- **IPv6.** `--bind ::1` and `[::]` supported; `[::]` triggers the same auth gate as `0.0.0.0`.
- Dependency review: Hummingbird and ArgumentParser are both Apache 2.0, MIT-compatible. No new transitive deps that haven't been vetted.

## CI

Add to the existing batch test step (do not introduce a third `swift test` invocation — CLAUDE.md flags single-feature PRs as a smell, and a separate step for one suite pays full process bring-up at 10× macOS billing):

```bash
swift test --filter BaseChatServerCoreTests --disable-default-traits --traits Server
```

Append to the batch invocation at `.github/workflows/ci.yml:166`. The `Server` trait is required because the test target depends on Hummingbird; if the trait is off, the target compiles to zero files and the filter no-ops — same pattern as `Ollama` / `Fuzz` today.

### Trait & dep-graph guards

Three lints, all in CI, all falsifiable:

1. **Default-graph cleanliness** (`swift package show-dependencies --disable-default-traits --format flatlist | grep -qv hummingbird`). Fails if Hummingbird leaks into the default graph — proves trait gating works.
2. **Import-grep guard** mirroring the existing UI→ModelManagement guard at `.github/workflows/ci.yml:105-117`: no source file outside `Sources/BaseChatServer*` may `import Hummingbird`.
3. **400-LOC file ceiling** for files under `Sources/BaseChatServer*` — `find Sources/BaseChatServer* -name '*.swift' -exec wc -l {} \; | awk '$1 > 400 {exit 1}'`. Hard rule, not plan prose. The SwiftLM cautionary tale is what this prevents.

CI-time impact: a third `swift test` invocation would be ~30s mostly link **plus** full process bring-up plus first-time Hummingbird/NIO compile (closer to 60–90s). Folding into the existing batch step is ~30s genuinely (link only, since the build cache is hot).

## Rollout

Compressed from 6 PRs to 3. Each independently reviewable, CI-green at every step, revertable.

1. **PR-A — skeleton + non-streaming + middleware + test-support deltas.** `Package.swift` trait + targets, all Codable models, `/v1/chat/completions` non-streaming, `/v1/models`, `/health/{live,ready}`, `ApiKeyMiddleware`, `CORSMiddleware`, `MockInferenceBackend` enhancements (scripted `.usage`, controlled tool-call lane interleaving). Routes tested against the mock. Pre-PR-A blockers (TrafficBoundaryAudit extension) land first. ~700 LOC + test-support.
2. **PR-B — streaming + tools + cancellation + performance baselines.** `SSEEncoder`, `EventMapper`, `FinishReasonDeriver`, parallel tool-call interleaving tests, `ClientDisconnectCancellationTests` (parameterized over 5 race windows), `WireCompatReplayTests`, `XCTMeasure` baselines. ~700 LOC.
3. **PR-C — CLI + executable + README + manual smoke.** `ArgumentParser` surface, `BackendBootstrap`, executable `main.swift`, README section with operability checklist, manual smoke against `mlx-community/Llama-3.2-3B-Instruct-4bit` and a real `openai` Python client. Closes #744. ~300 LOC.
4. **Release 0.14.0.** Highlight section in CHANGELOG with a 6–8 line code snippet showing `swift run BaseChatServer --backend mlx --model …` → `from openai import OpenAI; client.chat.completions.create(...)`.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Hummingbird API churn between minor versions | `.upToNextMinor(from: "2.22.0")` in `Package.swift`; `Package.resolved` exact-pin in the executable. Bump deliberately on minor. |
| Local-backend usage estimates diverge from cloud actuals enough to break observability tools | Document the source explicitly via `x-basechat-usage-source: tokenizer-estimate` response header; revisit in v2 with a real counting hook. |
| Client disconnect doesn't propagate cancellation in some Hummingbird configuration | Five parameterized acceptance tests on day one. Easy to detect, painful in production. |
| Parallel tool-call events arrive out of order across `index` lanes and break OpenAI's strict-index expectation | `EventMapperTests` covers interleaved lanes; `ToolCallLoopOrchestrator` already sorts by batch index for KV-prefix stability (#783), so the upstream ordering is correct. |
| OpenAI SDK clients reject responses with our spec-conformant but unusual error chunks | `WireCompatReplayTests` byte-replay against pinned `openai` SDK fixtures; one gated end-to-end against the real SDK as sanity. |
| Server target pulls Hummingbird into the default graph by accident | CI lint at the dep-graph level + import-grep lint, both falsifiable, both runs every PR. |
| Type-checker timeouts (the SwiftLM cautionary tale) | Module split + 400-LOC file ceiling enforced by CI, not plan prose. |
| `AsyncSemaphore` ossifies into a singleton, blocking v2 per-model swap | Injectable from day one (decision 20). |
| Hummingbird strict-concurrency settings (`ExistentialAny`, `InternalImportsByDefault`) force unexpected refactors | Smoke-build the dep before PR-A merges; surface conflicts now not at PR-B review time. |

## Open questions for review

All four resolved.

1. ~~Release window~~ → **0.14.0**. Server is the more dangerous surface and deserves its own headline; #753 PR-C is the more compelling 0.13.0 story.
2. ~~`BaseChatServerCore` public vs `package`~~ → **`package`**. Premature `public` is a one-way door; promote when the menubar embedding ask (#807) materializes.
3. ~~`--parallel` flag in v1~~ → **dropped**. Cargo-cult surface; reintroduce with cloud/Ollama pass-through in v2.
4. ~~`/v1/models` shape~~ → **loaded model only**. Disk-scanning pulls in filesystem flake; route handlers wired against `InferenceService` (not a captured backend reference) keep v2 multi-model migration clean.

---

## Post-merge update (2026-05-02)

`BaseChatServer` was put behind a new `Server` SwiftPM trait (off by default)
in PR #946 after the initial release inadvertently doubled per-PR CI wall
time. The architectural pattern is unchanged; only the build-graph membership
was scoped down. See `Package.swift` `traits:` block and `#if Server` guards
in `Sources/BaseChatServer*/`.
