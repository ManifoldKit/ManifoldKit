# ``ManifoldBackendTestKit``

Importable backend contract-check machinery for ManifoldKit backend packages.

## Overview

`ManifoldBackendTestKit` packages the contract suite every `InferenceBackend`
implementation must satisfy — universal invariants, the capability-claims
meta-contract, fail-closed families, the local-backend scenario runner, the
fixture comparator, and driver-coverage tripwires — as a `.library` product.
Companion backend packages (manifold-mlx, manifold-llama) depend on it to run
the exact same checks core's own conformance suites run, without `@testable`
access to core internals.

The kit links XCTest. It is deliberately a **separate product** from
`ManifoldTestSupport` (mocks, fixtures, fakes — no XCTest): merging
XCTest-linking helpers into the mock target caused
`dyld: Library not loaded: @rpath/libXCTestSwiftSupport.dylib` crashes in
non-test executables (ManifoldKit PR #1409). Depend on this product **only
from test targets**.

## Running the contract checks from a backend package

Add the products to your package's test target:

```swift,no-build
.testTarget(
    name: "MyBackendTests",
    dependencies: [
        .product(name: "ManifoldBackendTestKit", package: "ManifoldKit"),
        .product(name: "ManifoldTestSupport", package: "ManifoldKit"),
        "MyBackend",
    ]
)
```

Then declare one `XCTestCase` per backend, adopting the mixins:

```swift,no-build
import XCTest
import ManifoldInference
import ManifoldBackendTestKit

final class MyBackendConformanceTests: XCTestCase,
    BackendContractMixin, GrammarFailClosedContractMixin {

    var contractBackendName: String { "my.backend" }
    func makeContractBackend() -> MyBackend { MyBackend() }

    // Instance-scoped: XCTest instantiates a fresh test case per method, so
    // this registry starts empty for every method invocation — no cross-test
    // or cross-class bleed, even under `swift test --parallel`.
    let capabilityClaimRegistry = BackendContractChecks.ClaimRegistry()

    func test_contract_allInvariants() {
        assertUniversalBackendContract()
    }

    func test_contract_grammarFailClosed() async throws {
        try await assertGrammarFailClosedContract()
    }

    // Named test_z_… so XCTest's alphabetical in-class ordering runs it after
    // the claim-recording tests in this class.
    func test_z_contract_allCapabilityClaims() {
        BackendContractChecks.resetCapabilityClaims(capabilityClaimRegistry, forBackend: contractBackendName)
        // …claimWithoutBehaviouralAssertion / real assertion families…
        BackendContractChecks.assertCapabilityMetaContract(
            capabilityClaimRegistry,
            backendName: contractBackendName,
            capabilities: makeContractBackend().capabilities
        )
    }
}
```

For local (on-device) backends, additionally declare a
``LocalBackendContractParticipant`` and one test method per
``LocalBackendContractRunner`` scenario, with fixtures under
`Tests/Fixtures/backends/<name>/…` in your repo.

## The contract suite is safe under `swift test --parallel`

The capability-claims registry lives on ``BackendContractChecks/ClaimRegistry``,
an instance owned by the test case (a stored property, per the recipe above) —
not a process-global `static var`. Because XCTest instantiates a fresh test
case per test method, every method invocation gets its own empty registry with
no reset boilerplate required for isolation, and no shared mutable state
survives across concurrently-scheduled test classes or methods.

This replaced a process-global `nonisolated(unsafe) static var` (arch-plan
item 4.2) that made `swift test --parallel` unsafe for every contract suite in
the fleet — under explicit `--parallel`, backend test *classes* interleaved
aggressively enough that the shared registry could be partial when a
meta-contract assertion read it (ManifoldKit's own gate saw 57
normally-skipped tests register as runs with 7 false failures). That failure
mode is now structurally impossible: there is nothing left to share.

Suites may still collapse a backend's reset → claim → meta-contract sequence
into a single test method (see the recipe above) — that remains a readable,
self-contained shape, not a correctness requirement.

## Non-vacuity: assert that checks actually executed

A contract suite that compiles but executes zero checks is worse than no
suite — it's green evidence of nothing. This is the failure shape that
whole-file `#if` gates produce after a package split (the file compiles to
nothing and CI stays green). Every adopting suite must:

- assert N > 0 executed checks per participant — e.g. a final test that calls
  `BackendContractChecks.capturedClaims(registry)` and asserts your backend's
  prefix appears, or a suite-level counter asserting every scenario method ran;
- treat an all-skipped run as a red flag: hardware gates (`RUN_SLOW_TESTS`,
  simulator checks) should skip *scenarios*, never the universal invariants,
  which require no model and must always execute.

## Topics

### Contract checks

- ``BackendContractChecks``
- ``BackendContractMixin``
- ``GrammarFailClosedContractMixin``

### Local-backend scenarios

- ``LocalBackendContractParticipant``
- ``LocalBackendContractRunner``
- ``LocalDriverCoverageChecks``

### Fixture comparison

- ``FixtureComparator``
- ``XCTAssertEventsMatch(actual:fixtureURL:mode:file:line:)``
