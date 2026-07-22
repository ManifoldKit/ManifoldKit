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

    // MARK: - Grammar fail-closed

    /// FoundationBackend disclaims ``BackendCapabilities/supportsGrammarConstrainedSampling``
    /// (Apple's FoundationModels SDK exposes no grammar surface), so a non-nil
    /// `config.grammar` MUST throw ``InferenceError/unsupportedGrammar(reason:)``
    /// rather than being silently dropped — the same contract every other backend
    /// honours. This is the test that was missing when FoundationBackend ignored
    /// `config.grammar` entirely.
    ///
    /// Unlike the cloud/Ollama suites, this does NOT use the shared
    /// ``BackendContractChecks/assertGrammarFailClosedContract`` helper: that
    /// helper calls `loadModel(...)`, and `FoundationBackend.loadModel` probes a
    /// live Apple Intelligence session that CI/simulator lack. The grammar check
    /// is placed before the model-loaded guard, so we assert it directly on an
    /// unloaded backend — no session required.
    ///
    /// Sabotage-evidence: delete the `if config.grammar != nil, …` fail-closed
    /// block at the top of `FoundationBackend.generate(...)`; `generate` then
    /// throws `.inferenceFailure("No model loaded")` instead of
    /// `.unsupportedGrammar`, and the `case .unsupportedGrammar` guard below trips.
    @discardableResult
    private func assertGrammarFailsClosed(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let backend = FoundationBackend()
        var config = GenerationConfig()
        config.grammar = "root ::= \"hello\""
        var threwUnsupportedGrammar = false
        XCTAssertThrowsError(
            try backend.generate(prompt: "x", systemPrompt: nil, config: config),
            "FoundationBackend must throw when given a grammar it cannot honour",
            file: file, line: line
        ) { error in
            if case .unsupportedGrammar = error as? InferenceError {
                threwUnsupportedGrammar = true
            } else {
                XCTFail(
                    "Expected InferenceError.unsupportedGrammar; got \(String(describing: error))",
                    file: file, line: line
                )
            }
        }
        return threwUnsupportedGrammar
    }

    func test_contract_grammarFailClosed() {
        XCTAssertTrue(
            assertGrammarFailsClosed(),
            "FoundationBackend must fail closed on grammar-constrained sampling"
        )
    }

    // MARK: - Per-capability claims + meta-contract

    /// All bootstrap claims, the fail-closed grammar assertion, and the
    /// meta-contract assertion are collapsed into one method, threaded through
    /// one shared `capabilityClaimRegistry` instance, so the registry is built
    /// and verified within a single test-case lifetime. The grammar assertion is
    /// folded in (rather than left only in `test_contract_grammarFailClosed`)
    /// because the meta-contract now requires a recorded claim for declared-false
    /// fail-closed flags (`BackendContractChecks.failClosedContractFlags`) and
    /// XCTest gives each method a fresh registry. The suite is safe under
    /// `swift test --parallel` (instance-scoped registry, arch-plan 4.2).
    ///
    /// Full behavioural proofs for each flag:
    /// - `supportsToolCalling`: requires Apple Intelligence (live session); lives in the E2E tier.
    /// - `supportsGrammarConstrainedSampling` (declared false): the fail-closed
    ///   assertion above proves the disclaim; the claim is recorded here.
    ///
    /// (`supportsGuidedStructuredOutput` is no longer bootstrapped: it was
    /// flipped to `false` because the `.guided` strategy is not wired
    /// end-to-end — see #2354 and `FoundationBackend.capabilities`.)
    func test_contract_allCapabilityClaims() {
        // Reset first — harmless given a freshly-constructed registry, kept
        // for symmetry with suites that build up several scenarios in one
        // test method.
        BackendContractChecks.resetCapabilityClaims(capabilityClaimRegistry, forBackend: contractBackendName)

        // Fail-closed grammar contract. Records the claim in this method's
        // registry so the meta-contract's declared-false requirement is met.
        _ = assertGrammarFailsClosed()
        BackendContractChecks.recordCapabilityClaim(
            capabilityClaimRegistry,
            backend: contractBackendName,
            flag: "supportsGrammarConstrainedSampling"
        )

        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: contractBackendName,
            flag: "supportsToolCalling"
        )

        BackendContractChecks.assertCapabilityMetaContract(
            capabilityClaimRegistry,
            backendName: contractBackendName,
            capabilities: FoundationBackend().capabilities
        )
    }
}
#endif
