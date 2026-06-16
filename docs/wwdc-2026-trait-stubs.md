# WWDC 2026 Pre-emptive Trait Stubs

Added 2026-05-31, 8 days before WWDC 2026 (June 8). **Updated 2026-06-16**
against the shipped Xcode 27 / macOS 27 beta SDK — the pre-WWDC guesses below
each section have been resolved against ground truth. Works toward issue #1577.

Both traits remain pure-manifest stubs in `Package.swift`: no targets, no source
files, `unlocks: []`. This document records what the beta SDK actually exposes so
a later real-code PR can act on resolved facts instead of rumour.

## `CoreAI` — resolved: DEAD END for this repo

`CoreAI` is Apple's tensor runtime. It consumes a proprietary `.aimodel` format
via `AIModel(contentsOf:)` / `InferenceFunction` / `NDArray`. It has **no
`ModelExecutor`/`LanguageModel` protocol and no GGUF or MLX path** — it is
orthogonal to `ManifoldMLX` / `ManifoldLlama`, not an integration candidate.
ManifoldKit cannot adopt it as a backend seam: there is nothing to conform to.

**Recommendation (deferred, out of scope here):** the `CoreAI` trait name is now
misleading — it implies a backend seam that does not exist. A later real-code PR
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

**Do not** bump `swift-tools-version` to chase the beta: CI runs Xcode 26.5 /
Swift 6.3.2; bumping breaks `resolve-check` and `fuzz`. Probe the beta SDK
compile-only (as this investigation did) until GA.

## Status summary

| Trait | Real surface | Verdict |
|-------|--------------|---------|
| `CoreAI` | `.aimodel` tensor runtime, no LM protocol | Dead end; rename/retire in a later PR |
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
