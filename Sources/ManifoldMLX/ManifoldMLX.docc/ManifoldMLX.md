# ``ManifoldMLX``

MLX-backed inference and image generation for ManifoldKit on Apple Silicon.

## Overview

`ManifoldMLX` is the Apple-Silicon-only family target that plugs MLX-based
backends into the protocols declared in `ManifoldInference`. It carries two
distinct surfaces:

- **Text inference** via ``MLXBackend``, a conformer of `InferenceBackend`
  that drives `mlx-swift-lm` models with the shared generation-event stream,
  context budgeting, and tool-calling dialect.
- **Image generation** via ``MLXDiffusionBackend`` and ``FluxDiffusionBackend``,
  conformers of `ImageGenerationBackend` that drive `mlx-swift-examples`'s
  StableDiffusion and `mzbac/flux.swift` respectively.

The module is trait-gated behind the `MLX` package trait; apps that don't
need MLX can build without it. Image generation backends additionally need
diffusion weights on disk — see ``ImageModelInfo`` for the on-disk shape and
``ManifoldHuggingFace`` for the downloader.

> Note: `ImageGenerationConfig`, `ImageGenerationEvent`, and `ImageModelInfo`
> are declared in `ManifoldInference`, not here — they have to sit below the
> backend family so non-MLX consumers (catalog UIs, persistence, runtime) can
> reference them without dragging in MLX. Import both modules when wiring
> image generation:
>
> ```swift
> import ManifoldInference
> import ManifoldMLX
> ```

## Topics

### Image generation — high-level entry point

Use ``ImageGenerationService`` (in `ManifoldInference`) when you want the
framework to manage model lifecycle for you: pass an ``ImageModelInfo``
descriptor and the service picks the right backend, loads weights, and tears
the previous model down on switch. This is the recommended path for apps
that present a model picker or otherwise let the user swap models at
runtime.

### Image generation — direct backends

Use the backends directly when you want to own loading yourself — for
example a single-model app that ships one set of weights and never swaps,
or a CLI that does one generation and exits. Both backends conform to
``ImageGenerationBackend`` (in `ManifoldInference`) and emit an
`AsyncThrowingStream<ImageGenerationEvent, any Error>` from `generate`.

- ``MLXDiffusionBackend``
- ``FluxDiffusionBackend``

### Text inference

- ``MLXBackend``
- ``MLXCachePolicy``

## When to use which image-gen entry point

| Need | Use |
|---|---|
| Multi-model app, user can switch models, want framework to load/unload | ``ImageGenerationService`` |
| Single-model app, you own the model URL, want minimum surface area | ``FluxDiffusionBackend`` or ``MLXDiffusionBackend`` directly |
| Persist generated images alongside chat turns | ``ImageGenerationService`` + `ConversationRuntime` |
| Headless / CLI generation, no persistence | Direct backend |

Both paths emit the same ``ImageGenerationEvent`` stream and write the
finished image to a file URL on disk (see the type's "Why URL, not CGImage?"
section). The service path additionally arbitrates against the
text-inference resource pool so loading a diffusion model evicts an LLM
that's currently resident, and vice versa.
