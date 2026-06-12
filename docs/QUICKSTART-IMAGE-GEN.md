# ManifoldKit Image-Gen Quickstart

A one-page tutorial for adding on-device image generation to any Swift app. No
`ChatView`, no `ChatViewModel` — both `FluxDiffusionBackend` and
`MLXDiffusionBackend` conform to `ImageGenerationBackend` and stream progress
+ the final file URL through an `AsyncThrowingStream`.

> **Platform requirements by backend.**
>
> | Backend | Platforms | Memory |
> |---|---|---|
> | `FluxDiffusionBackend` | macOS 15+ only | ~7 GB unified memory headroom |
> | `MLXDiffusionBackend` | iOS 18+ / macOS 15+ | Checked at load time; throws `MLXDiffusionError.insufficientMemory` if denied |
>
> Bring-your-own URL — the backends take a local directory URL and do not
> download. See [§4](#4-picking-a-model) for which HuggingFace repo layouts the
> bundled `HuggingFaceService` downloader accepts.

---

## 1. Add the `MLX` trait

In your consumer `Package.swift`:

```swift,no-build
dependencies: [
    .package(
        url: "https://github.com/roryford/ManifoldKit.git",
        from: "0.47.0", // x-release-please-version
        traits: [
            .trait(name: "MLX"),
        ]
    ),
],
targets: [
    .executableTarget(
        name: "MyImageApp",
        dependencies: [
            .product(name: "ManifoldMLX", package: "ManifoldKit"),
            .product(name: "ManifoldInference", package: "ManifoldKit"),
        ]
    ),
],
```

`MLX` is in the default trait set, so this works without the explicit
`traits:` array too. Two public types live in two modules — the backend in
`ManifoldMLX`, the value types (`ImageGenerationConfig`,
`ImageGenerationEvent`) in `ManifoldInference`. Both imports are required.

---

## 2. End-to-end snippets

### FluxDiffusionBackend (macOS only)

`loadModel(from:)` is mandatory before the first `generate(prompt:config:)`
call — calling `generate` on a fresh backend throws
`FluxDiffusionError.notLoaded`. The `URL` is the on-disk directory containing
the FLUX weights (either flux.swift's quantized layout with `metadata.json`,
or the standard diffusers layout with `safetensors`). How you obtain that
directory is your choice — `HuggingFaceService.downloadDiffusionModel` is one
option (see [§4](#4-picking-a-model)).

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
        let modelDirectory = URL(
            fileURLWithPath: "/path/to/FLUX.1-schnell"
        )
        try await backend.loadModel(from: modelDirectory)

        // 3. Configure the run. FLUX Schnell is distilled to 1–4 steps;
        //    `guidanceScale: nil` lets the backend apply its own default.
        let config = ImageGenerationConfig(
            steps: 4,
            width: 1024,
            height: 1024,
            seed: 42,
            outputDirectory: FileManager.default.temporaryDirectory
        )
        // Backends that accept a ratio string (e.g. cloud backends) read
        // `aspectRatio` directly. On-device backends that operate on explicit
        // pixel dimensions derive the ratio from `width`/`height` instead.
        // let config = ImageGenerationConfig(steps: 4, width: 1024, height: 1024,
        //     aspectRatio: "16:9", outputDirectory: FileManager.default.temporaryDirectory)

        // 4. `generate` returns an AsyncThrowingStream. Iterate it to observe
        //    progress; the terminal `.completed(url)` event carries the
        //    PNG's file URL. The file is fully written before the event
        //    is yielded.
        let stream = try backend.generate(prompt: "a red fox in a snowy forest", config: config)
        for try await event in stream {
            switch event {
            case .progress(let step, let total):
                print("step \(step)/\(total)")
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

### MLXDiffusionBackend (Mac path — iOS waits for #1691)

`MLXDiffusionBackend` runs `ImageModelLoadPlan` during `loadModel(from:)` and
throws `MLXDiffusionError.insufficientMemory` if the device doesn't have
enough RAM — the caller doesn't need a separate guard. The URL must be the Hub
leaf directory (`<root>/models/<org>/<name>`);
`HuggingFaceService.downloadDiffusionModel` writes this layout automatically.

> **Note:** The iPhone path (iOS 18 device) is not yet documented — it depends
> on issue #1691 (iPhone model + diffusionkit layout support). The Mac path
> works today.

> **Storage and RAM for `stabilityai/sdxl-turbo`**
>
> - Storage: ~10 GB (9.6 GB unet weights)
> - RAM: cannot load on iPhone (4–5 GB usable). Use
>   `stabilityai/stable-diffusion-2-1-base` (~3 GB) for iPhone once #1691
>   lands.
> - `loadModel` throws `MLXDiffusionError.insufficientMemory` rather than
>   OOM-crashing — but the model still won't fit on most iPhones.

```swift,no-build
import Foundation
import ManifoldInference
import ManifoldMLX

@main
struct ImageGen {
    static func main() async throws {
        let backend = MLXDiffusionBackend()

        // Supported layouts (auto-detected): stabilityai/sdxl-turbo (1024×1024)
        // or stabilityai/stable-diffusion-2-1-base (512×512).
        // The URL must be the Hub leaf directory: <root>/models/<org>/<name>
        // (HuggingFaceService.downloadDiffusionModel writes this layout automatically).
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
`backend.stopGeneration()` directly — the next denoising step observes the
flag, throws `CancellationError`, and finishes the stream.

---

## 3. Using `ImageGenerationService` (optional)

If you're managing multiple image models or want backend lifecycle parity
with `InferenceService`, wire `ImageGenerationService`:

```swift,no-build
import ManifoldInference
import ManifoldMLX

@MainActor
func makeService() -> ImageGenerationService {
    let service = ImageGenerationService()
    service.registerFluxDiffusionBackend()   // wires `.fluxSchnell` format
    service.registerMLXDiffusionBackend()    // wires `.sdxlTurbo` / `.sdXL21Base` formats
    return service
}
```

Call `service.loadModel(_:)` with an `ImageModelInfo` (resolved from your
storage layer); call `service.generate(prompt:config:)` for the same
`AsyncThrowingStream<ImageGenerationEvent, Error>` shape as the bare-backend
path above.

---

## 4. Picking a model

The bundled `HuggingFaceService.downloadDiffusionModel` validator requires the
standard **diffusers layout**: a `model_index.json` at the repo root plus
`vae/config.json`, `vae/diffusion_pytorch_model.safetensors`, and a
`unet/` or `transformer/` weights directory. Repos that use the
**diffusionkit** layout (single quantized blob + `metadata.json` at root)
will fail validation against the bundled downloader with `HTTP 404 for
model_index.json`. Two paths:

- **Use a diffusers-layout repo with the bundled downloader.** The curated
  catalog (`DiffusionModelCatalogEntry` in `ManifoldUIModelManagement`) ships
  `stabilityai/sdxl-turbo` for exactly this reason — it loads through
  `MLXDiffusionBackend` and passes the validator out of the box.
- **Use any layout you want with your own download path.** `FluxDiffusionBackend`
  itself doesn't care about repo layout — it sniffs `metadata.json` at load
  time and falls back to the diffusers `Flux1Schnell(hub:modelDirectory:)`
  path. If you already have FLUX weights on disk (downloaded with
  `huggingface-cli`, `hf_hub_download`, or a custom tool), point
  `loadModel(from:)` at the directory and skip the bundled downloader.

Either way, the URL passed to `loadModel(from:)` is always a **directory**,
not a file.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `FluxDiffusionError.notLoaded` thrown from `generate` | You called `generate` before `loadModel(from:)` completed. Await the load before the first generate. |
| `HTTP 404 for model_index.json` from `downloadDiffusionModel` | Repo uses diffusionkit layout; the bundled validator requires diffusers layout. See [§4](#4-picking-a-model). |
| `FluxDiffusionError.noLatentsProduced` | The denoising loop yielded zero latents — typically a cancellation that fired before step 1. Increase `steps` or remove the early stop. |
| Process OOM during decode on FluxDiffusionBackend | FLUX Schnell needs ~7 GB headroom; close other GPU-using apps or `unloadModel()` after each generation. |
| Stream finishes without `.completed` and without throwing | The generation was cancelled via `stopGeneration()` or task cancellation. This is the contract — `onTermination` runs `stopGeneration` for you when the iterator drops. |
| `MLXDiffusionError.notLoaded` thrown from `generate` | Called `generate` before `loadModel(from:)` completed. |
| `MLXDiffusionError.unsupportedModelLayout` | Directory is not `stabilityai/sdxl-turbo` or `stabilityai/stable-diffusion-2-1-base` layout. Verify the Hub leaf path (`<root>/models/<org>/<name>`). |
| `MLXDiffusionError.insufficientMemory` on `loadModel` | Device RAM too low for the chosen model. Try `stable-diffusion-2-1-base` (~3 GB); or free GPU memory with `unloadModel()` on other backends first. |
| Process OOM during decode on MLXDiffusionBackend | Both UNet and VAE activations competed for memory. Call `unloadModel()` after each generation to release the GPU cache. |
