# Migration — `ImageGenerationConfig.steps` is now `Int?`

**Audience:** consumer
**Status:** living
**Applies to:** v0.77.0 and later (backend authors — including
companion-package maintainers — are a *producer* here too; see "Backend
authors" below)

## The compiler diagnostics you'll hit

```
error: value of optional type 'Int?' must be unwrapped to a value of type 'Int'
error: cannot convert value of type 'Int?' to expected argument type 'Int'
```

…on any expression that reads `config.steps`, or any call to
`ImageGenerationConfig.init(steps:...)` / `ImageGenerationConfigSnapshot.init(steps:...)`
that relied on the old non-optional parameter to reject `nil`.

## What changed

`ImageGenerationConfig.steps` changed from `Int` (default `20`) to `Int?`
(default `nil`). `nil` means **the backend resolves the loaded model's own
preset default** instead of the caller — or the type's own default — guessing
a step count that fits every model shape. `ImageGenerationConfigSnapshot.steps`
(the persistence-layer mirror) changed the same way.

An explicit value still overrides the backend's preset and is clamped to
whatever range that backend supports.

## Why

The old default of `20` was tuned for full-precision diffusion. Distilled
models — SDXL Turbo, FLUX Schnell — are trained for roughly 1–4 steps; a bare
`ImageGenerationConfig()` (the demo app's image-gen tool path, and any other
caller that didn't set `steps` explicitly) silently ran a distilled model
through 5–20x the denoise work it needed, for no quality gain. #2453 M2.

This is the same defect shape `ModelManifest.contextWindow` had before it went
optional (see
[`MIGRATION-manifest-context-window-optional.md`](MIGRATION-manifest-context-window-optional.md)):
a fixed constant standing in for "the caller didn't say," indistinguishable
from a deliberate choice. Making the absence of a caller preference
representable on the type — the same `nil`-defers-to-backend precedent as
`GenerationConfig.maxThinkingTokens` — lets each backend decide the right
default for the model it actually has loaded, instead of one number serving
every model.

## How to migrate

### Consumers — usually no change

The initializers take `Int?`, and Swift promotes a non-optional `Int`
implicitly, so a call site that already passed a specific value compiles
unchanged:

```swift
import ManifoldKit

_ = ImageGenerationConfig(steps: 4, width: 1024, height: 1024)   // still fine
```

The change that matters is on the *default* path. If you were relying on the
implicit `20` — including a bare `ImageGenerationConfig()` — stop guessing and
let the backend choose. If your app has a UI control for step count, thread
the user's choice through as `Int?` and only pass a value when the user
actually set one — don't backfill `?? 20` at the call site, which
reintroduces the exact guess this change removes:

```swift
import ManifoldKit

// Thread the user's own choice through as `Int?`. Passing `nil` straight
// through — rather than `userChosenSteps ?? 20` — is what actually lets the
// backend's model-preset default take over.
func makeImageConfig(userChosenSteps: Int?) -> ImageGenerationConfig {
    ImageGenerationConfig(steps: userChosenSteps)
}
```

### Persisted configs

`ImageGenerationConfig` and `ImageGenerationConfigSnapshot` are both
`Codable`, and the custom coding for the optional field uses
`decodeIfPresent`/`encodeIfPresent`. A payload written before this release
still carries an explicit `"steps": 20` and decodes as `.some(20)` — old rows
keep behaving exactly as they did. A new `nil` omits the key entirely rather
than encoding `"steps": null`.

## Backend authors

If you maintain a conforming `ImageGenerationBackend` — including the
`ManifoldMLX` companion-package backend — this is a
**producer**-side change with a real behavioral contract, not just a type
change to absorb. `Sources/ManifoldContract/ImageGenerationBackend.swift`'s
"Step-count resolution contract" (on `generate(prompt:config:)`) states it
normatively; the short version:

1. When `config.steps` is `nil`, resolve your own loaded model's preset
   default (e.g. ~2 for a distilled model, 20–50 for full diffusion) —
   don't substitute a fixed constant.
2. Every `ImageGenerationEvent.progress`/`.preview` you emit — **including
   the first tick** — must carry the real resolved count in `total`, never
   a placeholder `0`. `total: 0` on every tick leaves
   `GeneratedMediaProgressCardView` (and any other UI reading
   `ImageGenerationProgress.totalSteps`) stuck showing "Starting…" with a
   zero-width progress bar for the entire run, because nothing downstream
   ever corrects `total` after the first tick.

`manifold-mlx`'s `makeParams` needs its own adaptation to satisfy this — its
`guidanceScale` handling already does `config.guidanceScale ?? defaults.cfgWeight`,
and `steps` gets the same treatment. The coordinated
`fix/steps-nil-resolves-preset` branch must remain available while core ships
v0.77.0 and until the core example has switched back to its published
`manifold-mlx` version pin. After v0.77.0 ships, manifold-mlx#191 must update
its core requirement to `.upToNextMinor(from: "0.77.0")` and publish its
companion pin-bump release; only then may the core follow-up restore the
example's `minorVersion: 0.5.0` pin and delete that branch.

## Related

- [`MIGRATION-manifest-context-window-optional.md`](MIGRATION-manifest-context-window-optional.md) —
  the `Int` → `Int?` precedent this migration follows.
- `docs/API-DESIGN.md` — layer ownership and the pre-1.0 breaking-change policy.
- Principle 6 (*errors are visible*): a fabricated default is a silent failure
  wearing a plausible number.
