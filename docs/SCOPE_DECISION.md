# Scope Decision — ManifoldKit 0.6.0

## Why we slimmed ManifoldKit

Consumer audits of ManifoldKit's two known consumers — a private internal app and the public [ChatbotUI-iOS](https://github.com/roryford/ChatbotUI-iOS) demo — showed that less than half of the codebase had any real demand. Several large subsystems had zero consumers at all, and several more had a single consumer that used only a narrow slice of the public API. The April 2026 feature-expansion plan that introduced most of this surface area was built without this data, so 0.6.0 is the correction: we are deleting what nobody used and repositioning ManifoldKit around what actually makes it valuable to the apps that ship it.

## Consumer audit summary

| Capability | Internal consumer | ChatbotUI-iOS |
|---|---|---|
| `InferenceService` + `DefaultBackends` | transparent-use | transparent-use |
| `ChatViewModel` | ✓ | ✓ |
| `ChatView` (drop-in) | ✗ | ✓ |
| `SessionListView` (drop-in) | ✗ | ✓ |
| `ModelManagementSheet` | ✗ | ✓ |
| `APIConfigurationView` | ✗ | ✓ |
| HuggingFace downloader | ✗ | ✓ |
| Compression pipeline | ✓ | ✗ |
| Macro system (full) | ✓ | ✗ (uses a single `{{user}}` substitution) |
| Server discovery | ✗ | ✗ |
| Tool calling | ✗ | ✗ |

The internal consumer is the original home of the compression pipeline and exercised the full macro system through an app-level engine built on top of it. ChatbotUI-iOS is the drop-in consumer — it takes the UI wholesale (`ChatView`, `SessionListView`, `ModelManagementSheet`, `APIConfigurationView`) plus the HuggingFace downloader, and only ever needed a single `{{user}}` substitution in the system prompt. Neither consumer uses server discovery, the benchmark runner, or the tool-calling public API.

## What's leaving in 0.6.0

- **KoboldCpp backend** — zero consumers on either audited app, no evidence of external interest, pure maintenance cost.
- **Server discovery subsystem** (~1,643 LOC) — zero consumers; built speculatively for a "find local LLM servers on the LAN" flow that never shipped.
- **Tool calling public API** (~800+ LOC) — zero consumers; the public surface is being removed while we audit the underlying `MessagePart` tool cases separately.
- **`MessagePart` tool cases** — pending schema audit; removed from the public API in 0.6.0 but kept in the persistence layer until the migration path is clear.

## What's staying (and why)

- **Streaming resilience** — production failure mode where transient network loss, provider 429s, or cold TLS handshakes kill a stream mid-token. We caught this because ManifoldKit runs in apps that ship to real users on real networks, not just demo flows.
- **Model handoff (latest-wins `LoadRequestToken`)** — production failure mode where the user taps model A, then model B before A finishes loading, and the stale A load corrupts the active state. We caught this because ManifoldKit runs in apps where users actually change their mind.
- **Memory pressure auto-unload** — production failure mode where iOS pages out the loaded model silently and the next generation crashes on a zero pointer. We caught this because ManifoldKit runs on real devices that also run Safari, Messages, and background tasks.
- **Mock backend (`MockInferenceBackend`)** — production failure mode where an app-level feature depends on ManifoldKit's streaming contract and has no way to test it without loading a real model. We caught this because ManifoldKit consumers write XCTests.
- **Certificate pinning (fail-closed on known cloud APIs)** — production failure mode where a mis-configured device trusts a compromised CA and silently leaks chat traffic. We caught this because ManifoldKit ships cloud backends that actually get used in production.

The concrete, implementation-backed version of those guarantees lives in [RELIABILITY.md](RELIABILITY.md).

## Positioning

ManifoldKit is a drop-in chat framework with operational reliability guarantees, optimized for the ChatbotUI-iOS-shaped consumer: take `ChatView`, `SessionListView`, and `ModelManagementSheet` wholesale, inject an `InferenceService`, and compose app-level features on top of the `ChatViewModel` API. The value is not "we support every backend" — it's "your chat UI keeps working when the network flickers, the user changes their mind mid-load, or iOS decides to reclaim your model's memory."

AnyLanguageModel optimizes for provider abstraction — one protocol, many providers, API familiarity with Apple's `FoundationModels`. ManifoldKit optimizes for production failure modes — drop-in UI, operational reliability, and the things that go wrong between the demo and the App Store review. These are adjacent but distinct positions. We don't compete on backend count; we compete on what happens when the demo ends.

## Deferred to Weeks 2-3

- **Compression repatriation** — the compression pipeline was originally extracted from the internal consumer and will be moved back there once that app has a clean extraction path. It stays in ManifoldKit 0.6.0 to avoid breaking the internal consumer mid-release.
- **Macro engine deletion** — the full macro system had only one consumer and is being deleted from ManifoldKit now that consumer has taken ownership of its own expander. ChatbotUI-iOS's single-field usage migrates to the `systemPromptContext` property added in 0.6.0.
- **`ManifoldInference` target extraction** — splitting the inference-only surface out of `ManifoldCore` so that UI-less consumers (server-side, CLI tools, test harnesses) can depend on the engine without pulling SwiftUI types. Target for 0.7.0.

## Consumer impact

The internal consumer keeps building on its own vendored expander, so the ManifoldKit-side deletion does not affect it.

ChatbotUI-iOS migrates its single-field usage from the old context property to the `systemPromptContext` dictionary: the dict was added in 0.6.0 as the forward-compatible replacement for that specific use case. Drop-in UI, `ChatViewModel`, `ModelManagementSheet`, `APIConfigurationView`, and the HuggingFace downloader all remain unchanged.

---

# Scope Decision — Gemini: bridge, not native backend (2026-06)

**Decision: reach Gemini through the AnyLanguageModel bridge. Do not write a native Gemini backend at this time.**

Context: graduating the AnyLanguageModel bridge to the documented provider-breadth path (issue #1638) raised the question of whether Gemini specifically warrants a native backend. Gemini is high-demand, and its API surfaces thinking/reasoning tokens that the generic bridge flattens (the bridge advertises `supportsThinking = false` and streams plain text only).

Why bridge:

- **Provider breadth is the goal, not per-provider depth.** The bridge unlocks Gemini, xAI, Groq, Mistral, OpenRouter, and others through one adapter. A native Gemini backend buys depth for one provider at the cost of an Nth cloud backend to maintain (auth, retry, pinning, streaming wire format, tool-call dialect, capability probe, conformance suite).
- **The current gap is bounded and documented.** Bridged Gemini loses reasoning-token fidelity and ManifoldKit's operational guarantees (pinning, retry, circuit breaker, latest-wins cancellation). Both are stated in [PROVIDER-BRIDGE.md](PROVIDER-BRIDGE.md) so the limitation is visible, not silent.
- **No measured consumer demand for native Gemini yet.** Consistent with the "delete what nobody used" discipline of 0.6.0, a native backend is speculative surface area until demand is observed.

Revisit trigger — promote Gemini to a native backend when **either** holds:

- A shipping consumer needs Gemini reasoning/thinking-token streaming (the bridge's flattening becomes a product gap, not a cosmetic one), or
- A shipping consumer needs the operational guarantees (pinning / retry / circuit breaker / latest-wins) on Gemini traffic specifically.

Until then, Gemini is a first-class **bridged** provider: documented, surfaced in the Feature Matrix, and held to the universal backend contract by `AnyLanguageModelConformanceTests`.
