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

¹ Checkout weight: disk space in `.build/checkouts/<dep>` for the **remaining** opt-in traits (`Server` / `Macros`). Those trait deps still resolve when the trait is enabled. Heavy ML (mlx-swift / llama.cpp) is **not** in core anymore — it only appears if you add a companion package.

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

Through v0.47 that meant even a Foundation-only consumer cloned ~259 MB of source checkouts and downloaded the ~617 MB llama.cpp xcframework on first resolve. v0.48 fixed the heavy case by moving MLX and llama.cpp into companion packages: a core-only consumer never fetches those dependencies. The remaining traits (`Server`, `Macros`) still follow the SE-0450 rule for *their* deps (resolve when enabled / linked), but that cost is measured in tens of MB, not hundreds. (Traits also proved unreliable at the resolution boundary for the heavy families — see the #1737 diagnosis in `docs/MIGRATION-0.48.md`.)

### App Store reality

What the user downloads is the stripped, dead-stripped App Store binary; core's compiled overhead without the companion packages is small (no ML runtimes at all). Apple's App Store Review Guidelines §2.5.2 prohibit downloading executable code at runtime — model *weights* are fine; inference *runtimes* must ship in the app bundle. The Apple Foundation Models runtime is provided by the OS at zero bundle cost, making a core-only (Foundation + cloud) app the leanest possible shape. See [docs/AppStoreSubmission.md](AppStoreSubmission.md) for the full submission checklist.

## FAQ: why not keep the glue in core and only externalize the engines?

The companion packages look heavy until you open them: `ManifoldLlama` /
`ManifoldMLX` are a few thousand lines of Swift. Almost all of the cost is
**upstream** — the llama.cpp xcframework binary, mlx-swift and its graph —
not the ManifoldKit-shaped wrappers. So a natural design is:

> Keep the glue (`ManifoldLlama` / `ManifoldMLX`) as products of ManifoldKit,
> and let consumers who want local inference add the engine packages the same
> way they add companions today.

That design does **not** work under SwiftPM's package graph rules. The short
reason: **the package that imports an engine must declare that engine as a
dependency, and every declared dependency is resolved for every consumer of
that package.**

### What SwiftPM actually does

1. A target can only `import` modules that its **own** package lists in
   `Package.swift` (as a `.package` / `.binaryTarget` edge and a target
   dependency). The *consumer* cannot "inject" llama.cpp or mlx-swift into
   ManifoldKit so that core compiles `ManifoldLlama` without core declaring
   those deps.
2. Declaring those edges on ManifoldKit means they appear in core's package
   identity. On `swift package resolve`, **every** client of ManifoldKit
   fetches them — including apps that only use cloud chat or Foundation
   Models and never link a local backend product.
3. SwiftPM traits ([SE-0450](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md))
   gate *compilation* and *linking* (whether a target is built and whether a
   product is linked into *your* binary). They do **not** gate *resolution*:
   unused trait edges still clone into `.build/checkouts` (and still download
   binary targets). Fetch-pruning is a documented future direction, not
   current behavior. That is why the pre-v0.48 "`MLX` / `Llama` trait"
   shape still made Foundation-only consumers pay hundreds of megabytes.

So "glue in core + optional engine packages on the consumer" needs all three
of: glue compiles as part of ManifoldKit, engines only resolve when asked
for, and core-only apps never see those engines. SwiftPM can give you at
most two.

### What that implies for the split

| Shape | Core-only resolve skips ML engines? | Glue lives in ManifoldKit package? |
|-------|--------------------------------------|------------------------------------|
| Glue + engine deps in core `Package.swift` (even as an "optional" product or trait) | No | Yes |
| Glue + engines in a **separate package** (companions today) | Yes | No — next door |
| Multi-package monorepo (second `Package.swift` in the same git tree) | Yes | Same repo, still a second package identity |
| Protocols / contracts only in core (`InferenceBackend`, …); implementations next to the engines | Yes | Implementations stay out |

Core already owns the **contract**. Companions own the **implementations**,
because implementations must import the engines, and therefore must live in
a package whose manifest lists those engines. Moving only the binary out of
core while leaving `import LlamaSwift` / MLX-using sources in core still
forces core's manifest to depend on that binary — so core-only consumers
still resolve it.

The companion working trees are small (order of ~1–2 MB of source, a few
thousand LOC of glue). The size you avoid on a core-only resolve is the
**upstream** weight (llama.cpp xcframework download/extract; mlx-swift and
related checkouts — historically hundreds of MB when these lived in core).

### What companions are *not* solving

- They are not "we prefer many repos for its own sake." A monorepo of several
  packages would preserve the resolve split; it would not remove the second
  `.package(...)` line for local inference.
- They are not required for cloud, Ollama-as-HTTP, Foundation Models, UI,
  persistence, or the turn loop — those stay in core.
- They do not make `manifold-server --backend mlx|llama` work out of the
  box: the CLI is a core product and cannot link companions without putting
  those deps back on core's resolve path. Hosts that need GGUF/MLX over the
  OpenAI-compatible HTTP surface embed `ManifoldServer.serve` and inject a
  `ServerBackendProvider` from a binary that *does* depend on a companion
  (see `ManifoldServer` DocC / [QUICKSTART-SERVER.md](QUICKSTART-SERVER.md)).

### Pointers

- Install / migrate: [MIGRATION-0.48.md](MIGRATION-0.48.md),
  [QUICKSTART.md → Customizing backends](QUICKSTART.md#customizing-backends)
- Authoring a new family: [COMPANION-BACKENDS.md](COMPANION-BACKENDS.md)
- Remaining opt-in trait costs (`Server`, `Macros`) only: tables above

<!-- END HAND-WRITTEN -->
