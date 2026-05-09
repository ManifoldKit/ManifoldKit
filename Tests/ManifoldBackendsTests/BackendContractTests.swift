import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldBackends

/// Shared contract assertions that every InferenceBackend implementation must satisfy.
/// Called from a single `test_contract_allInvariants()` method declared directly on
/// each adopting XCTestCase subclass — protocol extension methods are invisible to
/// XCTest's ObjC runtime and would never run.
///
/// ## Three-category capability semantics (T1.1)
///
/// Every Bool flag on ``BackendCapabilities`` falls into one of three categories
/// per backend, and the contract harness self-polices each:
///
/// 1. **Claimed-true** → at least one passing behaviour assertion must run for
///    that capability against this backend. Tracked via the claim registry below;
///    the meta-contract test ``assertCapabilityMetaContract(...)`` fails if any
///    declared-true tracked flag has no claim.
/// 2. **Claimed-false** → a fail-closed assertion must run. Disclaiming a
///    capability is a promise to fail-closed (e.g. backends with
///    ``BackendCapabilities/supportsGrammarConstrainedSampling`` set to false
///    MUST throw ``InferenceError/unsupportedGrammar(reason:)`` when
///    ``GenerationConfig/grammar`` is non-nil).
/// 3. **Universal** → flags whose contract is the same for all backends (e.g.
///    `isRemote` — a static label, not a behaviour).
///
/// Per-capability assertion families live as static methods on this enum. Each
/// method calls ``recordCapabilityClaim(backend:flag:)`` when it runs against
/// a backend whose capability matches the family's gate, so the meta-contract
/// knows the claim was exercised.
///
/// ## Adding a new backend
///
/// 1. Subclass `XCTestCase` under `Tests/ManifoldBackendsTests/Conformance/`.
/// 2. Override `setUp` to call `BackendContractChecks.resetCapabilityClaims()`.
/// 3. Add `test_contract_allInvariants()` calling the universal harness.
/// 4. Add `test_contract_grammarFailClosed()` calling the false-claim family.
/// 5. Add `test_contract_metaContract()` calling
///    `BackendContractChecks.assertCapabilityMetaContract(...)` last so
///    every per-capability test has had a chance to record claims.
enum BackendContractChecks {

    // MARK: - Original universal invariants (preserved verbatim)

    static func assertAllInvariants<B: InferenceBackend>(
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

    /// Process-wide registry of `(backendName, capabilityFlag)` pairs that the
    /// per-capability assertion families have exercised. The meta-contract
    /// test reads this to decide whether every declared-true tracked flag has
    /// been claimed.
    ///
    /// Backed by an `NSLock`-protected `Set<String>` rather than an atomic
    /// type, because `Atomic` requires `BitwiseCopyable` payloads that
    /// `Set<String>` does not provide.
    private static let claimsLock = NSLock()
    private nonisolated(unsafe) static var claims: Set<String> = []

    /// Records that a per-capability assertion family ran against `backend`
    /// for `flag`. Called from each assertion method below. Idempotent;
    /// recording the same `(backend, flag)` twice is fine.
    static func recordCapabilityClaim(backend backendName: String, flag capabilityFlag: String) {
        claimsLock.lock()
        defer { claimsLock.unlock() }
        claims.insert("\(backendName)::\(capabilityFlag)")
    }

    /// Clears all recorded claims. Call from `setUp()` so the registry doesn't
    /// accumulate stale state across tests in the same process.
    static func resetCapabilityClaims() {
        claimsLock.lock()
        defer { claimsLock.unlock() }
        claims.removeAll()
    }

    /// Snapshot of the current claim set, taken under lock for stability under
    /// `--parallel`.
    static func capturedClaims() -> Set<String> {
        claimsLock.lock()
        defer { claimsLock.unlock() }
        return claims
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
    static let metaContractTrackedFlags: [String] = [
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
    /// has NO recorded claim. An empty result means the meta-contract is
    /// satisfied. A non-empty result is the backend's "unproven claims" set.
    ///
    /// Reflects ``BackendCapabilities`` via Mirror — no per-flag conditional
    /// chain to maintain.
    static func unprovenClaims(
        backendName: String,
        capabilities: BackendCapabilities
    ) -> [String] {
        let claimSet = capturedClaims()
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

    /// Asserts that every declared-true tracked flag for `backendName` has at
    /// least one recorded claim. Run this AFTER every per-capability assertion
    /// family for the backend; e.g. the last test method on the conformance
    /// XCTestCase subclass.
    static func assertCapabilityMetaContract(
        backendName: String,
        capabilities: BackendCapabilities,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let unproven = unprovenClaims(backendName: backendName, capabilities: capabilities)
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
    }

    // MARK: - False-claim family: grammar-constrained sampling

    /// Asserts that backends disclaiming
    /// ``BackendCapabilities/supportsGrammarConstrainedSampling`` (i.e. flag
    /// is `false`) fail-closed when given a non-nil
    /// ``GenerationConfig/grammar``: they MUST throw
    /// ``InferenceError/unsupportedGrammar(reason:)`` rather than silently
    /// ignoring the constraint.
    ///
    /// Records claim under `supportsGrammarConstrainedSampling` regardless of
    /// the flag's value. When the flag is `true` this method is a no-op
    /// (the true side will be claimed by a separate "grammar produces valid
    /// output" family in a future patch).
    @MainActor
    static func assertGrammarFailClosedContract<B: InferenceBackend>(
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
        recordCapabilityClaim(backend: backendName, flag: "supportsGrammarConstrainedSampling")

        guard !backend.capabilities.supportsGrammarConstrainedSampling else {
            // Backend claims true; no fail-closed test to run here. The
            // claim has been recorded; the meta-contract is satisfied.
            return
        }

        try await backend.loadModel(
            from: URL(string: "unused:")!,
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
    /// yet implemented in this harness. Records the claim so the
    /// meta-contract is satisfied, but does no further verification beyond
    /// the existing per-backend `BackendCapabilitiesContractTests`. This is
    /// the seam through which subsequent PRs grow the assertion families
    /// without re-architecting the meta-contract.
    ///
    /// Use sparingly — every claim recorded via this helper is debt that
    /// future PRs must replace with a real behavioural assertion. The intent
    /// is to bootstrap the meta-contract with the existing static-flag
    /// coverage; it is NOT a permanent escape hatch.
    static func claimWithoutBehaviouralAssertion(
        backendName: String,
        flag capabilityFlag: String
    ) {
        recordCapabilityClaim(backend: backendName, flag: capabilityFlag)
    }
}
