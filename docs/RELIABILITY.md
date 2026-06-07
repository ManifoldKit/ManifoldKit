# Reliability contract

This document describes the operational behavior ManifoldKit implements today. It is intentionally narrower than product copy: if a behavior is not backed by the current source, it is not promised here.

## Model handoff

`InferenceService` gives every `loadModel(...)` and `loadCloudBackend(...)` call a monotonic `LoadRequestToken` and only allows the newest token to commit. If an older load finishes after a newer request has started, the older success is unloaded instead of replacing the active backend, and the older failure is ignored for visible state transitions. `unloadModel()` invalidates every outstanding token before clearing the active backend, so a late completion cannot resurrect a model the user already switched away from. Load progress is token-scoped as well: stale loads stop updating `modelLoadProgress`. The coordination logic lives in [`Sources/ManifoldInference/Services/InferenceService.swift`](../Sources/ManifoldInference/Services/InferenceService.swift).

The same service also serializes queued generation. `enqueue(...)` runs one backend generation at a time, orders queued work by priority, and only advances after the consumer calls `generationDidFinish()`. That is a real contract, not a convenience API: if the caller forgets to signal completion, the queue stays blocked.

## Streaming resilience

For the SSE-based cloud backends, retry logic exists, but it is narrower than "retry the whole stream until it works." `SSECloudBackend` wraps only the connection/setup phase — the `URLSession.bytes(for:)` call plus HTTP status validation — in [`withRetry(...)`](../Sources/ManifoldInference/Services/RetryPolicy.swift). The default strategy is exponential backoff with jitter (`maxRetries: 3`, `baseDelay: 1s`, `maxTotalDelay: 60s`) and it honors `Retry-After` when a provider returns HTTP 429. Retries only happen for errors that declare themselves retryable in [`CloudBackendError`](../Sources/ManifoldModelCatalog/CloudBackendError.swift): rate limits, network errors, timeouts, `streamInterrupted`, and 5xx server errors. Authentication failures, parse errors, invalid URLs, missing keys, and backend deallocation are surfaced immediately.

Once the first response bytes arrive, parsing runs outside the retry wrapper. That means ManifoldKit preserves partial output instead of replaying the request from the top: if a provider sends tokens and then fails, the error is surfaced to the stream rather than hidden behind a transparent retry. `GenerationStream` can expose `.retrying`, `.stalled`, `.failed`, and an idle-timeout-driven `.timeout(...)` path, but the backends in `ManifoldBackends` leave `streamIdleTimeout` unset by default, so stall detection is opt-in rather than automatic. See [`Sources/ManifoldCloudCore/SSECloudBackend.swift`](../Sources/ManifoldCloudCore/SSECloudBackend.swift), [`Sources/ManifoldInference/Services/GenerationStream.swift`](../Sources/ManifoldInference/Services/GenerationStream.swift), and [`Sources/ManifoldInference/Services/SSEStreamParser.swift`](../Sources/ManifoldInference/Services/SSEStreamParser.swift).

## Memory behavior

ManifoldKit has two separate memory defenses. The first is preflight admission control through [`ModelLoadPlan`](../Sources/ManifoldHardware/ModelLoadPlan.swift), which is built by callers (or automatically by the drop-in UI) before a load commits. For `resident` backends it estimates roughly the full model file size plus KV cache; for `mappable` backends it estimates roughly 25% of the file size plus KV; for `external` backends it always allows the load. When the plan returns a `.deny` verdict, `InferenceService` applies [`LoadDenyPolicy`](../Sources/ManifoldHardware/LoadDenyPolicy.swift) — `.throwError` (iOS default), `.warnOnly` (macOS default), or `.custom` with full access to the plan's `reasons`.

The second is runtime memory-pressure handling. [`MemoryPressureHandler`](../Sources/ManifoldHardware/MemoryPressureHandler.swift) reports `.nominal`, `.warning`, and `.critical`, but it does not unload anything by itself. In the drop-in UI, [`ChatViewModel.handleMemoryPressure()`](../Sources/ManifoldUI/ViewModels/ChatViewModel+MemoryPressure.swift) shows a warning banner at `.warning` and stops generation plus unloads the model at `.critical`. If an app never starts monitoring or never forwards those events into the view model, there is no automatic unload path. Also, despite the handler comment mentioning "pause heavy work," the current UI behavior does not pause generation at `.warning`; only `.critical` triggers a stop and unload.

## Cancellation semantics by backend

Cancellation is not identical across backends, and the current implementation exposes that difference through [`BackendCapabilities.cancellationStyle`](../Sources/ManifoldHardware/BackendCapabilities.swift).

`LlamaBackend` is the only backend marked `.explicit`. Its `stopGeneration()` sets an internal `cancelled` flag and cancels the active task; the llama.cpp loop checks that flag between sampling and decode steps. `unloadModel()` clears observable state immediately, invalidates any in-flight load token, and frees the C resources only after the generation task has exited, which avoids use-after-free races. See [`Sources/ManifoldLlama/LlamaBackend.swift`](../Sources/ManifoldLlama/LlamaBackend.swift).

`MLXBackend`, `FoundationBackend`, and the `SSECloudBackend` family (`OpenAIBackend`, `ClaudeBackend`, `OllamaBackend`) are `.cooperative`: they cancel the active Swift task and let the generation loop unwind. `FoundationBackend` goes further and discards its `LanguageModelSession` after cancellation so a partial cancelled turn is not kept in later conversation history. See [`Sources/ManifoldMLX/MLXBackend.swift`](../Sources/ManifoldMLX/MLXBackend.swift), [`Sources/ManifoldFoundation/FoundationBackend.swift`](../Sources/ManifoldFoundation/FoundationBackend.swift), and [`Sources/ManifoldCloudCore/SSECloudBackend.swift`](../Sources/ManifoldCloudCore/SSECloudBackend.swift).

At the service layer, `InferenceService.cancel(_:)` removes a queued request immediately or stops the active request and drains the next one. `InferenceService.stopGeneration()` cancels the active request and every queued request. Queue consumers see their outward-facing `GenerationStream` transition to a cancelled failure path even if the backend stream itself simply finishes after task cancellation. One detail that is important for callers: some cooperative backends clear `isGenerating` during asynchronous cleanup rather than synchronously inside `stopGeneration()`, so ManifoldKit does not currently provide a cross-backend guarantee that `isGenerating == false` the instant `stopGeneration()` returns.

## Test backends

`ManifoldTestSupport` ships a real test double rather than a stub-only protocol mock. [`MockInferenceBackend`](../Sources/ManifoldTestSupport/MockInferenceBackend.swift) implements `InferenceBackend`, yields a real `GenerationStream`, and can be configured to fail at load time, fail before generation starts, or throw from inside the stream after some tokens have already been produced. It also records call counts and the last prompt, system prompt, config, and conversation history it saw. `stopGeneration()` finishes the active continuation, which makes it suitable for app-level tests that need to exercise the same streaming and cancellation surface the real backends use.

If you need harsher timing and failure-path tests, the same target also includes `SlowMockBackend` and `ChaosBackend`, but `MockInferenceBackend` is the baseline contract-oriented fake.

## Certificate pinning

OpenAI and Claude use [`URLSessionProvider.pinned`](../Sources/ManifoldCloudCore/URLSessionProvider.swift) by default, which installs [`PinnedSessionDelegate`](../Sources/ManifoldCloudCore/PinnedSessionDelegate.swift). The delegate loads default SPKI pins for `api.openai.com` and `api.anthropic.com`; those two hosts are treated as required pinned hosts, so a missing or empty pin set cancels the TLS challenge instead of falling back to system trust. `localhost`, `127.0.0.1`, and `::1` always bypass pinning.

For custom hosts, the behavior is weaker by design. If the hostname is not one of the required production hosts and `PinnedSessionDelegate.pinnedHosts` does not contain pins for it, the delegate falls back to normal platform trust evaluation. That means `APIProvider.custom` is not automatically pinned even though it is routed through `OpenAIBackend`; the host app must populate `PinnedSessionDelegate.pinnedHosts` itself if it wants pinning for that endpoint. `OllamaBackend` uses [`URLSessionProvider.unpinned`](../Sources/ManifoldCloudCore/URLSessionProvider.swift) by default, so local and LAN deployments are unpinned unless the app opts into something stricter. See [`Sources/ManifoldBackendsUmbrella/DefaultBackends.swift`](../Sources/ManifoldBackendsUmbrella/DefaultBackends.swift).

## What is not guaranteed

- ManifoldKit does **not** currently implement a circuit breaker.
- ManifoldKit does **not** automatically reconnect or resume a stream after bytes have started arriving; retries cover connection setup, not mid-stream replay.
- The default cloud backends do **not** enable idle-timeout detection unless the app sets `streamIdleTimeout`.
- `CloudBackendError.streamInterrupted` exists, but the default SSE/NDJSON backends do not currently synthesize it for a silent EOF.
- `InferenceService` alone does **not** monitor memory pressure; the app has to wire `MemoryPressureHandler` into a consumer such as `ChatViewModel`.
- Arbitrary custom HTTPS hosts are **not** pinned unless the host app configures pins for them.
- `stopGeneration()` does **not** have a universal "backend is fully quiesced before return" guarantee across every current backend.
