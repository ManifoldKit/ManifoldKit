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

## Topics

### Backend

- ``FoundationBackend``
