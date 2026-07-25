# Choosing and Loading Models (Headless)

**Audience:** consumer
**Status:** living

ManifoldKit can choose and load a model **without** a chat view. If you only need
to pick a model — for an NPC runner, a batch job, a settings screen, or your own
custom picker — reach for `ModelSelection` instead of standing up a
`ChatViewModel` as a loader.

`ModelSelection` lives in `ManifoldInference` (re-exported by the `ManifoldKit`
umbrella) and composes the pieces MK already owns:

- **`ModelRegistry`** — selection state plus the synchronous `selectModel` entry.
- **The `ModelInfo → ModelFitScore` bridge + `DeviceCapabilityService`** — the
  device-fit recommendation surface, vended as data.
- **The shared, service-vended `ModelLoadCoordinator`** — one coordinator per
  `InferenceService`, so a headless load does *not* leak progress into a sibling
  chat surface.

The sorted / scored / grouped model list is the product. Auto-load is one
synchronous call.

## The list is the product

```swift
import ManifoldKit

@MainActor
func buildSelection(service: InferenceService) throws -> ModelSelection {
    let selection = ModelSelection(inferenceService: service)
    try selection.refresh()  // scan the models directory

    // Sorted as data — no UI module required.
    let byCapability = selection.sortedModels(by: .capability)

    // Grouped (Apple Foundation vs. downloaded) — the fork fireside-night
    // rebuilt by hand.
    for section in selection.groupedModels(by: .alphabetical) {
        print(section.group.title)
        for model in section.models { print("  \(model.name)") }
    }

    // Scored against this device for a use case, best-first.
    let ranked = selection.rankedModels(useCase: .reasoning)
    if let best = ranked.first {
        print("Recommended: \(best.model.name) — composite \(best.score?.composite ?? 0)")
    }

    return selection
}
```

## A worked `ModelLoadPlan.compute()` rejection

`ModelSelection.loadSelected()` dispatches into the shared coordinator, which
runs `ModelLoadPlan.compute(for:…)` as an admission check. A model whose weights
plus KV cache exceed the device budget gets a `.deny` verdict and the load is
refused — no half-loaded backend, no crash. You can run the same check yourself
before offering a model:

```swift
import ManifoldKit

@MainActor
func canLoad(_ model: ModelInfo) -> Bool {
    let plan = ModelLoadPlan.compute(
        for: model,
        requestedContextSize: 8_192,
        strategy: .mappable
    )
    switch plan.verdict {
    case .allow:
        return true
    case .warn:
        // Tight fit — proceed, but expect memory pressure.
        return true
    case .deny:
        // Surface plan.reasons (e.g. .insufficientResident / .insufficientKVCache)
        // to the user instead of attempting the load.
        return false
    }
}
```

## Per-family fork: Foundation / local / cloud

Selection and load differ by family. Foundation is OS-resident (gate on OS
availability), local models route through `loadSelected()`, and cloud endpoints
are a chat-host concern (drive them through `ChatViewModel.selectedEndpoint`):

```swift
import ManifoldKit

@MainActor
func load(_ model: ModelInfo, into selection: ModelSelection) {
    switch model.modelType {
    case .foundation:
        // OS-resident. Only offer it where the Foundation backend is available.
        if #available(macOS 26, iOS 26, *) {
            selection.select(model)
            selection.loadSelected()
        }
    case .gguf, .mlx:
        // On-disk local model — admission-checked, then loaded.
        selection.select(model)
        selection.loadSelected()
    default:
        // `ModelType` is an extensible struct, not a closed enum (same
        // Notification.Name pattern as `BackendName`), so a `default:` arm is
        // required: a companion package or third party can mint a new model
        // type this switch has never heard of.
        //
        // Do NOT leave this as a bare `break`. A load that silently does
        // nothing shows the user a spinner that never resolves, with no error
        // to explain it — surface it instead (Principle 6, "errors are
        // visible").
        print("Unhandled model type \(model.modelType.rawValue) — not loading.")
    }
    // Cloud endpoints are not on-disk models; a headless selection surface drives
    // local/foundation models. For cloud, use a ChatViewModel's selectedEndpoint
    // (which clears any selected model synchronously — see #1312 below).
}
```

Observe progress without a chat surface:

```swift
import ManifoldKit

@MainActor
func watch(_ selection: ModelSelection) {
    Task {
        for await status in selection.loadStatusUpdates() {
            switch status {
            case .idle:                  break
            case .loading(let progress): print("loading \(progress ?? 0)")
            case .loaded:                print("ready")
            case .failed(let reason):    print("failed: \(reason)")
            }
        }
    }
}
```

## Capability routing and the `supportsReasoning` honest-false footgun

`ModelInfo` exposes `supportsCode`, `supportsMultilingual`, and
`supportsReasoning` as override-over-detected flags. **For most local GGUF models
`supportsReasoning` is `false`** — single-file GGUFs ship no sibling `config.json`
for the capability probe to read, and there is no reliable on-disk signal for
reasoning support. A `false` here means "unknown / not curated," *not* "this model
cannot reason." Do not route a user away from a local model purely on
`supportsReasoning == false`; treat it as a hint, and curate the flag when you
know better:

```swift
import ManifoldKit

@MainActor
func pickReasoner(from selection: ModelSelection) -> ModelInfo? {
    // Honest-false caveat: prefer a curated/cloud reasoner, but fall back to the
    // device-fit best local model rather than excluding all locals.
    let ranked = selection.rankedModels(useCase: .reasoning)
    if let curated = ranked.first(where: { $0.model.supportsReasoning }) {
        return curated.model
    }
    return ranked.first?.model
}
```

## Migration: the #1312 synchronous endpoint-clear

`ModelRegistry.selectedModel`'s setter now clears the mutually-exclusive cloud
endpoint **synchronously**, on the same actor, before the setter returns — via
the new `ModelRegistry.onSelectionChanged` hook that `ChatViewModel` wires to its
endpoint sync. Previously this ran on an async `withObservationTracking` Task hop,
which let `dispatchSelectedLoad` read a stale `selectedEndpoint` and dispatch the
wrong load intent. If you previously mirrored `ChatViewModel.selectedModel` into
`ModelRegistry.selectedModel` by hand to work around #1312, you can drop that
mirroring: select once, through the registry or `ModelSelection.select(_:)`, and
the endpoint clears before you dispatch.
```
