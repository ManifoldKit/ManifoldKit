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

    func test_contract_allInvariants() {
        assertUniversalBackendContract()
    }

    func test_contract_grammarFailClosed() async throws {
        try await assertGrammarFailClosedContract()
    }

    // Named test_z_… so XCTest's alphabetical in-class ordering runs it after
    // the claim-recording tests in this class.
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

For local (on-device) backends, additionally declare a
``LocalBackendContractParticipant`` and one test method per
``LocalBackendContractRunner`` scenario, with fixtures under
`Tests/Fixtures/backends/<name>/…` in your repo.

## Never run the contract suite with `swift test --parallel`

The capability-claims registry in ``BackendContractChecks`` is
**process-global** (an `NSLock`-protected set shared by every conformance
class in the test process). The registry lifecycle is safe when each backend's
reset → claim → meta-contract sequence stays inside one test method, but
explicit `--parallel` (with or without a tuned `--num-workers`) interleaves
backend test *classes* aggressively enough that the registry can be partial
when a meta-contract assertion reads it. In ManifoldKit's own gate this
surfaced as 57 normally-skipped tests registering as runs with 7 false
failures; `scripts/test.sh` documents the same rule for the core repo.

Run the suite with swift-test's implicit scheduling (no `--parallel` flag),
and keep the entire registry lifecycle for a backend inside a single test
method body.

## Non-vacuity: assert that checks actually executed

A contract suite that compiles but executes zero checks is worse than no
suite — it's green evidence of nothing. This is the failure shape that
whole-file `#if` gates produce after a package split (the file compiles to
nothing and CI stays green). Every adopting suite must:

- assert N > 0 executed checks per participant — e.g. a final test that calls
  `BackendContractChecks.capturedClaims()` and asserts your backend's prefix
  appears, or a suite-level counter asserting every scenario method ran;
- treat an all-skipped run as a red flag: hardware gates (`RUN_SLOW_TESTS`,
  simulator checks) should skip *scenarios*, never the universal invariants,
  which require no model and must always execute.

## Topics

### Contract checks

- ``BackendContractChecks``
- ``BackendContractMixin``
- ``GrammarFailClosedContractMixin``
- ``ConversationHistoryReceiverContractMixin``
- ``StructuredHistoryReceiverContractMixin``

### Local-backend scenarios

- ``LocalBackendContractParticipant``
- ``LocalBackendContractRunner``
- ``LocalDriverCoverageChecks``

### Fixture comparison

- ``FixtureComparator``
- ``XCTAssertEventsMatch(actual:fixtureURL:mode:file:line:)``
