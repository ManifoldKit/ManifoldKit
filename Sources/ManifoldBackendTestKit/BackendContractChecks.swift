import XCTest
import Foundation
import ManifoldInference
import ManifoldTestSupport

/// Shared contract assertions that every InferenceBackend implementation must satisfy.
/// Called from a single `test_contract_allInvariants()` method declared directly on
/// each adopting XCTestCase subclass — protocol extension methods are invisible to
/// XCTest's ObjC runtime and would never run.
///
/// Published as part of the ``ManifoldBackendTestKit`` product so companion
/// backend packages (manifold-mlx / manifold-llama) run the exact same
/// contract suite against core's published API. See the DocC catalog for the
/// adoption walkthrough and the non-vacuity expectation.
///
/// ## Three-category capability semantics (T1.1)
///
/// Every Bool flag on ``BackendCapabilities`` falls into one of three categories
/// per backend, and the contract harness self-polices each:
///
/// 1. **Claimed-true** → at least one passing behaviour assertion must run for
///    that capability against this backend. Tracked via the claim registry below;
///    the meta-contract test ``assertCapabilityMetaContract(_:backendName:capabilities:file:line:)``
///    fails if any declared-true tracked flag has no claim.
/// 2. **Claimed-false** → a fail-closed assertion must run. Disclaiming a
///    capability is a promise to fail-closed (e.g. backends with
///    ``BackendCapabilities/supportsGrammarConstrainedSampling`` set to false
///    MUST throw ``InferenceError/unsupportedGrammar(reason:)`` when
///    ``GenerationConfig/grammar`` is non-nil).
/// 3. **Universal** → flags whose contract is the same for all backends (e.g.
///    `isRemote` — a static label, not a behaviour).
///
/// Per-capability assertion families live as static methods on this enum. Each
/// method calls ``recordCapabilityClaim(_:backend:flag:)`` when it runs against
/// a backend whose capability matches the family's gate, so the meta-contract
/// knows the claim was exercised.
///
/// ## Adding a new backend
///
/// 1. Subclass `XCTestCase` in your backend package's test target.
/// 2. Declare one `let capabilityClaimRegistry = BackendContractChecks.ClaimRegistry()`
///    (or a per-mixin-required property — see ``BackendContractMixin``) owned by
///    the test case instance.
/// 3. Add `test_contract_allInvariants()` calling the universal harness.
/// 4. Add a single `test_contract_allCapabilityClaims()` that calls
///    `BackendContractChecks.resetCapabilityClaims(registry, forBackend:)` at the
///    top, then the fail-closed families (e.g. `assertGrammarFailClosedContract`)
///    and all `claimWithoutBehaviouralAssertion` calls, then
///    `assertCapabilityMetaContract(...)` — all in one method body, passing the
///    same `registry` instance throughout. The fail-closed families MUST run in
///    this method: ``assertCapabilityMetaContract(_:backendName:capabilities:file:line:)``
///    now requires a recorded claim for declared-false ``failClosedContractFlags``,
///    and XCTest gives each method a fresh instance-scoped registry, so a
///    fail-closed test in a separate method would be invisible to the assertion.
public enum BackendContractChecks {

    // MARK: - Original universal invariants (preserved verbatim)

    public static func assertAllInvariants<B: InferenceBackend>(
        makingBackend makeBackend: () -> B,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // 1. Not loaded on init
        XCTAssertFalse(makeBackend().isModelLoaded,
            "Backend must report isModelLoaded == false before loadModel is called",
            file: file, line: line)

        // 2. Not generating on init
        XCTAssertFalse(makeBackend().isGenerating,
            "Backend must report isGenerating == false before any generation",
            file: file, line: line)

        // 3. generate() before load must throw
        XCTAssertThrowsError(
            try makeBackend().generate(prompt: "hello", systemPrompt: nil, config: GenerationConfig()),
            "generate() must throw when called before loadModel()",
            file: file, line: line
        )

        // 4. Capabilities must advertise at least one parameter
        XCTAssertFalse(makeBackend().capabilities.supportedParameters.isEmpty,
            "Backend must advertise at least one supported generation parameter",
            file: file, line: line)

        // 5. unloadModel() is idempotent
        let b1 = makeBackend()
        b1.unloadModel()
        b1.unloadModel()  // second call must not crash

        // 6. stopGeneration() before load must not crash
        makeBackend().stopGeneration()
    }

    // MARK: - Capability claim registry

    /// Instance-scoped registry of `(backendName, capabilityFlag)` claim pairs
    /// that the per-capability assertion families have exercised. The
    /// meta-contract test reads a registry instance to decide whether every
    /// declared-true tracked flag has been claimed.
    ///
    /// Own **one instance per test case** — e.g. a `let capabilityClaimRegistry
    /// = BackendContractChecks.ClaimRegistry()` stored property on the adopting
    /// `XCTestCase` subclass — and thread it through every call in this file.
    /// XCTest instantiates a fresh instance of the test class per test method,
    /// so a registry stored this way starts empty for every method invocation
    /// with no cross-test or cross-class bleed. This replaced a process-global
    /// `nonisolated(unsafe) static var` (arch-plan item 4.2, #2038-adjacent)
    /// that made contract suites unsafe under `swift test --parallel` — the
    /// registry no longer needs a lock, and the whole fleet's ban on
    /// `--parallel` for these suites is lifted. See the DocC catalog.
    public final class ClaimRegistry {
        private var claims: Set<String> = []

        public init() {}

        func insert(_ key: String) {
            claims.insert(key)
        }

        func removeAll(matchingPrefix prefix: String) {
            claims = claims.filter { !$0.hasPrefix(prefix) }
        }

        var all: Set<String> { claims }
    }

    /// Records that a per-capability assertion family ran against `backend`
    /// for `flag` in `registry`. Called from each assertion method below.
    /// Idempotent; recording the same `(backend, flag)` twice is fine.
    public static func recordCapabilityClaim(
        _ registry: ClaimRegistry,
        backend backendName: String,
        flag capabilityFlag: String
    ) {
        registry.insert("\(backendName)::\(capabilityFlag)")
    }

    /// Clears `registry`'s recorded claims for a specific backend. Call at the
    /// top of `test_contract_allCapabilityClaims()` — harmless (and normally a
    /// no-op given a freshly-constructed `registry`), kept for symmetry and for
    /// suites that build up several scenarios against one long-lived registry
    /// within a single test method.
    public static func resetCapabilityClaims(_ registry: ClaimRegistry, forBackend backendName: String) {
        registry.removeAll(matchingPrefix: "\(backendName)::")
    }

    /// Snapshot of `registry`'s current claim set.
    public static func capturedClaims(_ registry: ClaimRegistry) -> Set<String> {
        registry.all
    }

    // MARK: - Meta-contract: tracked flags + unproven detection

    /// Boolean capability flags the meta-contract requires evidence for.
    ///
    /// Entries here represent **behaviours** the consumer is allowed to gate
    /// UI / runtime logic on. A backend declaring one of these `true` must
    /// have at least one assertion family that proves it.
    ///
    /// Flags NOT in this list are intentionally exempted:
    /// - `isRemote` — a static label about the network boundary, not behaviour.
    /// - `requiresPromptTemplate` — a request-shape contract, asserted by the
    ///    runtime's `PromptAssembler` tests, not by per-backend conformance.
    /// - `supportsSystemPrompt`, `supportsStreaming` — covered by the
    ///   universal invariants and the existing per-backend cap tests.
    public static let metaContractTrackedFlags: [String] = [
        "supportsToolCalling",
        "supportsStructuredOutput",
        "supportsNativeJSONMode",
        "supportsKVCachePersistence",
        "supportsGrammarConstrainedSampling",
        "supportsThinking",
        "supportsVision",
        "streamsToolCallArguments",
        "supportsParallelToolCalls",
        "supportsGuidedStructuredOutput",
        "supportsTokenCounting"
    ]

    /// Returns the list of declared-true tracked flags for which `backendName`
    /// has NO recorded claim in `registry`. An empty result means the
    /// meta-contract is satisfied. A non-empty result is the backend's
    /// "unproven claims" set.
    ///
    /// Reflects ``BackendCapabilities`` via Mirror — no per-flag conditional
    /// chain to maintain.
    public static func unprovenClaims(
        _ registry: ClaimRegistry,
        backendName: String,
        capabilities: BackendCapabilities
    ) -> [String] {
        let claimSet = capturedClaims(registry)
        var unproven: [String] = []
        let mirror = Mirror(reflecting: capabilities)
        for child in mirror.children {
            guard let label = child.label,
                  metaContractTrackedFlags.contains(label),
                  let value = child.value as? Bool,
                  value == true
            else { continue }
            if !claimSet.contains("\(backendName)::\(label)") {
                unproven.append(label)
            }
        }
        return unproven.sorted()
    }

    /// Boolean capability flags that carry a **fail-closed contract** when
    /// declared `false`: the backend must actively reject the corresponding
    /// request rather than silently ignore it, and a behavioural assertion must
    /// prove it does.
    ///
    /// Unlike ``metaContractTrackedFlags`` — which requires a claim only when a
    /// flag is declared *true* — these require a registered claim when the flag
    /// is declared *false* too. A `false` declaration is itself a promise (fail
    /// closed), and an unproven `false` declaration is exactly how a backend can
    /// silently drop the constraint: FoundationBackend disclaimed
    /// `supportsGrammarConstrainedSampling` yet never read `config.grammar`, and
    /// because the old meta-contract only audited true flags, the missing
    /// fail-closed test passed `test_contract_allCapabilityClaims()` cleanly.
    public static let failClosedContractFlags: Set<String> = [
        "supportsGrammarConstrainedSampling"
    ]

    /// Returns the fail-closed-contract flags that `backendName` declares
    /// `false` but has NO recorded claim for in `registry`. An empty result
    /// means every fail-closed obligation has a behavioural assertion behind it.
    ///
    /// This is the false-side counterpart to ``unprovenClaims(_:backendName:capabilities:)``
    /// and the detection function the meta-contract runs; it is unit-tested
    /// directly (planted-violation style) in the harness self-tests.
    public static func unprovenFailClosedContracts(
        _ registry: ClaimRegistry,
        backendName: String,
        capabilities: BackendCapabilities
    ) -> [String] {
        let claimSet = capturedClaims(registry)
        var unproven: [String] = []
        let mirror = Mirror(reflecting: capabilities)
        for child in mirror.children {
            guard let label = child.label,
                  failClosedContractFlags.contains(label),
                  let value = child.value as? Bool,
                  value == false
            else { continue }
            if !claimSet.contains("\(backendName)::\(label)") {
                unproven.append(label)
            }
        }
        return unproven.sorted()
    }

    /// Asserts that every declared-true tracked flag AND every declared-false
    /// fail-closed-contract flag for `backendName` has at least one recorded
    /// claim in `registry`. Call this at the end of
    /// `test_contract_allCapabilityClaims()`, after all
    /// `claimWithoutBehaviouralAssertion` calls and the fail-closed assertion
    /// families (e.g. ``assertGrammarFailClosedContract(_:backendName:makingBackend:forbiddenRequestURL:file:line:)``)
    /// for the backend — all threaded through the same `registry` instance.
    public static func assertCapabilityMetaContract(
        _ registry: ClaimRegistry,
        backendName: String,
        capabilities: BackendCapabilities,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let unproven = unprovenClaims(registry, backendName: backendName, capabilities: capabilities)
        XCTAssertTrue(
            unproven.isEmpty,
            """
            Backend \(backendName) declares the following capability flags as `true`
            but no per-capability assertion claimed them: \(unproven).
            Either add an assertion that proves the capability (and registers a
            claim via BackendContractChecks.recordCapabilityClaim), or flip the
            declared flag to `false` and add a fail-closed assertion.
            """,
            file: file, line: line
        )

        let unprovenFailClosed = unprovenFailClosedContracts(
            registry, backendName: backendName, capabilities: capabilities
        )
        XCTAssertTrue(
            unprovenFailClosed.isEmpty,
            """
            Backend \(backendName) declares the following fail-closed-contract flags
            as `false` but no behavioural assertion claimed them: \(unprovenFailClosed).
            A `false` declaration is a promise to fail closed — e.g.
            supportsGrammarConstrainedSampling == false MUST throw
            InferenceError.unsupportedGrammar when GenerationConfig.grammar is non-nil.
            Run the matching fail-closed family (e.g. assertGrammarFailClosedContract)
            in this test so the claim is recorded through the same registry; without
            it a missing fail-closed test lets the backend silently drop the
            constraint (the FoundationBackend grammar gap, issue #2354-adjacent).
            """,
            file: file, line: line
        )
    }

    // MARK: - False-claim family: grammar-constrained sampling

    /// Asserts that backends disclaiming
    /// ``BackendCapabilities/supportsGrammarConstrainedSampling`` (i.e. flag
    /// is `false`) fail-closed when given a non-nil
    /// ``GenerationConfig/grammar``: they MUST throw
    /// ``InferenceError/unsupportedGrammar(reason:)`` rather than silently
    /// ignoring the constraint.
    ///
    /// Records claim under `supportsGrammarConstrainedSampling` in `registry`
    /// regardless of the flag's value. When the flag is `true` this method is
    /// a no-op (the true side will be claimed by a separate "grammar produces
    /// valid output" family in a future patch).
    @MainActor
    public static func assertGrammarFailClosedContract<B: InferenceBackend>(
        _ registry: ClaimRegistry,
        backendName: String,
        makingBackend makeBackend: () -> B,
        forbiddenRequestURL: URL? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let backend = makeBackend()
        // Always record the claim so the meta-contract sees it whether or
        // not the backend takes the false-side path. The same family proves
        // both shapes — true backends via "produces grammar-valid output"
        // (future) and false backends via "throws unsupportedGrammar" (here).
        recordCapabilityClaim(registry, backend: backendName, flag: "supportsGrammarConstrainedSampling")

        guard !backend.capabilities.supportsGrammarConstrainedSampling else {
            // Backend claims true; no fail-closed test to run here. The
            // claim has been recorded; the meta-contract is satisfied.
            return
        }

        try await backend.loadModel(
            from: URL(fileURLWithPath: "/dev/null"),
            plan: .testStub(effectiveContextSize: 512)
        )

        var cfg = GenerationConfig()
        cfg.grammar = "root ::= \"hello\""
        let capturedRequestsBefore = capturedRequestCount(for: forbiddenRequestURL)

        XCTAssertThrowsError(
            try backend.generate(prompt: "x", systemPrompt: nil, config: cfg),
            "Backend disclaiming supportsGrammarConstrainedSampling must throw when given a grammar",
            file: file, line: line
        ) { error in
            guard case .unsupportedGrammar = error as? InferenceError else {
                XCTFail(
                    "Expected InferenceError.unsupportedGrammar; got \(String(describing: error))",
                    file: file, line: line
                )
                return
            }
        }

        XCTAssertEqual(
            capturedRequestCount(for: forbiddenRequestURL),
            capturedRequestsBefore,
            "Backend must reject unsupported grammar before opening a network request",
            file: file,
            line: line
        )
    }

    private static func capturedRequestCount(for url: URL?) -> Int {
        guard let url else { return 0 }
        return MockURLProtocol.capturedRequests.filter { $0.url == url }.count
    }

    // MARK: - True-claim convenience: claim-and-skip helper

    /// Convenience helper for capabilities whose true-claim assertion is not
    /// yet implemented in this harness. Records the claim in `registry` so the
    /// meta-contract is satisfied, but does no further verification beyond
    /// the existing per-backend `BackendCapabilitiesContractTests`. This is
    /// the seam through which subsequent PRs grow the assertion families
    /// without re-architecting the meta-contract.
    ///
    /// Use sparingly — every claim recorded via this helper is debt that
    /// future PRs must replace with a real behavioural assertion. The intent
    /// is to bootstrap the meta-contract with the existing static-flag
    /// coverage; it is NOT a permanent escape hatch.
    public static func claimWithoutBehaviouralAssertion(
        _ registry: ClaimRegistry,
        backendName: String,
        flag capabilityFlag: String
    ) {
        recordCapabilityClaim(registry, backend: backendName, flag: capabilityFlag)
    }
}
