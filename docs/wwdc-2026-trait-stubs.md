# WWDC 2026 Pre-emptive Trait Stubs

**Audience:** contributor
**Status:** living

Added 2026-05-31, 8 days before WWDC 2026 (June 8). **Updated 2026-06-16**
against the shipped Xcode 27 / macOS 27 beta SDK — the pre-WWDC guesses below
each section have been resolved against ground truth. Works toward issue #1577.

Both traits remain pure-manifest stubs in `Package.swift`: no targets, no source
files, `unlocks: []`. This document records what the beta SDK actually exposes so
a later real-code PR can act on resolved facts instead of rumour.

## `CoreAI` — resolved: reachable via the `apple/coreai-models` package + executor seam

The **bare** `CoreAI` framework is Apple's tensor runtime. It consumes a
proprietary `.aimodel` format via `AIModel(contentsOf:)` / `InferenceFunction` /
`NDArray`, and at that layer has **no `LanguageModel` protocol and no GGUF or MLX
path** — nothing to conform to directly.

**But that is not the whole picture (corrected 2026-06-17).** Apple also shipped
the open-source [`apple/coreai-models`](https://github.com/apple/coreai-models)
Swift package (macOS/iOS 27, BSD-3) — model export recipes plus a Swift runtime.
Its `CoreAILM` product provides:

- `struct CoreAILanguageModel: LanguageModel` (`typealias Executor = CoreAIExecutor`),
  loaded via `init(resourcesAt:) async throws` from an `.aimodel` bundle, and
- `CoreAIExecutor: LanguageModelExecutor` with the streaming `respond(...)` channel,

so a `.aimodel` runs through `LanguageModelSession(model:)` like any other
`LanguageModel`. **`.aimodel` is therefore reachable through the exact
`LanguageModelExecutor` seam documented below** — it is *not* orthogonal after
all. An MK integration would consume `apple/coreai-models` and adopt that seam,
carrying the **same** deferred tool-loop-ownership tradeoff (see below), not the
bare-framework `AIModel`/`NDArray` surface. (These are export *recipes* + a
runtime, not pre-bundled Apple `.aimodel` downloads — verified against a clone of
the repo: gallery LLM recipes incl. Qwen3-0.6B/4B, Qwen3-Coder-30B-A3B (MoE),
Mistral-7B, gpt-oss-20b; constrained generation via the vendored `xgrammar`.)

**Recommendation (deferred, out of scope here):** the `CoreAI` trait name remains
misleading — it implies a *bare-framework* seam, when the real path is the
`apple/coreai-models` package via `LanguageModelExecutor`. A later real-code PR
should rename or retire it. We are **not** renaming traits in this docs-only
change; renaming a `Package.swift` trait is a manifest decision for that PR.

## `SystemAIProviderExtension` — investigation: symbol NOT FOUND in beta SDK

The pre-WWDC stub assumed Apple would ship a "system AI provider" extension point
letting third-party apps plug into Siri / Writing Tools as AI backends, with an
unconfirmed protocol name / entitlement / Info.plist key.

**Finding (evidence-based, macOS 27 beta SDK):** no such symbol exists.

- `SystemAIProvider` appears **nowhere** in the SDK — zero hits across all 580
  `*.swiftinterface` files under
  `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.sdk/System/Library/Frameworks`,
  zero hits in framework ObjC `Headers/`, and zero matches among
  `EXAppExtensionPoint` / `ai-provider` / `model-provider` extension-point
  identifiers in framework `Info.plist`s.
- The closest real mechanism is **AppIntents `AssistantSchema`** (e.g.
  `AssistantSchemaIntent`, `AssistantSchemaEntity`, `AssistantSchemaEnum` in
  `AppIntents.framework`). But that is the **inverse direction**: it lets an app
  expose *its own* intents/entities to Siri via Apple's intelligence, not a slot
  for a third-party app to supply a *language-model backend* to the system.
- There is no FoundationModels-side provider-registration surface either.

**Conclusion:** as of the macOS 27 beta SDK, the "third-party app as system AI
provider" backend slot that this trait anticipated **does not exist as a public
API**. The trait describes a surface Apple has not shipped. It should stay a
stub; do not invent a symbol to gate against. If a later beta adds one, re-run
the sweep and update this section.

## `LanguageModelExecutor` — the real third-party model seam (confirmed)

The genuine public seam for plugging a non-Apple model into FoundationModels is
the `LanguageModel` / `LanguageModelExecutor` protocol pair, confirmed in:

`.../MacOSX27.sdk/System/Library/Frameworks/FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`

```swift
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
public protocol LanguageModel : Sendable {
  associatedtype Executor : LanguageModelExecutor where Self == Self.Executor.Model
  var capabilities: LanguageModelCapabilities { get }
  var executorConfiguration: Self.Executor.Configuration { get }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
public protocol LanguageModelExecutor : Sendable {
  associatedtype Configuration : Hashable, Sendable
  associatedtype Model : LanguageModel
  func prewarm(model: Self.Model, transcript: Transcript)
  init(configuration: Self.Configuration) throws
  nonisolated(nonsending) func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: Self.Model,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws
}
```

Notes from the swiftinterface:

- This is a genuinely **public, non-privileged** protocol. Apple's own
  `SystemLanguageModel` and `PrivateCloudComputeLanguageModel` conform via the
  same pair (each exposes a public `Executor : LanguageModelExecutor`). There is
  no special-cased Apple path — third parties conform identically. (Anthropic and
  Google shipped conformances.)
- `LanguageModelCapabilities` advertises `.vision`, `.guidedGeneration`,
  `.reasoning`, `.toolCalling`.
- The streaming channel surfaces `appendText` / reasoning / `toolCall` events —
  i.e. FoundationModels owns the tool-call *protocol*, not the host app.

### Deferred architectural decision (NOT resolved here)

Adopting `LanguageModelExecutor` for MLX / Llama is *technically* viable, but it
**forks tool-loop ownership** to FoundationModels. ManifoldKit's
`GenerationToolDispatchLoop`, the approval gate (`toolCallApproved`),
`maxToolIterations`, and handoff detection have **no FoundationModels
equivalent** — conforming would mean ceding the turn loop that `ConversationRuntime`
owns. This is an unresolved either/or, recorded here as a deferred decision, not
a recommendation:

- **(a)** Keep MLX/Llama on the existing `InferenceBackend` seam (MK owns the
  tool loop); FoundationModels stays one backend among several.
- **(b)** Add `LanguageModel` conformances so MLX/Llama also appear inside the
  system FoundationModels surface — and accept FM-owned tool orchestration there.

If (b) is ever pursued, that conformance work belongs in the **companion
`manifold-mlx` / `manifold-llama` repos**, not core — core does not depend on
those backends.

## OS availability floor

Both real seams are `@available(iOS 27.0, macOS 27.0, visionOS 27.0,
watchOS 27.0, *)`, `tvOS` unavailable. That is **above** ManifoldKit's n-1 floor
(macOS 15 / iOS 18), so any real adoption needs `#available(macOS 27, iOS 27, *)`
guards and cannot ship unguarded until GA (~Sept 2026, when the floor bumps).

**Do not** bump `swift-tools-version` to chase the beta: core CI is pinned to
Xcode 26.3 / Swift 6.3; bumping breaks `resolve-check` and `fuzz`. Probe the beta SDK
compile-only (as this investigation did) until GA.

## Status summary

| Trait | Real surface | Verdict |
|-------|--------------|---------|
| `CoreAI` | bare framework: no LM protocol — **but `apple/coreai-models` package ships `CoreAILanguageModel`/`CoreAIExecutor`** | `.aimodel` reachable via the executor seam (same tool-loop-fork tradeoff); rename trait later |
| `SystemAIProviderExtension` | none found in beta SDK | Symbol does not exist; stay a stub |
| (the real seam) | `FoundationModels.LanguageModelExecutor` | Viable but forks tool-loop ownership; companion-repo work; macOS 27 floor |

## How to activate post-GA (unchanged guidance)

When a real surface is adopted:

1. Add the concrete source target(s) and a `swiftSettings: [.define(...)]`
   annotation gated `.when(traits: [...])`.
2. Remove the relevant trait name from `pendingMapping` in
   `FeatureMatrixTests.swift` **and** add the real `ManifoldCapability` cases it
   unlocks (a trait with `unlocks: []` must stay in `pendingMapping` — the matrix
   invariant requires it).
3. Add `#available(macOS 27, iOS 27, *)` guards (floor is above n-1 until GA).
4. Update this file with the confirmed API surface.
