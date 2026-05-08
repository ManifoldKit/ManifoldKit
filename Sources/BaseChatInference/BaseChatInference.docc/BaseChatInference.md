# ``BaseChatInference``

Inference orchestration for BaseChatKit — protocols, models, and services that
coordinate model loading, generation, context budgeting, and prompt assembly.

## Overview

`BaseChatInference` contains the inference surface area of BaseChatKit:
``InferenceService`` and the `InferenceBackend` protocol family, generation
events and streams, context window management, prompt templates and assembly,
macro expansion, repetition detection, tokenizers, and the
capability/compatibility API.

`BaseChatInference` is the lowest production layer in BaseChatKit (apart from
`BaseChatTestSupport`). It carries no SwiftData schema, no SwiftUI views, no
ML dependencies, and no concrete inference backends — those live in higher
layers:

- `BaseChatRuntime` adds persistence-agnostic ports and use cases.
- `BaseChatPersistenceSwiftData` adds the shipped SwiftData schema and
  ``BaseChatBootstrap`` entry point.
- `BaseChatBackends` adds the concrete MLX, llama.cpp, Foundation, and cloud
  backends, depending on `BaseChatInference` directly so it stays free of
  SwiftData.

Apps that bring their own persistence and UI can depend on this target alone
to integrate a custom backend or drive a custom chat surface.

For the source-backed operational contract around loading, streaming, memory handling, cancellation, and pinning, see [`docs/RELIABILITY.md`](../../../docs/RELIABILITY.md).

## Topics

### Configuration

- ``BaseChatConfiguration``

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
