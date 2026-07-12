# ``ManifoldAnyLanguageModel``

The AnyLanguageModel provider bridge — one `InferenceBackend` over HuggingFace's
[AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) package, reaching
providers ManifoldKit has no native backend for (Gemini, xAI, Groq, Mistral, OpenRouter).

## Overview

`ManifoldAnyLanguageModel` adapts AnyLanguageModel's session layer into ManifoldKit's
``/ManifoldContract/InferenceBackend`` contract via ``AnyLanguageModelBackend``. Requests
routed through it do **not** inherit ManifoldKit's certificate pinning, retry strategy,
circuit breaker, or latest-wins cancellation guarantees — AnyLanguageModel owns those
concerns internally. See [docs/PROVIDER-BRIDGE.md](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/PROVIDER-BRIDGE.md)
for the full setup recipe and provider-URL scheme reference.

## Semver-exempt (#2209)

This module is **semver-exempt** — see [docs/API-DESIGN.md § 7](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/API-DESIGN.md).
``AnyLanguageModelDescriptor/model`` types its stored property as `any LanguageModel`, a
protocol owned by the external AnyLanguageModel package (pinned pre-1.0). This module's
entire purpose is bridging that dependency, so **its stability tracks AnyLanguageModel's
release cadence, not ManifoldKit's.** A breaking change in the upstream package can force a
breaking change here in any ManifoldKit minor release, migration-noted in the changelog but
without a deprecation cycle. A wrapper type would not change this — it would still break
whenever the upstream protocol does, while adding a layer consumers must learn.

## Topics

### Backend

- ``AnyLanguageModelBackend``

### Model resolution

- ``AnyLanguageModelDescriptor``
- ``AnyLanguageModelResolver``
- ``AnyLanguageModelURLResolver``

### Capabilities and errors

- ``AnyLanguageModelBridgeCapabilities``
- ``AnyLanguageModelBridgeError``
