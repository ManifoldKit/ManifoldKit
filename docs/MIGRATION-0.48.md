# Migrating to ManifoldKit v0.48 — "The Packaging Release"

**Audience:** consumer
**Status:** historical

> **Superseded for shims — read [MIGRATION-shims-retired.md](MIGRATION-shims-retired.md) first.**
> The `ManifoldBackends` umbrella and `DefaultBackends` cross-family glue that body sections below
> still describe as "still compiles" were **removed in P7 (#1837)** — `import ManifoldBackends`,
> `import ManifoldCloud`, and `DefaultBackends` **no longer compile**. Any step that says the
> umbrella "still compiles in v0.48" is **historical only** (true at the 0.48 cut, false now).
> For the current import/registrar model use the shims-retired guide. This document stays as the
> canonical v0.47 → v0.48 trait/companion map; treat every shim example as historical.

v0.48 retires the SwiftPM trait architecture in favour of **library products**, and moves
the heavy local-inference backends (MLX, llama.cpp) into **companion packages**:

- [`ManifoldKit/manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx) — the `ManifoldMLX` module
- [`ManifoldKit/manifold-llama`](https://github.com/ManifoldKit/manifold-llama) — the `ManifoldLlama` module

> **This release lands automatically if you depend on ManifoldKit with `from:`.**
> SwiftPM's `from: "0.47.0"` resolves `0.47.0..<1.0.0` — there is no special pre-1.0
> caret rule — so your next clean resolve picks up v0.48. If you want opt-in upgrades
> while ManifoldKit is pre-1.0, pin with
> `.package(url: "…/ManifoldKit", .upToNextMinor(from: "0.47.0"))` and bump deliberately.

The sections below are headed by the **literal error strings** you will see, so a search
for the message lands on the fix.

---

## package 'manifoldkit' has no trait named 'MCP'

(Also: `has no trait named 'MCPBuiltinCatalog'`, `'Voice'`, `'Tools'`, `'AppIntents'`,
`'Skills'`, `'Ollama'`, `'CloudSaaS'`, or `'AnyLanguageModel'` — same fix.)

SwiftPM hard-errors when a consumer manifest enables a trait the package no longer
declares. These nine traits were retired in v0.48. **Delete them from the `traits:`
array** in your `.package(…)` line; nothing is lost — every gated module still ships,
as an always-compiled module or as a product you import explicitly:

| Retired trait | v0.48 replacement |
|---|---|
| `MCP` | `ManifoldMCP` compiles unconditionally — keep `import ManifoldMCP`, drop the trait. |
| `MCPBuiltinCatalog` | Built-in `MCPCatalog` descriptors always compiled — drop the trait. |
| `Voice` | `ManifoldVoice` product — link/import it, drop the trait. |
| `Tools` | `ManifoldTools` / `manifold-tools` always available — drop the trait. |
| `AppIntents` | `ManifoldAppIntents` product — link/import it, drop the trait. |
| `Skills` | `ManifoldSkills` product — link/import it, drop the trait. |
| `Ollama` | **`ManifoldOllama` product** — always compiled into core / the `ManifoldKit` umbrella; link just `ManifoldOllama` if you want only that family. (`ManifoldBackends` is gone — see [MIGRATION-shims-retired.md](MIGRATION-shims-retired.md).) |
| `CloudSaaS` | **`ManifoldCloudSaaS` product** (OpenAI Chat + Responses, Anthropic, LM Studio / custom endpoints) — always compiled into core / the `ManifoldKit` umbrella; link just `ManifoldCloudSaaS` for the single family. |
| `AnyLanguageModel` | **`ManifoldAnyLanguageModel` product** — opt in by importing it (see below). Not part of the `ManifoldKit` umbrella; consumers that never import it never link it. |

```swift,no-build
// Before (v0.47):
.package(url: "https://github.com/ManifoldKit/ManifoldKit.git",
         from: "0.47.0",
         traits: ["MCP", "Voice", "Ollama", "CloudSaaS", "AnyLanguageModel"])

// After (v0.48): traits array gone (or holding only surviving traits)
.package(url: "https://github.com/ManifoldKit/ManifoldKit.git", from: "0.48.0")
```

For the AnyLanguageModel provider bridge (Gemini, xAI, Groq, Mistral, OpenRouter, …),
add the product to your target and import the module:

```swift,no-build
// target dependencies:
.product(name: "ManifoldAnyLanguageModel", package: "ManifoldKit")
```

```swift,no-build
import ManifoldAnyLanguageModel

let backend = AnyLanguageModelBackend()
```

See [PROVIDER-BRIDGE.md](PROVIDER-BRIDGE.md) for provider URLs and capability limits.

---

## package 'manifoldkit' has no trait named 'MLX'

(Also: `has no trait named 'Llama'`, `'HuggingFace'`, `'Fuzz'`, or `'FoundationOnly'` —
the five traits retired by the companion-package split, PR C2.)

Same shape as the section above — delete the trait from your `traits:` array — but the
replacements differ:

| Retired trait | v0.48 replacement |
|---|---|
| `MLX` | The MLX family moved to the [`manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx) companion package — see [no such module 'ManifoldMLX'](#no-such-module-manifoldmlx) below for the install steps. |
| `Llama` | The llama.cpp/GGUF family moved to [`manifold-llama`](https://github.com/ManifoldKit/manifold-llama) — see [no such module 'ManifoldLlama'](#no-such-module-manifoldllama) below. |
| `HuggingFace` | `ManifoldHuggingFace` (model search/download machinery) compiles unconditionally — drop the trait. |
| `Fuzz` | `ManifoldFuzz` and the `fuzz-chat` CLI compile unconditionally — drop the trait. `fuzz-chat` now drives Ollama / OpenAI / Foundation / mock / chaos (default backend: ollama); the MLX/Llama fuzz factories moved to the companions. |
| `FoundationOnly` | The lean build is now the **default**: core has no heavy ML dependencies at all. Don't add the companion packages and you get the former `FoundationOnly` footprint without any flag. See [AppStoreSubmission.md](AppStoreSubmission.md). |

With these gone there are **no default traits left** — plain `swift build` /
`swift test` is the full core build, and `--disable-default-traits` is a no-op you
should delete from scripts and CI.

---

## no such module 'ManifoldMLX'

The MLX backend lives in the companion package
[`ManifoldKit/manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx) as of v0.48.
The module name is unchanged (`import ManifoldMLX` still compiles) — only the package
that provides it moved, taking the ~700 MB mlx-swift dependency graph with it. Core
ManifoldKit builds with no MLX checkout at all.

**SwiftPM:**

```swift,no-build
// Package.swift
.package(url: "https://github.com/ManifoldKit/ManifoldKit.git", from: "0.48.0"),
.package(url: "https://github.com/ManifoldKit/manifold-mlx.git", from: "0.1.0"),

// target dependencies:
"ManifoldKit",
.product(name: "ManifoldMLX", package: "manifold-mlx"),
```

**Xcode:** File ▸ Add Package Dependencies… ▸ enter
`https://github.com/ManifoldKit/manifold-mlx` ▸ Add Package ▸ tick the `ManifoldMLX`
product for your app target. (Xcode consumers never edit a manifest — this is the
whole migration.)

**Then register the backend.** Companion backends are invisible until registered;
pass the registrar to `quickStart(backends:)` (registration must happen *before*
the model-registry refresh and selection policy run, which is exactly what this
overload guarantees):

```swift,no-build
import ManifoldKit
import ManifoldMLX   // from manifold-mlx

let kit = try await ManifoldKit.quickStart(backends: [MLXBackends.self])
```

Bring-your-own-bootstrap consumers call `MLXBackends.register(with: service)` after
`DefaultBackends.register(with:)`.

---

## no such module 'ManifoldLlama'

Same move as MLX: the llama.cpp/GGUF backend lives in
[`ManifoldKit/manifold-llama`](https://github.com/ManifoldKit/manifold-llama), module name
unchanged, taking the ~617 MB prebuilt llama.cpp xcframework out of core's resolve.

**SwiftPM:**

```swift,no-build
// Package.swift
.package(url: "https://github.com/ManifoldKit/ManifoldKit.git", from: "0.48.0"),
.package(url: "https://github.com/ManifoldKit/manifold-llama.git", from: "0.1.0"),

// target dependencies:
"ManifoldKit",
.product(name: "ManifoldLlama", package: "manifold-llama"),
```

**Xcode:** File ▸ Add Package Dependencies… ▸ `https://github.com/ManifoldKit/manifold-llama`
▸ Add Package ▸ tick `ManifoldLlama` for your app target.

**Then register:**

```swift,no-build
import ManifoldKit
import ManifoldLlama   // from manifold-llama

let kit = try await ManifoldKit.quickStart(
    backends: [LlamaBackends.self],
    seed: .recommendedSmallModel()   // optional: live chat on first launch
)
```

Or `LlamaBackends.register(with: service)` on a hand-assembled service.

---

## 'register(with:)' is deprecated — the ManifoldBackends umbrella shim

> **Historical (v0.48 only).** P7 (#1837) removed the shim entirely — see
> [MIGRATION-shims-retired.md](MIGRATION-shims-retired.md). The paragraphs below
> describe the short-lived deprecated state at the 0.48 cut; they are **not**
> current guidance.

At v0.48, `import ManifoldBackends` still compiled as a deprecated shim carrying
only the always-compiled families (Apple Foundation Models + the cloud backends).
It could no longer hand you MLX or llama.cpp, so a consumer that relied on
`DefaultBackends.register(with:)` for local inference compiled clean and
**silently lost local models** unless it added a companion package. That failure
mode was deliberately loud via deprecation warnings and the runtime no-backend
diagnostic.

**Today:** `import ManifoldBackends` / `DefaultBackends` do not compile. Import
the families (or the `ManifoldKit` umbrella) and pass companion registrars to
`quickStart(backends:)`.

---

## product 'ManifoldBackends' not found

This is the error you see **now** (post-P7) if anything still depends on the
retired umbrella product. The fix: drop `ManifoldBackends`, depend on the
companion package(s) you need (`manifold-mlx` / `manifold-llama`) and/or the
in-core family products, and pass registrars to `quickStart(backends:)`.
`import ManifoldKit` + explicit companion imports is the supported shape — see
[MIGRATION-shims-retired.md](MIGRATION-shims-retired.md).

---

## Traits that survive v0.48

| Trait | Why it survives |
|---|---|
| `Server` | Genuine build-cost lever: gates `ManifoldServer` and its Hummingbird/swift-nio dependency tree on a leaf edge. |
| `Macros` | Gates the `@ToolSchema` macro plugin and its ~647-file swift-syntax tree. Build-time-only cost; off by default. |
| `SystemAIProviderExtension`, `CoreAI` | WWDC 2026 forward stubs — no targets attached. |

Everything else is products now. If your `traits:` array contains anything not in
this table, delete it.

---

## What you'll see if you forget a step

All of these are designed to surface at **assembly/launch time**, not on the first send:

- **No backend at all** (core only, pre-iOS 26/macOS 26, no cloud endpoint, no
  companions): `quickStart` throws `ManifoldKitError.noBackendsRegistered`.
  Pass a companion registrar to `quickStart(backends:)` — manifold-llama (GGUF)
  or manifold-mlx (MLX) — register an in-core family, or run on iOS 26 /
  macOS 26+ for the built-in Foundation Models backend. (Older diagnostic text
  that named `DefaultBackends.register` is historical — that type is gone.)
- **On-disk model, missing backend**: the model registry flags the file instead of
  auto-selecting it, and logs
  `quickStart: skipping <file> — no registered backend can load <type> models. Add the
  matching backend package (manifold-llama for GGUF, manifold-mlx for MLX) and pass its
  registrar to quickStart(backends:).`
- **Starter seed with no GGUF backend**: the seed download is skipped (never an error)
  with `quickStart(seed:): no registered backend can load gguf models — seed skipped. …`
- **Umbrella-shim reliance**: compile errors on `ManifoldBackends` /
  `DefaultBackends` (removed in P7 — see [MIGRATION-shims-retired.md](MIGRATION-shims-retired.md)).

If you see any of these, you're one `.package(…)` line + one `quickStart(backends:)`
argument away from working local inference.

---

## Staying behind (for now)

Pre-1.0, ManifoldKit can break between minors and `from:` auto-delivers those breaks.
To adopt v0.48 on your own schedule:

```swift,no-build
.package(url: "https://github.com/ManifoldKit/ManifoldKit.git",
         .upToNextMinor(from: "0.47.0"))
```

When you do migrate, do it in one sitting: remove retired traits, add the companion
package(s), switch to `quickStart(backends:)`, build, and check the launch log for the
diagnostics above. The companion packages pin core with `.upToNextMinor(from: "0.48.0")`,
so core patch releases flow to you automatically; companion minors track core minors.
