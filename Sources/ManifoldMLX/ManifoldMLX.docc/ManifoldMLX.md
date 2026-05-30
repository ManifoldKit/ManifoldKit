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
`ManifoldHuggingFace` for the downloader.

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

## When to use this module

Import `ManifoldMLX` directly when:

- You are loading safetensors / MLX-format model weights from a local directory
  or a HuggingFace Hub snapshot for **text inference** on Apple Silicon.
- You are running **on-device diffusion** — either SDXL/SD 2.1 via
  ``MLXDiffusionBackend`` or FLUX.1 Schnell via ``FluxDiffusionBackend``.
- You want to tune the Metal GPU buffer cache size with ``MLXCachePolicy``
  (for example to maximise throughput on a Mac Studio with 192 GB RAM, or to
  minimise peak footprint on an older iPhone).
- You are writing backend-level tests that need ``MLXBackend`` directly rather
  than going through ``InferenceService``.

## When not to use this module

- **Your app never runs on Apple Silicon.** The entire module is conditionally
  compiled behind the `MLX` package trait. Cloud-only apps should omit the
  `MLX` trait so the MLX XCFramework is never linked.
- **You only need the image-generation value types** (``ImageGenerationConfig``,
  ``ImageGenerationEvent``). Those are in `ManifoldInference` so you can
  reference them without pulling in the MLX dependency.
- **You want the framework to manage model lifecycle.** For text inference,
  register ``MLXBackend`` via
  `InferenceService.registerBackendFactory` and let ``InferenceService``
  own loading. For image generation, use ``ImageGenerationService`` when you
  want automatic load/unload-on-switch and resource arbitration against the
  text-inference pool.

## Beyond chat

``MLXDiffusionBackend`` and ``FluxDiffusionBackend`` are fully independent of
the chat runtime. Use them from any Swift context — a command-line tool, a
photo-editing extension, a SwiftUI image-generation view — without importing
`ManifoldRuntime` or `ManifoldUI`. The shared ``ImageGenerationEvent`` stream
and file-URL–based output mean finished images slot directly into any
persistence layer that stores file references.

The text backend (``MLXBackend``) is also usable outside chat: classification
pipelines, document summarisers, and structured-output extractors that need a
fast local LLM on Mac can drive it through ``InferenceService`` without
wiring up sessions or a message store.

## When to use which image-gen entry point

| Need | Use |
|---|---|
| Multi-model app, user can switch models, want framework to load/unload | ``ImageGenerationService`` |
| Single-model app, you own the model URL, want minimum surface area | ``FluxDiffusionBackend`` or ``MLXDiffusionBackend`` directly |
| Persist generated images alongside chat turns | ``ImageGenerationService`` + `ConversationRuntime` |
| FLUX.1 Schnell (distilled, 4-step) | ``FluxDiffusionBackend`` |
| Stable Diffusion 2.1 Base or SDXL Turbo | ``MLXDiffusionBackend`` |
| Headless / CLI generation, no persistence | Direct backend |

Both paths emit the same ``ImageGenerationEvent`` stream and write the
finished image to a file URL on disk (see the type's "Why URL, not CGImage?"
section). The service path additionally arbitrates against the
text-inference resource pool so loading a diffusion model evicts an LLM
that's currently resident, and vice versa.

## The 3–5 most-used types

### `MLXBackend` — text inference on Apple Silicon

``MLXBackend`` is the primary text backend for safetensors/MLX models. Register
it at app start so ``InferenceService`` can select it when the loaded model
is in MLX format:

```swift,no-build
import ManifoldInference
import ManifoldMLX

@MainActor
func wireBackends(service: InferenceService) {
    service.registerBackendFactory { modelType in
        guard modelType == .mlx else { return nil }
        return MLXBackend()
    }
}

// Later: load a model directory containing config.json + .safetensors weights.
let plan = try ModelLoadPlan.compute(for: modelInfo)
try await inferenceService.loadModel(from: modelInfo, plan: plan)

let (_, stream) = try inferenceService.enqueue(
    messages: [.user("Explain diffusion models in one paragraph.")],
    config: GenerationConfig(temperature: 0.7, maxOutputTokens: 256)
)

for try await event in stream {
    if case .token(let chunk) = event { print(chunk, terminator: "") }
}
```

``MLXBackend`` requires real Apple Silicon hardware — it will not function in
the iOS Simulator. Gate Metal-dependent paths with `#if !targetEnvironment(simulator)`.

### `MLXCachePolicy` — tune the Metal buffer pool

MLX maintains a process-global pool of freed Metal buffers. The default
``MLXCachePolicy/auto`` picks a sensible size based on device RAM, but you
can override it when you have measured a specific workload:

```swift,no-build
import ManifoldMLX

// Auto (recommended) — picks 64 MB on older iPhones, up to 1 GB on 36+ GB Macs.
let policy: MLXCachePolicy = .auto

// Generous — ~25% of physical RAM, capped at 4 GB.
// Use when throughput matters more than peak footprint.
let policy: MLXCachePolicy = .generous

// Explicit — you have benchmarked 768 MB for your specific model + workload.
let policy: MLXCachePolicy = .explicit(bytes: 768 * 1024 * 1024)

// Apply the policy (call after loadModel succeeds, not before).
MLX.Memory.cacheLimit = policy.resolvedBytes()
```

> Warning: Never call `MLX.Memory.cacheLimit` or `MLX.Memory.clearCache()`
> before a successful `loadModel` — doing so requires the metallib to be
> initialised and will abort the process in the Simulator. Use container
> presence as the guard.

### `FluxDiffusionBackend` — FLUX.1 Schnell on device

``FluxDiffusionBackend`` drives FLUX.1 Schnell via `mzbac/flux.swift`. It
accepts both quantized weights (4-bit, written by `flux.swift`'s own
`saveQuantizedWeights`) and standard FP16 safetensors in diffusers layout:

```swift,no-build
import ManifoldInference
import ManifoldMLX

let backend = FluxDiffusionBackend()
try await backend.loadModel(from: weightsURL)  // URL to the model directory

let config = ImageGenerationConfig(
    steps: 4,           // FLUX Schnell is distilled — 4 steps is enough
    width: 1024,
    height: 1024,
    seed: 42,
    outputDirectory: FileManager.default.temporaryDirectory
)

let stream = try await backend.generate(prompt: "a red fox in the snow", config: config)
for try await event in stream {
    switch event {
    case .progress(let step, let total):
        print("Step \(step)/\(total)")
    case .completed(let url):
        // `url` points to a fully-written PNG on disk.
        displayImage(at: url)
    }
}
```

### `MLXDiffusionBackend` — Stable Diffusion on device

``MLXDiffusionBackend`` auto-detects the model layout from the directory
structure — SD 2.1 Base (512×512) or SDXL Turbo (1024×1024). The init
takes no parameters; all tuning goes through ``ImageGenerationConfig``:

```swift,no-build
import ManifoldInference
import ManifoldMLX

let backend = MLXDiffusionBackend()
try await backend.loadModel(from: sdxlTurboURL)

let config = ImageGenerationConfig(
    steps: 1,           // SDXL Turbo is distilled — 1 step works well
    width: 1024,
    height: 1024,
    guidanceScale: 0.0  // distilled models ignore CFG; set to 0 to be explicit
)

let stream = try await backend.generate(
    prompt: "a watercolour painting of Kyoto in autumn",
    config: config
)
for try await event in stream {
    if case .completed(let url) = event { displayImage(at: url) }
}
```

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
