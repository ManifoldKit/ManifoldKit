# ``ManifoldFoundation``

The Apple Foundation Models bridge — an on-device ``InferenceBackend`` backed by
the system model, gated to OS releases that ship it.

## Overview

`ManifoldFoundation` adapts Apple's Foundation Models into ManifoldKit's
``/ManifoldContract/InferenceBackend`` contract via ``FoundationBackend`` and
the `FoundationBackends` registrar. It is available only where the system
framework is (`#if canImport(FoundationModels)`, iOS 26 / macOS 26+); on older
OSes it compiles to an empty surface, so register it conditionally. The cloud
families and this Foundation backend are the engines compiled into core — the
on-device MLX and llama.cpp families ship as companion packages.

## Conversation history

Each generation uses the request's `GenerationRuntimeHints.history` as its
complete conversation. The backend reconstructs a fresh native transcript, so
restoring a session includes earlier turns and trimming, editing or branching
cannot retain turns that the caller removed. The latest user message is sent
once; tool continuations instead send the pending tool results once. ManifoldKit
continues to own tool approval and execution.

Empty history means a single-turn request. Direct backend callers must supply
history on each call to retain earlier context; reusing a backend instance alone
does not retain a conversation. `InferenceService` supplies this history for its
message-based entry points. Instructions and the selected tool catalogue are
applied anew on each request. Rebuilding may sacrifice native session cache reuse.

This bridge replays text and tool records on iOS 26 / macOS 26 and later. Private
reasoning is excluded from text context. Media, unknown roles, and a history that
ends with an assistant response instead of a pending user/tool turn are rejected
with an error. Vision support remains disabled.

## Topics

### Backend

- ``FoundationBackend``
