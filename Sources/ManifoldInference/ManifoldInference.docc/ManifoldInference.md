# ``ManifoldInference``

Inference orchestration for ManifoldKit — protocols, models, and services that
coordinate model loading, generation, context budgeting, and prompt assembly.

## Overview

`ManifoldInference` contains the inference surface area of ManifoldKit:
``InferenceService`` and the `InferenceBackend` protocol family, generation
events and streams, context window management, prompt templates and assembly,
macro expansion, repetition detection, tokenizers, and the
capability/compatibility API.

`ManifoldInference` is the lowest production layer in ManifoldKit (apart from
`ManifoldTestSupport`). It carries no SwiftData schema, no SwiftUI views, no
ML dependencies, and no concrete inference backends — those live in higher
layers:

- `ManifoldRuntime` adds persistence-agnostic ports and use cases.
- `ManifoldPersistenceSwiftData` adds the shipped SwiftData schema and
  ``ManifoldBootstrap`` entry point.
- `ManifoldBackends` adds the concrete MLX, llama.cpp, Foundation, and cloud
  backends, depending on `ManifoldInference` directly so it stays free of
  SwiftData.

Apps that bring their own persistence and UI can depend on this target alone
to integrate a custom backend or drive a custom chat surface.

For the source-backed operational contract around loading, streaming, memory handling, cancellation, and pinning, see [`docs/RELIABILITY.md`](../../../docs/RELIABILITY.md).

## Topics

### Configuration

- ``ManifoldConfiguration``

### Inference orchestration

- ``InferenceService``
- ``InferenceBackend``
- ``BackendCapabilities``

### Conversation records

- ``ChatMessageRecord``
- ``ChatSessionRecord``
- ``MessageRole``
- ``MessagePart``

### Generation

- ``GenerationEvent``
- ``GenerationStream``

### Image generation

The image-generation value types live here (not in `ManifoldMLX`) so non-MLX
modules — catalog UIs, persistence, runtime — can reference them without
pulling in a backend family. Concrete backends (``MLXDiffusionBackend``,
``FluxDiffusionBackend``) live in `ManifoldMLX`; see that module's
documentation for the high-level vs. direct-backend chooser.

- ``ImageGenerationBackend``
- ``ImageGenerationService``
- ``ImageGenerationConfig``
- ``ImageGenerationEvent``
- ``ImageModelInfo``
- ``ImageModelFormat``
- ``PrecisionVariant``
