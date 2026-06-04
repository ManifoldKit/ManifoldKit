import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldBackends

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
                                                 GrammarFailClosedContractMixin,
                                                 ConversationHistoryReceiverContractMixin,
                                                 StructuredHistoryReceiverContractMixin {

    private let backendName = "MockInferenceBackend"
    let contractBackendName = "MockInferenceBackend"

    func makeContractBackend() -> MockInferenceBackend {
        MockInferenceBackend()
    }

    override func setUp() {
        super.setUp()
        // Critical: clear this backend's registry entries between tests so that
        // per-capability claims recorded by an earlier test don't bleed into the
        // current one and confuse the meta-contract. Scoped to "MockInferenceBackend"
        // so concurrent backend classes under --parallel don't erase each other's
        // in-flight claims.
        BackendContractChecks.resetCapabilityClaims(forBackend: "MockInferenceBackend")
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
            BackendContractChecks.capturedClaims().contains("\(backendName)::supportsGrammarConstrainedSampling"),
            "assertGrammarFailClosedContract must record the capability claim"
        )
    }

    // MARK: - Opt-in protocol contracts

    func test_conversationHistoryReceiverContract_replacesHistory() {
        assertConversationHistoryReceiverContract(readHistory: \.lastReceivedHistory)
    }

    func test_structuredHistoryReceiverContract_replacesHistory() {
        assertStructuredHistoryReceiverContract(readHistory: \.lastReceivedStructuredHistory)
    }

    // MARK: - Meta-contract self-tests

    /// Default mock has no declared-true tracked flags → meta-contract passes
    /// trivially with zero claims.
    func test_metaContract_defaultMockHasNoTrackedTrueFlags() {
        let caps = MockInferenceBackend().capabilities
        let unproven = BackendContractChecks.unprovenClaims(
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
            backendName: backendName,
            flag: "supportsToolCalling"
        )
        let unproven = BackendContractChecks.unprovenClaims(
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
            backendName: backendName,
            flag: "supportsToolCalling"
        )
        let unproven = BackendContractChecks.unprovenClaims(
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
            backendName: backendName,
            flag: "supportsToolCalling"
        )
        BackendContractChecks.assertCapabilityMetaContract(
            backendName: backendName,
            capabilities: caps
        )
    }
}
