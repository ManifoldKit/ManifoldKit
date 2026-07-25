# Migration: `BackendVisionCapability.llamaSupportsImageInput` is probed

**Audience:** companion backend authors (primarily `ManifoldLlama`)
**Status:** living

**This is a breaking change.** The llama vision capability gate is no longer a
hardcoded `false` property. It is a two-argument function that requires both a
staged multimodal projector and a working image-embedding path — matching the
probed shape already used by the MLX and Ollama helpers, and the contract
documented on `MultimodalProjectorConfigurable`.

Shipped with PR [#2393](https://github.com/ManifoldKit/ManifoldKit/pull/2393)
(issues #2381).

## What changed

| Before | After |
|--------|--------|
| `BackendVisionCapability.llamaSupportsImageInput` → `Bool` (always `false`) | `BackendVisionCapability.llamaSupportsImageInput(projectorStaged:engineSupportsImageEmbedding:)` → `Bool` |

Truth table (both halves required):

| `projectorStaged` | `engineSupportsImageEmbedding` | Result |
|-------------------|--------------------------------|--------|
| `false` | `false` | `false` |
| `true` | `false` | `false` |
| `false` | `true` | `false` |
| `true` | `true` | `true` |

A staged mmproj URL alone must **not** advertise vision — the engine must also
be able to turn `MessagePart.image` into embeddings.

## Symptoms

```
type 'BackendVisionCapability' has no member 'llamaSupportsImageInput'
// or, after partial migration:
missing argument labels 'projectorStaged:engineSupportsImageEmbedding:' in call
```

## What to do instead

Pass real probes from the backend that owns mmproj staging and embedding:

```swift,no-build:API-shape fragment for BackendCapabilities construction, not a standalone program
// Until the engine can embed images, keep both halves false — same runtime
// behaviour as the old constant, but compiles against the new API:
supportsVision: BackendVisionCapability.llamaSupportsImageInput(
    projectorStaged: false,
    engineSupportsImageEmbedding: false
)

// Once mmproj is staged AND mtmd/clip (or equivalent) can embed:
supportsVision: BackendVisionCapability.llamaSupportsImageInput(
    projectorStaged: mmprojURL != nil,
    engineSupportsImageEmbedding: Self.engineCanEmbedImages
)
```

`GenerationQueue` still hard-throws image-bearing turns when
`capabilities.supportsVision` is false — that fail-fast is intentional. Only
the capability *computation* changed.

## Why

The constant made vision **structurally unreachable** on the llama.cpp lane:
image turns were rejected inside core before `LlamaBackend.generate()` ran, so
companion work (manifold-llama#152 / mmproj+mtmd) would have landed inert.
