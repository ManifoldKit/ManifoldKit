# WWDC 2026 Trait-Stubs Disposition

**Audience:** contributor
**Status:** living

The pre-WWDC traits were added on 2026-05-31 and retired by
[PR #2536](https://github.com/ManifoldKit/ManifoldKit/pull/2536) on 2026-09-18.
Neither `SystemAIProviderExtension` nor `CoreAI` unlocked a target or source
file. Keeping names for unadopted APIs made no-op switches part of the public
manifest.

The retirement resolves the core trait disposition in
[#1577](https://github.com/ManifoldKit/ManifoldKit/issues/1577). `Package.swift`,
`FeatureMatrix`, its tests, the generated [feature matrix](FeatureMatrix.md),
and the trait-gate audit agree that only the genuine `Server` / `Macros`
build switches remain; the old `pendingMapping` exception was removed. Consumers
should follow [the migration guidance](MIGRATION-platform-floor-26.md#remove-the-retired-traits).

The remaining provider-adapter work belongs to
[#2436](https://github.com/ManifoldKit/ManifoldKit/issues/2436), with llama/GGUF
scope in `manifold-llama`. It does not revive either core trait. An MLX
conformance was explicitly declined because upstream
[`MLXFoundationModels`](https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXFoundationModels)
already provides that bridge.

## Release SDK recheck — 2026-09-26

A read-only sweep used Xcode 27.0 (`27A266a`) and the installed
`MacOSX27.0.sdk`, under
`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs`.
Within `System/Library/Frameworks`, case-insensitive searches for
`SystemAIProvider`, `ai-provider`, and `model-provider` found zero matches in
588 `*.swiftinterface` files and 6,281 header files (`*.h` / `*.hpp` under
`Headers`). This SDK framework tree contains no `Info.plist` files, so the
historical extension-point plist sweep below was **not** repeated against the
release SDK. These searches establish absence of the anticipated names in the
inspected files, not absence of every possible extension mechanism.

The release FoundationModels `arm64e-apple-macos.swiftinterface` still declares
`LanguageModel` at line 1483 and `LanguageModelExecutor` at line 1711, with
iOS/macOS/visionOS/watchOS 27 availability and tvOS unavailable. This is
interface evidence only: no adapter, model inference, entitlement check, or
OS-27 session runtime test was performed in this recheck.

The June investigations and September beta-4 spike in #1577 remain historical
evidence. The following API excerpt and observations came from those earlier
investigations; they are not new release-runtime qualification.

## `CoreAI` — historical investigation; trait retired

The June investigation described the **bare** `CoreAI` framework as Apple's
tensor runtime. That inspected surface consumed a
proprietary `.aimodel` format via `AIModel(contentsOf:)` / `InferenceFunction` /
`NDArray`, and at that layer had **no `LanguageModel` protocol and no GGUF or MLX
path** — nothing to conform to directly.

**Historical correction (2026-06-17).** Apple also shipped
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
carrying the **same** tool-loop-ownership tradeoff (see below), not the
bare-framework `AIModel`/`NDArray` surface. (These are export *recipes* + a
runtime, not pre-bundled Apple `.aimodel` downloads — verified against a clone of
the repo: gallery LLM recipes incl. Qwen3-0.6B/4B, Qwen3-Coder-30B-A3B (MoE),
Mistral-7B, gpt-oss-20b; constrained generation via the vendored `xgrammar`.)

**Disposition.** `CoreAI` was retired as a no-op trait. A future integration,
if it becomes useful, should add a real target for the `apple/coreai-models` /
`LanguageModelExecutor` seam rather than restoring a manifest switch.

## `SystemAIProviderExtension` — historical beta investigation; trait retired

The pre-WWDC stub assumed Apple would ship a "system AI provider" extension point
letting third-party apps plug into Siri / Writing Tools as AI backends, with an
unconfirmed protocol name / entitlement / Info.plist key.

**Historical finding (macOS 27 beta SDK, June 2026):** the anticipated names
were not found in the inspected SDK files.

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
API** in that investigation. The contemporary recommendation was to retain
the stub pending a later SDK check. That recommendation is superseded by the
retirement in PR #2536 and the scoped release-SDK recheck above; do not restore
a no-op trait or invent a symbol to gate against.

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

### Adapter scope and tool-loop ownership

The llama/GGUF `LanguageModel` / `LanguageModelExecutor` adapter is tracked in
[#2436](https://github.com/ManifoldKit/ManifoldKit/issues/2436), primarily in
`manifold-llama`. Its current acceptance requires a supported SDK/runtime pair,
executor-owned model lifecycle, and real external-consumer GGUF and session
verification. The historical compiling prototype does not satisfy those runtime
requirements. MLX conformance remains declined in favor of upstream
`MLXFoundationModels`.

FoundationModels owns tool dispatch on this adapter path. ManifoldKit's
`GenerationToolDispatchLoop`, approval gate (`toolCallApproved`),
`maxToolIterations`, handoff detection, and runtime persistence/finalization do
not automatically run inside a `LanguageModelSession`. This is a separate
consumer surface from `ConversationRuntime`, whose existing turn loop remains
ManifoldKit's orchestration path. Adapter implementation and those compatibility
checks are outside the completed core trait retirement.

## OS availability floor

The inspected FoundationModels protocol pair is
`@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)`, with tvOS
unavailable. With current OS 27, **n-1 is OS 26**, matching ManifoldKit's iOS 26 /
macOS 26 deployment floor. GA does not make OS-27-only APIs unconditional for
OS-26 consumers: adoption still needs appropriate compile-time handling and
runtime availability guards, such as `#available(macOS 27, iOS 27, *)`.

A provider adapter must preserve compilation with supported toolchains and
older-platform behavior; it must not raise core's `swift-tools-version` merely
to probe a newer SDK. The concrete supported SDK/runtime qualification belongs
to #2436, rather than a prerequisite that the n-1 floor reach OS 27.

## Status summary

| Surface | Evidence and disposition |
|---------|--------------------------|
| `CoreAI` trait | Retired as a no-op switch. Historical `apple/coreai-models` investigation does not create a core target. |
| `SystemAIProviderExtension` trait | Retired as a no-op switch. The anticipated names were absent from the inspected release SDK interfaces and headers. |
| `FoundationModels.LanguageModelExecutor` adapter | Release interface exists at OS 27 availability; llama/GGUF implementation and runtime verification remain in #2436. MLX duplication is declined. |

## Future adoption

There is no dormant trait to activate and no `pendingMapping` entry to remove.
If a later integration needs a core build switch, propose it with a concrete
target, real consumer gate, capability mapping, tests, and migration guidance.
The existing #2436 companion adapter scope does not require either retired
trait to return. Record SDK/interface evidence separately from executed runtime
verification, and keep OS-26 behavior supported when adopting OS-27 APIs.
