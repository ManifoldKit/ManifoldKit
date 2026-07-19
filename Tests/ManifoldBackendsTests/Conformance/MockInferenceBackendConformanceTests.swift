import XCTest
import ManifoldInference
import ManifoldBackendTestKit
import ManifoldTestSupport
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS
import ManifoldCloudCore

/// Exercises the `BackendContractChecks` harness against `MockInferenceBackend`,
/// the canary backend used by the rest of the runtime tests. If the meta-contract
/// or per-capability families are broken, this fails first — well before any
/// real backend's conformance suite would.
///
/// Three classes of test:
///
/// 1. **Universal invariants** — `assertAllInvariants` on a default mock.
/// 2. **False-claim families** — `assertGrammarFailClosedContract` against a
///    mock with `supportsGrammarConstrainedSampling=false` (the default).
/// 3. **Meta-contract** — verifies that the registry correctly reports
///    "unproven" claims when a flag is declared `true` but no assertion
///    family has been called for it, and that explicit
///    `claimWithoutBehaviouralAssertion(...)` records do clear the unproven
///    bit. Acts as a self-test of the meta-contract bookkeeping itself.
@MainActor
final class MockInferenceBackendConformanceTests: XCTestCase,
                                                 BackendContractMixin,
                                                 GrammarFailClosedContractMixin {

    private let backendName = "MockInferenceBackend"
    let contractBackendName = "MockInferenceBackend"

    // Instance-scoped: XCTest instantiates a fresh MockInferenceBackendConformanceTests
    // per test method, so this registry starts empty for every method invocation with
    // no explicit reset needed between tests. See BackendContractChecks.ClaimRegistry.
    let capabilityClaimRegistry = BackendContractChecks.ClaimRegistry()

    func makeContractBackend() -> MockInferenceBackend {
        MockInferenceBackend()
    }

    // MARK: - Universal invariants

    func test_universalInvariants_allPass() {
        assertUniversalBackendContract()
    }

    // MARK: - False-claim family: grammar fail-closed

    /// Sabotage-evidence:
    ///   M1: in `MockInferenceBackend.generate`, comment out the
    ///       `if !capabilities.supportsGrammarConstrainedSampling, config.grammar != nil {
    ///         throw … }` block; this test fails because generate() returns a
    ///       stream instead of throwing.
    ///   M2: change the OOD grammar literal `"root ::= \"§NONCE§…\""` to `""`;
    ///       the assertion cited below still requires a non-nil grammar — empty
    ///       string is non-nil in Swift, so this M2 is intentionally a sanity
    ///       check that any non-nil value triggers the fail-closed path.
    ///   M3: flip `supportsGrammarConstrainedSampling` to `true` on the mock
    ///       capabilities; the early-return inside the assertion family fires
    ///       and the test correctly skips the throw assertion (claim is
    ///       still recorded, so meta-contract still satisfied).
    @MainActor
    func test_grammarFailClosed_throwsUnsupportedGrammar() async throws {
        try await assertGrammarFailClosedContract()
        // Claim recorded.
        XCTAssertTrue(
            BackendContractChecks.capturedClaims(capabilityClaimRegistry).contains("\(backendName)::supportsGrammarConstrainedSampling"),
            "assertGrammarFailClosedContract must record the capability claim"
        )
    }

    // MARK: - History threads through per-call hints (#2312)

    /// History no longer installs on backend instance state via a
    /// set-then-use receiver protocol — it arrives per-call on
    /// `GenerationRuntimeHints.history` and is consumed inside `generate(...)`.
    /// This proves the mock observes it there, and that a second call with
    /// different history fully replaces the first (no stale carryover from
    /// shared instance state, which was the #2312 cross-client leak hazard).
    @MainActor
    func test_threadsHistoryThroughHints() async throws {
        let backend = MockInferenceBackend()
        try await backend.loadModel(from: URL(fileURLWithPath: "/tmp/mock"), plan: ModelLoadPlan.testStub(effectiveContextSize: 4096))
        let history = [
            StructuredMessage(role: "user", parts: [.text("Question")]),
            StructuredMessage(role: "assistant", parts: [.thinking("Reasoning", signature: "sig-1"), .text("Answer")]),
        ]
        _ = try backend.generate(prompt: "next", systemPrompt: nil, config: GenerationConfig(), hints: GenerationRuntimeHints(history: history))
        XCTAssertEqual(backend.lastReceivedStructuredHistory, history)
        // No stale carryover: a second call with different history replaces it.
        let replacement = [StructuredMessage(role: "tool", parts: [.text("{\"ok\":true}")])]
        _ = try backend.generate(prompt: "again", systemPrompt: nil, config: GenerationConfig(), hints: GenerationRuntimeHints(history: replacement))
        XCTAssertEqual(backend.lastReceivedStructuredHistory, replacement)
    }

    // MARK: - Meta-contract self-tests

    /// Default mock has no declared-true tracked flags → meta-contract passes
    /// trivially with zero claims.
    func test_metaContract_defaultMockHasNoTrackedTrueFlags() {
        let caps = MockInferenceBackend().capabilities
        let unproven = BackendContractChecks.unprovenClaims(
            capabilityClaimRegistry,
            backendName: backendName,
            capabilities: caps
        )
        XCTAssertEqual(unproven, [], "default mock declares no tracked flags as true")
    }

    /// Sabotage-evidence:
    ///   M1: in `BackendContractChecks.unprovenClaims`, change the
    ///       `if !claimSet.contains(...)` condition to `if false`; this test
    ///       fails because `unproven` is empty (the meta-contract incorrectly
    ///       passes when claims are missing).
    ///   M2: change the seeded flag from `supportsToolCalling` to `supportsVision`;
    ///       the assertion below would still report 1 unproven, but the
    ///       *value* differs from the expected literal.
    ///   M3: not capability-gated.
    func test_metaContract_declaredTrueWithoutClaim_isReportedUnproven() {
        let caps = BackendCapabilities(
            supportsToolCalling: true  // declared true, no claim recorded
        )
        let unproven = BackendContractChecks.unprovenClaims(
            capabilityClaimRegistry,
            backendName: backendName,
            capabilities: caps
        )
        XCTAssertEqual(unproven, ["supportsToolCalling"],
                       "a declared-true tracked flag with no recorded claim must surface as unproven")
    }

    /// Recording a claim via the bootstrap helper clears the unproven bit.
    /// This is the seam that lets per-backend conformance tests pass before
    /// every assertion family has been implemented — the claim records the
    /// intent to assert; subsequent PRs replace the helper call with a real
    /// behavioural family.
    func test_metaContract_claimWithoutBehaviouralAssertion_clearsUnproven() {
        let caps = BackendCapabilities(supportsToolCalling: true)
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: backendName,
            flag: "supportsToolCalling"
        )
        let unproven = BackendContractChecks.unprovenClaims(
            capabilityClaimRegistry,
            backendName: backendName,
            capabilities: caps
        )
        XCTAssertEqual(unproven, [],
                       "an explicitly recorded claim must satisfy the meta-contract for that flag")
    }

    /// Two declared-true flags, only one claim — the other surfaces.
    /// Confirms the meta-contract isn't a single-flag check that would pass
    /// once any flag is claimed.
    func test_metaContract_multipleFlags_partialClaim_surfacesUnclaimedOnly() {
        let caps = BackendCapabilities(
            supportsToolCalling: true,
            supportsStructuredOutput: true
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: backendName,
            flag: "supportsToolCalling"
        )
        let unproven = BackendContractChecks.unprovenClaims(
            capabilityClaimRegistry,
            backendName: backendName,
            capabilities: caps
        )
        XCTAssertEqual(unproven, ["supportsStructuredOutput"],
                       "only flags without a recorded claim surface; the claimed one is satisfied")
    }

    /// Untracked flags (e.g. `isRemote`) declared `true` are NOT reported as
    /// unproven — the meta-contract intentionally exempts them.
    func test_metaContract_untrackedFlag_neverSurfaces() {
        let caps = BackendCapabilities(isRemote: true)
        let unproven = BackendContractChecks.unprovenClaims(
            capabilityClaimRegistry,
            backendName: backendName,
            capabilities: caps
        )
        XCTAssertEqual(unproven, [],
                       "isRemote is a static label, not a tracked behavioural capability — must not surface")
    }

    /// `assertCapabilityMetaContract` itself must succeed when the registry
    /// is correctly populated.
    func test_metaContract_assertSucceedsWhenAllClaimed() {
        let caps = BackendCapabilities(supportsToolCalling: true)
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: backendName,
            flag: "supportsToolCalling"
        )
        BackendContractChecks.assertCapabilityMetaContract(
            capabilityClaimRegistry,
            backendName: backendName,
            capabilities: caps
        )
    }
}
