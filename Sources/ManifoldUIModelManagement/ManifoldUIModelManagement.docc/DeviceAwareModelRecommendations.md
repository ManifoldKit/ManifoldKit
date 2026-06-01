# Device-Aware Model Recommendations

Rank surfaced models by how well they fit the current device, and present that fit honestly.

## Overview

Picking a local model is hard: a 13B at Q2 sounds bigger than a 7B at Q4, but the 7B usually runs faster *and* answers better on a laptop. ManifoldKit scores each downloadable model along four dimensions — quality, speed, memory fit, and context — weights them for the user's task, and surfaces a single ranked order.

The guiding principle is **honesty of presentation, not raw numbers.** A pre-download throughput figure is a coarse estimate (memory bandwidth ÷ model footprint), accurate only to a factor. Showing "12.7 tok/s" reads as a measured fact and erodes trust when it turns out wrong. So the public surface deliberately exposes *qualitative buckets* on top of the raw values:

- ``SpeedClass`` — `fast` / `usable` / `sluggish` / `tooSlow`, bucketed for chat reading pace.
- ``FitQuality`` — `excellent` / `good` / `marginal` / `notRecommended`, bucketed from the composite.
- ``ModelFitScore/rationale`` — a one-line, factual "why" assembled from the buckets, never from raw decimals.

The raw ``ModelFitScore/estimatedTokensPerSecond`` and ``ModelFitScore/composite`` remain available for power users and tests — the buckets are an honest layer *on top of* them, not a replacement.

> Important: All of these are **approximate guidance, not guarantees.** Real throughput depends on prompt length, sampler settings, thermal state, and concurrent load. Present them as estimates, never as benchmarks.

There are two ways to consume this, and they share no code path — pick the one that matches your app.

## Path 1 — The built-in browser (high-level)

If you use ManifoldKit's model browser, you get device-aware recommendations automatically. The browser shows a **use-case picker** (General / Coding / Reasoning / Chat / …) that re-orders results, and a **Sort** control (`Recommended` / `Size` / `Downloads`) as an escape hatch.

The browser **ranks, it never filters** — every model stays visible regardless of the selected use case, so a power user can always reach the model they want. Each row shows a qualitative ``SpeedClass`` badge (Fast / Usable / Sluggish / Too slow), and the top-ranked model carries its one-line rationale. The exact on-disk size and quantization string stay visible for power users.

State lives on `ModelManagementViewModel`:

- `selectedUseCase` — the ``ModelUseCase`` to rank for (default `.general`).
- `sortMode` — `.recommended` / `.size` / `.downloads`.

`selectedUseCase` persists only when you inject a `UserDefaults` into the view model (never `UserDefaults.standard` implicitly — that is a `--parallel` test-flake source). Without one it is purely in-memory.

## Path 2 — Bring your own UI

If you render your own model list, drive it with `ModelFitScorer` directly. Score or rank your candidates, then present the qualitative abstractions — not the raw figures.

```swift,no-build
import ManifoldInference

// Your candidate models (e.g. from a HuggingFace search or a curated catalog).
let candidates: [DownloadableModel] = …

// Rank best-first for the user's task. `DeviceProfile.current` reads the host's
// memory + estimated bandwidth; inject a fixed profile in tests for determinism.
let ranked = ModelFitScorer().rank(candidates, useCase: .chat, device: .current)

for (model, score) in ranked {
    // Present the HONEST abstractions, not the raw estimate.
    let speed = score.speedClass.label        // "Fast" / "Usable" / "Sluggish" / "Too slow"
    let quality = score.fitQuality.label      // "Excellent" / "Good" / "Marginal" / "Not recommended"
    let why = score.rationale                 // "Fast on your device · fits comfortably · strong capability"

    print("\(model.displayName): \(quality) — \(speed). \(why)")

    // The raw values are still here for a power-user "details" disclosure, but
    // never present `estimatedTokensPerSecond` as a bare, unqualified fact.
    // e.g. show "~\(Int(score.estimatedTokensPerSecond)) tok/s (estimate)".
}
```

### Honesty guidance for your own UI

- Lead with ``SpeedClass`` and ``ModelFitScore/rationale``, not ``ModelFitScore/estimatedTokensPerSecond``.
- If you must show a number, label it as an estimate (`~N tok/s`) or show a range — never a bare decimal presented as fact.
- **Rank, don't filter.** Keep every model reachable; ordering is a recommendation, not a gate.
- Keep size and quantization visible — they are the ground truth a power user reasons about.
- The authoritative will-it-run gate stays `ModelLoadPlan`; ``ModelFitScore/willRun`` mirrors its verdict, and a non-runnable model is always ``FitQuality/notRecommended``.

## When recommendations do nothing

Recommendations require models to be *surfaced* in the first place. They have nothing to rank for:

- **Cloud-only apps** — there is no local file to fit to the device.
- **Single-bundled-model apps** — one model, no choice to rank.

To populate candidates you need either the HuggingFace search trait enabled or a populated `CuratedModel` catalog. Without surfaced models the picker and ranking are inert.

## Topics

### Core scoring

- ``ModelFitScorer``
- ``ModelFitScore``
- ``ModelUseCase``

### Honest presentation

- ``SpeedClass``
- ``FitQuality``
- ``ModelFitScore/rationale``
