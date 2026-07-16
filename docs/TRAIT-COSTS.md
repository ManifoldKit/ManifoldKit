# ManifoldKit — Per-trait cost table

**Audience:** consumer
**Status:** living

> **Generated document.** The table sections are regenerated from `docs/trait-costs.json`
> by `scripts/measure-trait-costs.sh`. The prose section is
> hand-written (marked below). Do not edit the `BEGIN GENERATED` … `END GENERATED`
> regions by hand — re-run the script instead. `TraitCostsDriftTest` fails CI if
> the generated regions drift from the JSON.
>
> **v0.48 (PR C2):** the MLX / Llama / HuggingFace / Fuzz / FoundationOnly traits
> are retired. The heavy MLX and llama.cpp families (and their mlx-swift /
> mlx-swift-lm / llama.swift / swift-transformers dependencies) moved to the
> [manifold-mlx](https://github.com/ManifoldKit/manifold-mlx) and
> [manifold-llama](https://github.com/ManifoldKit/manifold-llama) companion
> packages (#1749). A plain `swift build` of core no longer clones or compiles
> any of them. Only two genuine build-cost levers remain.

<!-- BEGIN GENERATED — do not edit by hand; run scripts/measure-trait-costs.sh to regenerate -->

## Per-trait cost table

> Generated 2026-06-10T19:40:00Z on Apple Silicon (arm64); retired-trait rows removed 2026-06-13 (v0.48 PR C2).
> Toolchain: `swift-driver version: 1.148.6 Apple Swift version 6.3.2 (swiftlang-6.3.2.1.108 clang-2100.1.1.101)`.
>
> **Approx. note:** Binary-delta and build-time columns are approximations measured on one machine
> at one point in time. Rerun `scripts/measure-trait-costs.sh` after any heavy dependency bump.

| Trait | Adds modules | Transitive deps | Checkout weight MB ¹ | Artifact MB ² | Binary impact approx. KB ³ | Cold-build added approx. s ⁴ |
|-------|--------------|-----------------|----------------------|---------------|----------------------------|-----------------------------|
| `Server` | ManifoldServer + Hummingbird | `EventSource`, `swift-nio`, `swift-crypto`, `swift-collections`, `swift-atomics`, `swift-system` | ~74 | — | +12157 | — |
| `Macros` | ManifoldMacrosPlugin + @ToolSchema | `swift-syntax` | ~11 | — | +0 | — |

¹ Checkout weight: disk space in `.build/checkouts/<dep>`. Fetched on first `swift package resolve` **regardless of trait set** (SwiftPM traits gate compilation, not resolution).

² Artifact MB: prebuilt binary artifacts in `.build/artifacts`. None remain in core since v0.48 — the ~617 MB llama.cpp xcframework moved to manifold-llama.

³ Approx. binary delta: sum of stripped `.o` sizes for the specific modules each trait adds, measured from a release build on arm64 macOS. `Macros` shows 0 because swift-syntax compiles as a build-time compiler plugin (host executable), not a runtime library.

⁴ Approx. cold-build delta: wall-clock seconds added to a release build on Apple Silicon. Variance ±10–20 s on a loaded machine.

<!-- END GENERATED -->

<!-- BEGIN GENERATED COMBINATIONS -->

## Named build-mode combinations

These map to the modes in `scripts/build-modes.sh`. Costs here are **not** the sum of individual rows — shared infrastructure is compiled once.

| Mode | Traits enabled | Notes |
|------|----------------|-------|
| **default** | _(none — there are no default traits since v0.48)_ | Full core surface: Foundation + Cloud backends, UI, persistence, HuggingFace downloads |
| **cloud-only** | _(none — build the `ManifoldOllama` / `ManifoldCloudSaaS` products)_ | Pure HTTP; link-out (not compile-out) of unwanted families — see docs/FIPS.md |
| **server** | `Server` | Adds Hummingbird + the OpenAI-compatible HTTP server executable |
| **macros** | `Macros` | Adds swift-syntax (~647 files) for the @ToolSchema plugin |

Local inference (MLX / GGUF) is an extra `.package` line, not a trait: see the companion packages.

<!-- END GENERATED COMBINATIONS -->

---

<!-- BEGIN HAND-WRITTEN — edit freely; drift test does not cover this section -->

## Why the heavy families left — the resolution gap in SwiftPM traits

SwiftPM trait support ([SE-0450](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md), landed Swift 6.1) gates *compilation* and *linking* — whether a target is compiled and whether a library product is linked into your binary. It does **not** gate dependency *resolution*: every `.package(url:)` entry in `Package.swift` is cloned into `.build/checkouts` on first `swift package resolve`, regardless of the active trait set. SE-0450 explicitly calls out fetch-pruning as a descoped "Future direction".

Through v0.47 that meant even a Foundation-only consumer cloned ~259 MB of source checkouts and downloaded the ~617 MB llama.cpp xcframework on first resolve. The only resolution-pruning mechanism SwiftPM has today is moving a dependency into a separate package that consumers opt into explicitly (the Vapor/onnxruntime-gpu pattern) — which is exactly what v0.48 did: the MLX and llama.cpp families live in the manifold-mlx / manifold-llama companion packages, and a core-only consumer never fetches their dependencies at all. (Traits also proved unreliable at the resolution boundary — see the #1737 diagnosis in `docs/MIGRATION-0.48.md`.)

### App Store reality

What the user downloads is the stripped, dead-stripped App Store binary; core's compiled overhead without the companion packages is small (no ML runtimes at all). Apple's App Store Review Guidelines §2.5.2 prohibit downloading executable code at runtime — model *weights* are fine; inference *runtimes* must ship in the app bundle. The Apple Foundation Models runtime is provided by the OS at zero bundle cost, making a core-only (Foundation + cloud) app the leanest possible shape. See [docs/AppStoreSubmission.md](AppStoreSubmission.md) for the full submission checklist.

<!-- END HAND-WRITTEN -->
