# ManifoldKit Image-Gen Quickstart

**Audience:** consumer
**Status:** living

A one-page tutorial for adding on-device image generation to any Swift app. No
`ChatView`, no `ChatViewModel` — both `FluxDiffusionBackend` and
`MLXDiffusionBackend` conform to `ImageGenerationBackend` and stream progress
plus the final file URL through an `AsyncThrowingStream`, exactly the way text
inference streams `GenerationEvent`.

> **Where the pieces live (since v0.48).** The diffusion **backends** ship in the
> [`manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx) companion package
> (module `ManifoldMLX`). The **value types** (`ImageGenerationConfig`,
> `ImageGenerationEvent`, `ImageModelInfo`) and the optional
> `ImageGenerationService` orchestrator stay in **core** and re-export through
> `import ManifoldInference`. The HuggingFace download path is core too
> (`import ManifoldHuggingFace`).

> **Platform requirements by backend.**
>
> | Backend | Platforms | Memory |
> |---|---|---|
> | `FluxDiffusionBackend` | macOS 15+ (Apple Silicon) | ~7 GB headroom — a memory floor, not an API gate; impractical on iPhone |
> | `MLXDiffusionBackend` | iOS 18+ / macOS 15+ | Checked at load time; throws `MLXDiffusionError.insufficientMemory` if the device can't fit the model |
>
> Bring-your-own URL — the backends take a **local directory** and do not
> download. See [§4](#4-getting-a-model) for the bundled downloader and the
> curated catalog.

> **Command-line builds need the Metal Toolchain.** Under an Xcode / `xcodebuild`
> build (any normal SwiftUI `.app`), MLX's `mlx.metallib` is produced and bundled
> automatically. Under a bare-SwiftPM `swift build` / `swift run` it is only
> produced when the **Metal Toolchain** component is installed — see
> [§5](#5-the-metallib-requirement) before you `swift run`.

---

## 1. Add the `manifold-mlx` package

The MLX family is a separate companion package (the old `MLX` trait was retired
in v0.48). In your consumer `Package.swift`:

```swift,no-build
dependencies: [
    .package(
        url: "https://github.com/ManifoldKit/ManifoldKit.git",
        from: "0.76.0" // x-release-please-version
    ),
    .package(
        url: "https://github.com/ManifoldKit/manifold-mlx.git",
        from: "0.2.13"
    ),
],
targets: [
    .executableTarget(
        name: "MyImageApp",
        dependencies: [
            .product(name: "ManifoldMLX", package: "manifold-mlx"),
            .product(name: "ManifoldInference", package: "ManifoldKit"),
        ]
    ),
],
```

The backend types live in `ManifoldMLX`; the value types
(`ImageGenerationConfig`, `ImageGenerationEvent`) come in through
`ManifoldInference`. Both imports are required.

(Xcode consumers: File ▸ Add Package Dependencies… ▸ enter the `manifold-mlx`
URL ▸ tick the `ManifoldMLX` product for your app target.)

---

## 2. End-to-end snippets

### FluxDiffusionBackend (Apple Silicon Mac)

`loadModel(from:)` is mandatory before the first `generate(prompt:config:)`
call — calling `generate` on a fresh backend throws
`FluxDiffusionError.notLoaded`. The `URL` is the on-disk directory containing
the FLUX weights (either flux.swift's quantized layout with `metadata.json`, or
the standard diffusers layout with `safetensors`). How you obtain that directory
is your choice — `HuggingFaceService.downloadDiffusionModel` is one option
(see [§4](#4-getting-a-model)).

```swift,no-build
import Foundation
import ManifoldInference
import ManifoldMLX

@main
struct ImageGen {
    static func main() async throws {
        // 1. Construct the backend.
        let backend = FluxDiffusionBackend()

        // 2. Load weights from a local directory. The URL must point at the
        //    unpacked FLUX model directory — not a single file.
        let modelDirectory = URL(fileURLWithPath: "/path/to/FLUX.1-schnell")
        try await backend.loadModel(from: modelDirectory)

        // 3. Configure the run. FLUX Schnell is distilled to 1–4 steps;
        //    `guidanceScale: nil` lets the backend apply its own default.
        //    `outputDirectory` controls where the PNG is written; nil lets the
        //    backend pick its own temporary location.
        let config = ImageGenerationConfig(
            steps: 4,
            width: 768,
            height: 768,
            seed: 42,
            outputDirectory: FileManager.default.temporaryDirectory
        )

        // 4. `generate` returns an AsyncThrowingStream. Iterate it to observe
        //    progress; the terminal `.completed(url)` event carries the PNG's
        //    file URL, fully written before the event is yielded.
        let stream = try backend.generate(prompt: "a red fox in a snowy forest", config: config)
        for try await event in stream {
            switch event {
            case .progress(let step, let total):
                print("step \(step)/\(total)")
            case .preview(let step, let total, _):
                // Only emitted when you set `config.previewStride`; carries
                // encoded thumbnail bytes for a progressively-refining preview.
                print("preview \(step)/\(total)")
            case .completed(let url):
                print("wrote \(url.path)")
            }
        }

        // 5. Free GPU memory when you're done. `unloadModel` is safe to call
        //    even if the backend was never loaded.
        backend.unloadModel()
    }
}
```

### MLXDiffusionBackend (SDXL Turbo / SD 2.1 Base)

`MLXDiffusionBackend` runs `ImageModelLoadPlan` during `loadModel(from:)` and
throws `MLXDiffusionError.insufficientMemory` if the device doesn't have enough
RAM — the caller doesn't need a separate guard. It auto-detects the
`stabilityai/sdxl-turbo` (1024×1024) and `stabilityai/stable-diffusion-2-1-base`
(512×512) layouts; other layouts throw `MLXDiffusionError.unsupportedModelLayout`.

> **iPhone note.** `MLXDiffusionBackend` runs on iOS 18+, but SDXL Turbo (~10 GB)
> will not fit on a phone — use `stable-diffusion-2-1-base` (~3 GB) there.
> `loadModel` throws `MLXDiffusionError.insufficientMemory` rather than
> OOM-crashing when a model is too large for the device.

```swift,no-build
import Foundation
import ManifoldInference
import ManifoldMLX

@main
struct ImageGen {
    static func main() async throws {
        let backend = MLXDiffusionBackend()

        // The URL is the model directory (diffusers submodules — unet/, vae/,
        // scheduler/, … — at its top level). Either a flat install or a Hub leaf.
        let modelDirectory = URL(fileURLWithPath: "/path/to/sdxl-turbo")
        try await backend.loadModel(from: modelDirectory)

        // SDXL Turbo is distilled to 1–4 steps.
        let config = ImageGenerationConfig(
            steps: 4,
            width: 1024,
            height: 1024,
            seed: 42,
            outputDirectory: FileManager.default.temporaryDirectory
        )

        let stream = try backend.generate(prompt: "a red fox in a snowy forest", config: config)
        for try await event in stream {
            switch event {
            case .progress(let step, let total):
                print("step \(step)/\(total)")
            case .preview(let step, let total, _):
                print("preview \(step)/\(total)")
            case .completed(let url):
                print("wrote \(url.path)")
            }
        }

        backend.unloadModel()
    }
}
```

### Cancelling mid-run

The stream's `onTermination` hook drives `stopGeneration()` for you when the
iterator is torn down (drop the `for try await` early, cancel the enclosing
`Task`, etc.). To stop without tearing down the iterator, call
`backend.stopGeneration()` directly — the next denoising step observes the flag,
throws `CancellationError`, and finishes the stream.

---

## 3. Using `ImageGenerationService` (optional)

If you're managing multiple image models or want backend-lifecycle parity with
`InferenceService`, wire `ImageGenerationService`. You register a **factory per
format**; the service constructs and swaps backends as models load. The factory
closure is `@MainActor (ImageModelInfo) async throws -> any ImageGenerationBackend`.

```swift,no-build
import ManifoldInference
import ManifoldMLX

@MainActor
func makeService() -> ImageGenerationService {
    let service = ImageGenerationService()
    service.registerBackendFactory(for: .fluxSchnell) { _ in FluxDiffusionBackend() }
    service.registerBackendFactory(for: .mlxDiffusion) { _ in MLXDiffusionBackend() }
    return service
}
```

Call `service.loadModel(_:)` with an `ImageModelInfo` (its `format` selects the
factory); call `service.generate(prompt:config:)` for the same
`AsyncThrowingStream<ImageGenerationEvent, Error>` shape as the bare-backend path
above; `service.unload()` tears the backend down. If no factory is registered
for the model's format, `loadModel` throws
`ImageGenerationServiceError.noFactoryRegistered`.

---

## 4. Getting a model

The bundled `HuggingFaceService.downloadDiffusionModel` fetches a **diffusers
layout** repo (a `model_index.json` at the root plus `vae/`, `unet/` or
`transformer/` weights) and returns an `ImageModelInfo` whose `directoryURL` you
hand straight to `loadModel(from:)`:

```swift,no-build
import Foundation
import ManifoldHuggingFace
import ManifoldMLX

let hf = HuggingFaceService()
let destination = URL.applicationSupportDirectory
    .appending(path: "models/sdxl-turbo", directoryHint: .isDirectory)

let info = try await hf.downloadDiffusionModel(
    from: "stabilityai/sdxl-turbo",
    to: destination,
    displayName: "SDXL Turbo",
    progress: { progress in
        print("downloading \(progress.currentFile) — \(Int(progress.fractionCompleted * 100))%")
    }
)

// `info.format == .mlxDiffusion`; `info.directoryURL` is the loadable directory.
let backend = MLXDiffusionBackend()
try await backend.loadModel(from: info.directoryURL)
```

The download uses a background `URLSession` (survives app suspension on iOS) and
writes atomically through a staging directory, so a killed download never leaves
a half-written model in place.

Two other paths worth knowing:

- **Curated catalog + install UI.** `DiffusionModelCatalog` (in
  `ManifoldUIModelManagement`) seeds a picker with known-good diffusers repos, and
  `ImageModelInstallView` gives you a ready-made download-with-progress screen —
  the fastest route to a first-run "model needed → downloading → ready" flow if
  you're already on SwiftUI.
- **Bring your own weights.** `FluxDiffusionBackend` doesn't care about repo
  layout — it sniffs `metadata.json` at load time and falls back to the diffusers
  `Flux1Schnell` path. If you already have FLUX weights on disk (from
  `huggingface-cli`, `hf_hub_download`, mflux, or a custom tool), point
  `loadModel(from:)` at the directory and skip the bundled downloader entirely.

Either way, the URL passed to `loadModel(from:)` is always a **directory**, not a
file.

---

## 5. The metallib requirement

mlx-swift loads a precompiled `mlx.metallib` at first GPU use and aborts with
`MLX error: Failed to load the default metallib` if none is colocated with the
running binary. How that library gets there depends on how you build:

- **Xcode / `xcodebuild` (any SwiftUI `.app`)** — the Metal-shader compile phase
  produces and bundles it. Nothing to do; image gen works out of the box.
- **Command-line `swift build` / `swift run`** — `manifold-mlx`'s
  `MLXMetallibPlugin` compiles the metallib during `swift build` and
  `MLXMetallibStaging` colocates it next to your binary at first load —
  **provided the Metal Toolchain component is installed**
  (`xcodebuild -downloadComponent MetalToolchain`, or Xcode ▸ Settings ▸
  Components). Without that component the build still *succeeds* but emits no
  metallib, and MLX aborts at model load with the error above (discovery,
  classification, registration, and the load *plan* all still work).

If you don't want to depend on the Metal Toolchain at all, the GGUF/llama.cpp
companion ([`manifold-llama`](https://github.com/ManifoldKit/manifold-llama)) runs
text inference from `swift run` with no Metal step — but it has no diffusion
backend. For image generation, MLX + the Metal Toolchain is the path.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `MLX error: Failed to load the default metallib` | No colocated `mlx.metallib`. Under `swift run`, install the Metal Toolchain component so `MLXMetallibPlugin` can compile it — see [§5](#5-the-metallib-requirement). Under Xcode it should never happen. |
| `FluxDiffusionError.notLoaded` / `MLXDiffusionError.notLoaded` from `generate` | You called `generate` before `loadModel(from:)` completed. Await the load first. |
| `HTTP 404 for model_index.json` from `downloadDiffusionModel` | Repo isn't a diffusers-layout snapshot (e.g. a single-blob mflux/diffusionkit bundle). Use a diffusers repo, or download by hand and point `loadModel` at the directory. |
| `MLXDiffusionError.unsupportedModelLayout` | Directory isn't a `stabilityai/sdxl-turbo` or `stable-diffusion-2-1-base` layout. |
| `MLXDiffusionError.insufficientMemory` on `loadModel` | Device RAM too low for the chosen model. Try `stable-diffusion-2-1-base` (~3 GB), or `unloadModel()` other backends first. |
| `FluxDiffusionError.noLatentsProduced` | The denoise loop yielded zero latents — typically a cancellation that fired before step 1. Increase `steps` or remove the early stop. |
| Stream finishes without `.completed` and without throwing | The generation was cancelled via `stopGeneration()` or task cancellation. This is the contract — `onTermination` runs `stopGeneration` for you when the iterator drops. |
| Process OOM during decode | UNet + VAE activations competed for memory. Call `unloadModel()` after each generation to release the GPU cache. |
