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
                                            BackendContractMixin,
                                            StructuredHistoryReceiverContractMixin {

    let contractBackendName = "FoundationBackend"

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

    // MARK: - StructuredHistoryReceiver conformance

    /// 0.50 multimodal prep (#1710): FoundationBackend opts into
    /// ``StructuredHistoryReceiver`` so it captures the unflattened
    /// ``MessagePart`` shape — including image parts — that the legacy
    /// flattened history discards. This verifies round-trip retention via the
    /// shared mixin; the image-attachment consumption is a documented NO-OP on
    /// the current toolchain.
    ///
    /// Touches only in-memory state (no `LanguageModelSession`), so it is safe
    /// once `setUp`'s macOS-26 guard has passed.
    func test_contract_structuredHistoryReceiver() {
        assertStructuredHistoryReceiverContract(
            readHistory: { $0._installedStructuredHistory }
        )
    }

    // MARK: - Per-capability claims + meta-contract

    /// All bootstrap claims and the meta-contract assertion are collapsed into
    /// one method so the registry is built and verified within a single process.
    /// Under `swift test --parallel` each test method runs in an isolated worker
    /// process; splitting claim recording across several methods meant the
    /// meta-contract reader saw an empty registry in its worker. (#1601)
    ///
    /// Full behavioural proofs for each flag:
    /// - `supportsToolCalling`: requires Apple Intelligence (live session); lives in the E2E tier.
    /// - `supportsGuidedStructuredOutput`: requires a live session (GuidedGeneration round-trip).
    func test_contract_allCapabilityClaims() {
        // Reset first so a prior run of this method in the same process doesn't
        // leave stale claims that could mask a newly-removed flag.
        BackendContractChecks.resetCapabilityClaims(forBackend: contractBackendName)

        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsToolCalling"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsGuidedStructuredOutput"
        )

        BackendContractChecks.assertCapabilityMetaContract(
            backendName: contractBackendName,
            capabilities: FoundationBackend().capabilities
        )
    }
}
#endif
