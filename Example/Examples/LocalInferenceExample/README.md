# LocalInferenceExample

Two small SwiftUI apps demonstrating ManifoldKit's local-inference companion
packages end to end: **MLX** (Apple's on-device ML framework, text + image
generation) and **llama.cpp** (GGUF, text only). Companion package to
[`docs/COMPANION-BACKENDS.md`](../../../docs/COMPANION-BACKENDS.md) and
[`docs/QUICKSTART-CLI.md`](../../../docs/QUICKSTART-CLI.md) § 4 — read those
first for the underlying API contract; this app is the runnable, SwiftUI-app
version of the same recipes.

## See it work

The fastest way to see this working — real download, real generation, no
Xcode required — is the human-run gate script:

```sh
scripts/example-local-inference.sh build        # compile both targets only
scripts/example-local-inference.sh run llama    # download + launch the Llama app
scripts/example-local-inference.sh run mlx      # download + launch the MLX app
scripts/example-local-inference.sh run all      # both, one after another
```

Needs a real Apple Silicon Mac and network access — `run` downloads real
models (multi-GB for `mlx`) and hands off to you for the one step nothing
can script: confirming a reply (and, for MLX, a generated image) actually
appears in the chat UI. See the script's own header for the full story;
it is not part of any CI gate. Building and running from Xcode directly
(below, under "Building") is the secondary path — useful when iterating on
the app code itself, but it proves compilation only, not a working chat.

## ⚠️ Never link both companions into one target

`ManifoldMLX` and `ManifoldLlama` must **never** be linked into the same
target or binary. Both wrap process-global native state
(`llama_backend_init`, Metal-in-simulator gating — see
[`docs/HARDWARE-TOOLCHAIN.md`](../../../docs/HARDWARE-TOOLCHAIN.md)), and
mixing them in one process is the #982 hazard. That's why this is **two**
Xcode targets, not one app with a backend picker:

| Target | Sources | Links |
|---|---|---|
| `LocalInferenceExample_MLX` | `MLX/` | `ManifoldKit` + `ManifoldMLX` |
| `LocalInferenceExample_Llama` | `Llama/` | `ManifoldKit` + `ManifoldLlama` |

If you're extending this example, keep that split. Don't add a
`import ManifoldLlama` to anything under `MLX/`, or vice versa.

Both targets are **macOS-only** (no iOS destinations) — the iOS Simulator
doesn't provide the Metal / native process lifecycle either companion needs.

## What each app does

**`LocalInferenceExample_Llama`** uses the documented one-call recipe
(`docs/QUICKSTART.md` → "Seeding a starter model"):

```swift
let configuration = ManifoldConfiguration(
    appName: "Local Inference (llama.cpp)",
    bundleIdentifier: "com.manifoldkit.local-inference-example-llama"
)
let result = try await ManifoldKit.quickStart(
    backends: [LlamaBackends.self],
    configuration: configuration,
    seed: .recommendedSmallModel { progress in
        print("Downloading: \(Int(progress * 100))%")
    }
)
```

On first launch it downloads the curated Qwen3-0.6B-Instruct GGUF (~400 MB)
before the chat surface appears — live and generating, zero model-management
UI required.

**`LocalInferenceExample_MLX`** demonstrates text *and* image generation.
`quickStart(...)` has no `imageGenerationService` parameter on any overload
(see `Sources/ManifoldUI/ManifoldUI.docc/Articles/GenerationComponents.md` §
"Registering tool sources" — tracked as #1903), so this app drops down to the
documented manual `ManifoldBootstrap.build(...)` recipe (`AGENTS.md` → Part 1
→ "Bootstrap recipe") instead, registering `MLXBackends` plus an
`ImageGenerationService` wired to `registerMLXDiffusionBackend()`
(`manifold-mlx`'s `MLXDiffusionBackend.swift`) and an `ImageGenerationToolSource`
so the model can call `generate_image` autonomously. `ChatView` already
renders the resulting inline image — no new chat UI was added.

The MLX app ships no model-download UI (`ManifoldUIModelManagement` is not
linked): text models are discovered from `~/Documents/Models` (the same
fallback directory `docs/QUICKSTART-CLI.md` § 4 documents — populate it with
`hf download`), and the SDXL-Turbo diffusion snapshot is discovered from
`~/Documents/Models/ImageModels/stabilityai-sdxl-turbo`. Both are populated
by [`scripts/example-local-inference.sh`](../../../scripts/example-local-inference.sh),
not by this app.

## Building

```sh
cd Example/Examples
xcodegen generate
open ManifoldExamples.xcodeproj
```

Select the `LocalInferenceExample_MLX` or `LocalInferenceExample_Llama`
scheme, destination "My Mac", and Run.

`scripts/demo-apps-build.sh` builds both targets headlessly as a release
gate — compile-only, no model, no download, no generation. For an actual
working chat, use `scripts/example-local-inference.sh` (see "See it work"
above).

## Developing against a local companion checkout

The companion packages are pinned by released version in
`Example/Examples/project.yml`:

```yaml
packages:
  ManifoldMLX:
    url: https://github.com/ManifoldKit/manifold-mlx
    minorVersion: 0.5.0
  ManifoldLlama:
    url: https://github.com/ManifoldKit/manifold-llama
    minorVersion: 0.4.3
```

To iterate against a local `manifold-mlx` or `manifold-llama` checkout
(mirrors the `swift package edit` workflow `docs/COMPANION-BACKENDS.md` § 4
describes for SwiftPM-only consumers — this project is XcodeGen-generated, so
the equivalent lever is the package source in `project.yml`), temporarily
swap the `url:`/`minorVersion:` pair for a `path:` entry pointing at your
checkout, exactly like this file's existing `ManifoldKit` reference:

```yaml
packages:
  ManifoldMLX:
    path: ../../../manifold-mlx     # adjust to your checkout's location
```

then regenerate:

```sh
cd Example/Examples
xcodegen generate
```

Revert to the `url:`/`minorVersion:` form before committing — a `path:`
package reference in `project.yml` only resolves on a machine with that exact
sibling checkout, and CI has none.
