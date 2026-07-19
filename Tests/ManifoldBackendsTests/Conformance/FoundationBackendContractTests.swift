#if canImport(FoundationModels)
import XCTest
import ManifoldInference
import ManifoldBackendTestKit
import ManifoldTestSupport
import ManifoldOllama
import ManifoldCloudSaaS
import ManifoldCloudCore
@testable import ManifoldFoundation

/// FoundationBackend conformance against the universal backend contract.
///
/// Universal invariants (``assertUniversalBackendContract``) exercise state
/// that does not require a live session — `isModelLoaded == false` and
/// `isGenerating == false` on init. These run in every build where
/// `FoundationModels` is importable (macOS 26 / iOS 26+), without hardware
/// or `RUN_SLOW_TESTS` gates.
///
/// Generation-level behavioural assertions (fixture replay, streaming
/// cancellation) live in ``LocalBackendContractTests`` and are gated behind
/// `RUN_SLOW_TESTS=1` so they only execute in the nightly tier where macOS 26
/// / iOS 26 and Apple Intelligence are present.
///
/// ## macOS 15 / CI safety
///
/// `@available(macOS 26, iOS 26, *)` on the class declaration is NOT enforced
/// by XCTest — the ObjC runtime discovers test methods regardless of OS
/// availability annotations (see ``FoundationBackendUnitTests`` for the same
/// pattern). The `setUp()` override below throws `XCTSkip` on macOS < 26 so
/// that `FoundationBackend()` — which references `FoundationModels` types — is
/// never instantiated on a runner that doesn't have the framework at runtime.
/// Without this guard the CI lane (macOS 15, Xcode 26 SDK) would attempt to
/// call `FoundationBackend.generate()` before the system model is available,
/// producing a SIGABRT from the `FoundationModels` framework asserting
/// internal preconditions.
@available(macOS 26, iOS 26, *)
@MainActor
final class FoundationBackendContractTests: XCTestCase,
                                            BackendContractMixin {

    let contractBackendName = "FoundationBackend"

    // Instance-scoped: XCTest instantiates a fresh test case per method, so
    // this registry starts empty for every method invocation. See
    // BackendContractChecks.ClaimRegistry.
    let capabilityClaimRegistry = BackendContractChecks.ClaimRegistry()

    func makeContractBackend() -> FoundationBackend {
        FoundationBackend()
    }

    // XCTest bypasses Swift @available on test classes (ObjC runtime discovery).
    // Throw XCTSkip here so no FoundationModels API is touched on macOS 15 CI.
    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ) else {
            throw XCTSkip("FoundationModels requires macOS 26 / iOS 26")
        }
    }

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if
    // FoundationBackend.init() incorrectly sets isModelLoaded=true.
    func test_contract_allInvariants() {
        assertUniversalBackendContract()
    }

    // removed: StructuredHistoryReceiver retired in #2312; Foundation replays via its SDK transcript, history threads via hints

    // MARK: - Per-capability claims + meta-contract

    /// All bootstrap claims and the meta-contract assertion are collapsed into
    /// one method, threaded through one shared `capabilityClaimRegistry`
    /// instance, so the registry is built and verified within a single test-case
    /// lifetime. Historically necessary because the registry was process-global
    /// (#1601); now the registry is instance-scoped (arch-plan 4.2) and this
    /// suite is safe under `swift test --parallel` — the collapse remains as a
    /// readable, self-contained shape, not a correctness requirement.
    ///
    /// Full behavioural proofs for each flag:
    /// - `supportsToolCalling`: requires Apple Intelligence (live session); lives in the E2E tier.
    /// - `supportsGuidedStructuredOutput`: requires a live session (GuidedGeneration round-trip).
    func test_contract_allCapabilityClaims() {
        // Reset first — harmless given a freshly-constructed registry, kept
        // for symmetry with suites that build up several scenarios in one
        // test method.
        BackendContractChecks.resetCapabilityClaims(capabilityClaimRegistry, forBackend: contractBackendName)

        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: contractBackendName,
            flag: "supportsToolCalling"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: contractBackendName,
            flag: "supportsGuidedStructuredOutput"
        )

        BackendContractChecks.assertCapabilityMetaContract(
            capabilityClaimRegistry,
            backendName: contractBackendName,
            capabilities: FoundationBackend().capabilities
        )
    }
}
#endif
