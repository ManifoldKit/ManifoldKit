# ManifoldKit — Per-trait cost table

> **Generated document.** The table sections are regenerated from `docs/trait-costs.json`
> by `scripts/measure-trait-costs.sh`. The "Why the clone is heavy" section is
> hand-written prose (marked below). Do not edit the `BEGIN GENERATED` … `END GENERATED`
> regions by hand — re-run the script instead. `TraitCostsDriftTest` fails CI if
> the generated regions drift from the JSON.

<!-- BEGIN GENERATED — do not edit by hand; run scripts/measure-trait-costs.sh to regenerate -->

## Per-trait cost table

> Generated 2026-06-10T19:40:00Z on Apple Silicon (arm64).
> Toolchain: `swift-driver version: 1.148.6 Apple Swift version 6.3.2 (swiftlang-6.3.2.1.108 clang-2100.1.1.101)`.
>
> **Approx. note:** Binary-delta and build-time columns are approximations measured on one machine
> at one point in time. Rerun `scripts/measure-trait-costs.sh` after any heavy dependency bump.
>
> **Resolution note:** Checkout weights are fetched *regardless of trait set* — SwiftPM traits gate
> compilation and linking, not dependency resolution. See the "Why the clone is heavy" section below.

| Trait | Adds modules | Transitive deps | Checkout weight MB ¹ | Artifact MB ² | Binary impact approx. KB ³ | Cold-build added approx. s ⁴ |
|-------|--------------|-----------------|----------------------|---------------|----------------------------|-----------------------------|
| `FoundationOnly` | FoundationBackend only (removes MLX+Llama+HuggingFace defaults) | _(none beyond baseline)_ | — | — | +0 | -48 |
| `MLX` | ManifoldMLX + StableDiffusion + FluxSwift | `mlx-swift`, `mlx-swift-lm` | ~121 | — | +42652 | +464 |
| `Llama` | ManifoldLlama | `llama.swift` | — | ~617 | +8 | — |
| `HuggingFace` | ManifoldHuggingFace | `swift-huggingface` | ~2 | — | +5026 | — |
| `CloudSaaS` | ManifoldCloud (SaaS bodies) | _(none beyond baseline)_ | — | — | +731 | — |
| `Ollama` | ManifoldCloud (Ollama bodies) | _(none beyond baseline)_ | — | — | +731 | — |
| `MCP` | ManifoldMCP + ManifoldMCPHost | _(none beyond baseline)_ | — | — | +1914 | — |
| `MCPBuiltinCatalog` | ManifoldMCP built-in catalog | _(none beyond baseline)_ | — | — | +31 | — |
| `Server` | ManifoldServer + Hummingbird | `EventSource`, `swift-nio`, `swift-crypto`, `swift-collections`, `swift-atomics`, `swift-system` | ~74 | — | +12157 | — |
| `Macros` | ManifoldMacrosPlugin + @ToolSchema | `swift-syntax` | ~11 | — | +0 | — |
| `Skills` | ManifoldSkills | _(none beyond baseline)_ | — | — | +224 | — |
| `Voice` | ManifoldVoice | _(none beyond baseline)_ | — | — | +429 | — |
| `Tools` | ManifoldTools + manifold-tools CLI | _(none beyond baseline)_ | — | — | +632 | — |
| `AppIntents` | ManifoldAppIntents | _(none beyond baseline)_ | — | — | +279 | — |
| `AnyLanguageModel` | AnyLanguageModel bridge | _(none beyond baseline)_ | — | — | — | — |
| `Fuzz` | fuzz-chat executable (real backends) | _(none beyond baseline)_ | — | — | — | — |

¹ Checkout weight: disk space in `.build/checkouts/<dep>`. Fetched on first `swift package resolve` **regardless of trait set**.

² Artifact MB: `.build/artifacts/llama.swift` — the pre-built llama.cpp xcframework. Downloaded on first resolve regardless of trait set.

³ Approx. binary delta: sum of stripped `.o` sizes for the specific modules each trait adds, measured from a release build on arm64 macOS. Not the total build delta vs a baseline — shared infrastructure (ManifoldInference, ManifoldRuntime, etc.) is excluded and counted once. Not the final linked binary size — dead-stripping by the app linker typically reduces this further. `Macros` shows 0 because swift-syntax compiles as a build-time compiler plugin (host executable), not a runtime library. `Llama` shows 8 KB because LlamaSwift is a prebuilt xcframework (the 617 MB xcframework column reflects its actual link-time cost).

⁴ Approx. cold-build delta: wall-clock seconds added to a release build on Apple Silicon (`.build/{debug,release,build.db}` wiped between runs; `.build/checkouts` and `.build/artifacts` kept warm). Variance ±10–20 s on a loaded machine.

<!-- END GENERATED -->

<!-- BEGIN GENERATED COMBINATIONS -->

## Named build-mode combinations

These map to the modes in `scripts/build-modes.sh`. Costs here are **not** the sum of individual rows — shared infrastructure is compiled once.

| Mode | Traits enabled | Approx. checkout+artifact MB¹ | Notes |
|------|----------------|-------------------------------|-------|
| **FoundationOnly** | `FoundationOnly` | ~259 cloned, ~0 compiled | ≤5 MB compiled; all ~876 MB fetched once |
| **local-only** (default) | `MLX`, `Llama`, `HuggingFace` | ~259 cloned | Default when no `traits:` override; on-device only |
| **cloud-only** | `CloudSaaS` or `Ollama` | ~259 cloned | Pure HTTP; no local model deps compiled |
| **full** | all non-Fuzz traits | ~259 cloned | ~617 MB xcframework + Metal compile |

¹ All modes clone the same ~259 MB of source checkouts plus the ~617 MB llama.cpp xcframework on first resolve. The FoundationOnly mode _compiles_ ~5 MB. See footnote 1 in the table above and the resolution note.

<!-- END GENERATED COMBINATIONS -->

---

<!-- BEGIN HAND-WRITTEN — edit freely; drift test does not cover this section -->

## Why the clone is heavy — and what we're doing about it

### The resolution gap in SwiftPM traits

SwiftPM trait support ([SE-0450](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md), landed Swift 6.1) gates *compilation* and *linking* — whether a target is compiled and whether a library product is linked into your binary. It does **not** gate dependency *resolution*: every `.package(url:)` entry in `Package.swift` is cloned into `.build/checkouts` on first `swift package resolve`, regardless of the active trait set.

SE-0450 explicitly calls out fetch-pruning as a "Future direction" that was descoped from the initial implementation. Binary targets ([SE-0305](https://github.com/apple/swift-evolution/blob/main/proposals/0305-swiftpm-binary-target-improvements.md)) download the artifact-bundle index eagerly and fetch xcframeworks unconditionally — the index-based conditional fetch mechanism only helps executable plugins, not Apple-platform libraries.

**What this means in practice:** even a `FoundationOnly` consumer (no MLX, no Llama, no HuggingFace) clones ~259 MB of source checkouts and downloads the ~617 MB llama.cpp xcframework on first resolve. The *compiled* artifact is still ≤5 MB (CI-enforced by `scripts/check-foundation-only-bundle.sh` and the `foundation-only-build` CI gate). The binary you ship to the App Store is bounded by what the linker pulls in — not by what SwiftPM cloned.

### App Store reality

The checkout weight is a **one-time developer machine cost** (and a CI cache line), not a user-visible cost. What the user downloads is the stripped, dead-stripped App Store binary. For `FoundationOnly` builds that is verifiably ≤5 MB for the ManifoldBackends module.

**Important runtime note:** Apple's App Store Review Guidelines §2.5.2 prohibit downloading executable code at runtime. Model *weights* are fine; inference *runtimes* must ship in the app bundle. That's why the slim `FoundationOnly` packaging matters for indie apps: the Apple Foundation Models runtime is provided by the OS at zero bundle cost, making it the only inference path where the runtime itself doesn't add to your IPA.

See [docs/AppStoreSubmission.md](AppStoreSubmission.md) for the full submission checklist, including the encryption-export classification and privacy-manifest requirements for each build mode.

### Roadmap candidates under evaluation

These are directions under active evaluation — **not commitments**. ManifoldKit's module seams are already cut to make them tractable:

**(a) Satellite packages for heavy families.** The only resolution-pruning mechanism SwiftPM has today is moving a dependency into a separate package that consumers opt into explicitly (the Vapor/onnxruntime-gpu pattern). `ManifoldMLX`, `ManifoldLlama`, and `ManifoldCloud` already depend on `ManifoldInference` (or `ManifoldContract`) directly and carry zero cross-family symbols — the seams exist. The cost is an extra `.package(url:)` line in consumer manifests and a separate release cadence.

**(b) Prebuilt mlx-swift xcframework.** The dominant cold-build cost on Apple Silicon is compiling mlx-swift's Metal shaders (~117 MB checkout, ~100 MB compiled with Metal shader IR). Firebase/Google ship their ML SDKs as prebuilt xcframeworks to avoid exactly this. If ml-explore publishes a prebuilt xcframework tag, ManifoldKit can switch `mlx-swift` to a binary target and eliminate the Metal compile entirely for consumers. Tracked in umbrella issue #1002.

**(c) Adopt toolchain trait-pruning when it ships.** SE-0450 names fetch-pruning as an explicit future direction. When it lands in a Swift toolchain that ManifoldKit's minimum deployment supports, dependency-attributed checkout weights (the table above) will drop toward zero for traits the consumer hasn't enabled. No code changes required on ManifoldKit's side — the `Package.swift` trait declarations are already the right shape.

<!-- END HAND-WRITTEN -->
