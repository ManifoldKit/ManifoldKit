# Building a backend companion package

**Audience:** contributor
**Status:** living

A guide for anyone standing up a new companion package — a new local-inference
family alongside [`manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx)
and [`manifold-llama`](https://github.com/ManifoldKit/manifold-llama), or a
future third family. It answers "which core products do I depend on, how do I
prove my backend is conformant, and how do I stay in lockstep with core
releases" — the questions every companion package answers from scratch today
because the constraints are scattered across `Package.swift` comments,
`CLAUDE.md`, and test-support source docs.

This is the companion-package view. For the core repo's own test conventions,
suite layout, and per-backend contract walkthrough, [`Tests/README.md`](../Tests/README.md)
is canonical — this doc summarizes the parts a companion package needs and
links back rather than duplicating them. For QA practices that sit outside
the unit/integration/E2E pyramid, see [`docs/QA-PRACTICES.md`](QA-PRACTICES.md).

## 1. Which products to depend on

Core publishes two products a companion package's *sources* should ever need,
and two more for its *tests*. From `Package.swift`'s product declarations
(lines ~36–105):

| Product | What it is | When to depend on it |
|---|---|---|
| `ManifoldContract` | The thin Contract kernel: backend protocols (`InferenceBackend`, `EmbeddingBackend`), value/stream types (`GenerationConfig`, `GenerationEvent`, `Message`, tool types), streaming transforms. `@_exported import`s `ManifoldHardware` + `ManifoldModelCatalog`. Carries **no engine state** — `InferenceService`/`GenerationQueue`/`ToolRegistry` stay in `ManifoldInference`. | Your backend's core sources. This is the compile-against surface every family targets. |
| `ManifoldInference` | The engine: `InferenceService`, `GenerationQueue`, `ModelRegistry`, tool dispatch, `PromptAssembler`, `ContextWindowManager`. `@_exported import`s `ManifoldContract`, so importing this also gets you the Contract surface. | Only your **registrar** target — the piece that calls `BackendRegistrar`/`InferenceService` APIs to register your backend with a host app. `ManifoldFoundation` is the precedent: its bridge sources compile against `ManifoldContract` alone, but the target links `ManifoldInference` too because `FoundationBackends.register(with:)` needs the engine (Package.swift:398–401). |
| `ManifoldTestSupport` | Shared mocks and fakes (`MockInferenceBackend`, `CharTokenizer`, …). **No XCTest dependency** — safe to link from an executable, not just a test target. | Any target, including non-test code, that wants the mocks (e.g. a demo CLI). |
| `ManifoldBackendTestKit` | Contract-check machinery: `BackendContractChecks`, the contract mixins, `FixtureComparator`, the local-backend contract runner. **Links XCTest.** | Test targets only. |

**Never depend on `ManifoldBackendTestKit` from an executable target.** It
links XCTest, and XCTest is only resolvable inside an `xctest` host process.
The split between `ManifoldTestSupport` (no XCTest) and
`ManifoldBackendTestKit`/`ManifoldContractTestSupport` (links XCTest) exists
specifically so `fuzz-chat` (an executable) can depend on the mocks without
pulling in a framework that isn't on its runtime search path — merging them
back caused a real crash in PR #1409:

```
dyld[4010]: Library not loaded: @rpath/libXCTestSwiftSupport.dylib
```

`ContractTestSupportSplitAuditTest` (`Tests/ManifoldCoreTests/ContractTestSupportSplitAuditTest.swift`)
is core's tripwire against this regression recurring — it fails CI if the
split collapses. There is no equivalent tripwire in a companion repo; keep
your own `Package.swift` shape honest by construction (test targets only).

## 2. Contract adoption walkthrough

Every `InferenceBackend` implementation — in core or a companion package —
proves conformance through `BackendContractChecks`
(`Sources/ManifoldBackendTestKit/BackendContractChecks.swift`), published as
part of the `ManifoldBackendTestKit` product specifically so companion
packages can run the same suite against core's published API without
`@testable` access.

Minimal shape (see the kit's DocC catalog,
`Sources/ManifoldBackendTestKit/ManifoldBackendTestKit.docc/ManifoldBackendTestKit.md`,
for the full walkthrough):

```swift
final class MyBackendConformanceTests: XCTestCase,
    BackendContractMixin, GrammarFailClosedContractMixin {

    var contractBackendName: String { "my.backend" }
    func makeContractBackend() -> MyBackend { MyBackend() }

    func test_contract_allInvariants() {
        assertUniversalBackendContract()
    }

    func test_contract_grammarFailClosed() async throws {
        try await assertGrammarFailClosedContract()
    }

    // Named test_z_… so XCTest's alphabetical in-class ordering runs it
    // after the claim-recording tests in this class.
    func test_z_contract_allCapabilityClaims() {
        BackendContractChecks.resetCapabilityClaims(forBackend: contractBackendName)
        // …claimWithoutBehaviouralAssertion / real assertion families…
        BackendContractChecks.assertCapabilityMetaContract(
            backendName: contractBackendName,
            capabilities: makeContractBackend().capabilities
        )
    }
}
```

For an on-device backend, additionally adopt `LocalBackendContractParticipant`
and drive scenarios through `LocalBackendContractRunner`, with fixtures under
`Tests/Fixtures/backends/<name>/…` in your own repo.

**Capability semantics.** Every `Bool` on `BackendCapabilities` falls into one
of three categories, and the harness self-polices each:

1. **Claimed-true** — at least one passing behavior assertion must run for
   that capability, tracked via `recordCapabilityClaim`.
2. **Claimed-false** — a fail-closed assertion must run (e.g. a backend that
   sets `supportsGrammarConstrainedSampling = false` must throw
   `InferenceError.unsupportedGrammar(reason:)` when `GenerationConfig.grammar`
   is non-nil).
3. **Universal** — same contract for every backend (e.g. `isRemote`, a static
   label rather than a behavior).

**The process-global registry constraint — never run this suite under
`--parallel`.** The capability-claims registry (`claimsLock`-protected
`Set<String>` in `BackendContractChecks`) is process-global — one set shared
by every conformance class in the test process. The lifecycle is safe when
each backend's reset → claim → meta-contract sequence stays inside a single
test method body, but explicit `swift test --parallel` (with or without a
tuned `--num-workers`) interleaves backend test *classes* aggressively enough
that a meta-contract assertion can read a partial registry. In core's own
gate this surfaced as 57 normally-skipped tests registering as runs with 7
false failures. Run with swift-test's implicit scheduling — no `--parallel`
flag — same rule `scripts/test.sh` documents for the core repo.

**Non-vacuity.** A contract suite that compiles but executes zero checks is
worse than no suite — it's green evidence of nothing (the failure shape a
whole-file `#if` gate produces after a package split). Assert `N > 0`
executed checks per participant, and treat an all-skipped run as a red flag —
hardware gates should skip *scenarios*, never the universal invariants, which
require no model and must always execute.

## 3. The `@_spi(BackendInternals)` escape hatch

Some core internals are deliberately published to companion packages under
`@_spi(BackendInternals)` — visible to any importer that opts in with
`@_spi(BackendInternals) import ManifoldHardware` (or `ManifoldContract`),
but excluded from the ordinary public API surface and from DocC. Currently:

- `HeuristicTokenizer` (`Sources/ManifoldContract/HeuristicTokenizer.swift`) — the
  `TokenizerProvider` used for context-budget estimation.
- `MemoryPressureHandler` (`Sources/ManifoldHardware/MemoryPressureHandler.swift`) —
  the memory-pressure broadcast primitive local backends hook to evict caches
  under pressure.
- `GGUFKVCacheEstimator` (`Sources/ManifoldHardware/GGUFKVCacheEstimator.swift`) —
  KV-cache byte estimation for `ModelLoadPlan`, promoted from `package` visibility
  specifically for this seam.

Core's own consumers of the same SPI (`ManifoldInference/Extensions/ModelFitScorer+ModelInfo.swift`,
`ModelLoadPlan+ModelInfo.swift`, `ManifoldUI/ViewModels/ChatViewModel.swift` and its
`+MemoryPressure` extension) are the reference examples for the import shape.
Reach for `@_spi(BackendInternals)` when you need a core primitive that isn't
public API but is intentionally shared with backend packages; don't reach for
`@testable import` — that only works inside the same package.

## 4. Pin and release lifecycle

> **1.0 semantics.** Core and companion packages version independently —
> core reaching 1.0 does not require or wait for a companion's 1.0, and a
> companion is free to stay pre-1.0 tracking core's stable API from the
> outside. See [`docs/RELEASE-1.0.md` Policy 4](RELEASE-1.0.md#policy-4--core--companion-10-semantics).

- **Pin core with `.upToNextMinor`.** Core's own `companion-compat.yml`
  documents this explicitly: `swift package edit manifoldkit --path ../core`
  is described as "bypassing the `.upToNextMinor` pin (which only resolves to
  published tags)" — i.e. the companion's ordinary dependency declaration is
  an `.upToNextMinor` requirement against a tagged core release, not a branch
  or commit pin.
- **Auto-bump on core releases.** `.github/workflows/release-please.yml`'s
  `notify-companions` job fires a `repository_dispatch` of type `core-release`
  to `ManifoldKit/manifold-llama`, `ManifoldKit/manifold-mlx`, and
  `ManifoldKit/manifold-eval` whenever a core release ships. Each companion is
  expected to run its own listener workflow for that event type and re-resolve
  against the new tag — the dispatch is a no-op for any repo that hasn't
  shipped a matching `repository_dispatch: [core-release]` listener, so wire
  the listener and the dispatch target together.
- **Canary against core `main` before a risky release.** `companion-compat.yml`
  is an on-demand (`workflow_dispatch`) job that checks out both companion
  repos and builds each against an arbitrary core ref (default `main`) via
  `swift package edit`, catching a breaking seam change (e.g. a new
  non-frozen `GenerationEvent` case) before it ships in a tag. It's not a
  required gate — the breaking change usually lands on `main` before the
  release PR exists, so there's nothing on that PR's diff to gate — press the
  button by hand before merging a `feat!`/minor release PR.
- **Conventional Commits + release-please**, same as core: `feat:`/`fix:`
  drive the companion's own version bump; companion release notes are
  hand-rewritten (Prisma-style Highlights), not auto-published verbatim.

## 5. Vendored scenarios and fixtures

Historically, tools that consume `ManifoldTools`' scenario corpus resolved a
`Sources/ManifoldTools/Scenarios/built-in` path relative to the current
working directory — which only worked when the CWD happened to be the core
package root, and forced any out-of-repo consumer (including companion-side
tooling) to vendor a drift-prone copy of the corpus.

As of the unreleased 0.64 line (`Sources/ManifoldTools/Scenarios/ScenarioLoader.swift`),
the corpus ships as a `.copy` resource on the `ManifoldTools` target and
resolves via `Bundle.module` regardless of process working directory —
`swift run`, `swift test`, an installed `manifold-tools` binary, or a
companion package that depends on `ManifoldTools` all see the same canonical
corpus. If you were vendoring a copy of the built-in scenarios or the BFCL
fixtures (`Sources/ManifoldTools/BFCL/fixtures`, also a bundled resource),
drop the vendored copy once you're on a core version that includes this
change and consume `ScenarioLoader.loadBuiltIn()` directly instead.

## 6. Where to go next

- [`Tests/README.md`](../Tests/README.md) — suite layout, trait conventions,
  the "Adding a new backend" walkthrough with a full conformance-class example.
- [`docs/QA-PRACTICES.md`](QA-PRACTICES.md) — DX walkthroughs, audit tests, the
  audit sabotage suite, and cold-start conformance gates; the cross-cutting QA
  practices that sit outside the unit/integration/E2E pyramid.
- [`docs/HARDWARE-TOOLCHAIN.md`](HARDWARE-TOOLCHAIN.md) — the consolidated
  hardware/CI constraints (process-global `llama_backend_init`, simulator
  Metal gating, Swift Testing/XCTest process separation, toolchain ceiling)
  that apply across core and every companion package.
- [`docs/MIGRATION-0.48.md`](MIGRATION-0.48.md) — the mapping from the
  retired trait architecture to the current product/companion-package shape,
  useful background if you're porting an existing trait-gated backend.
