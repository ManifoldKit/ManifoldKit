import XCTest
import ManifoldInference

/// XCTest-visible mixins for opt-in backend protocol contracts.
///
/// Extension methods are intentionally assertion helpers rather than `test_…`
/// methods: XCTest does not discover protocol-extension tests. Adopting suites
/// call these helpers from concrete test methods so each backend explicitly opts
/// into the protocol contracts it supports.
/// All contract mixin protocols are `@MainActor`-isolated so that conforming
/// test classes (which are `@MainActor`) satisfy Swift 6's isolation boundary
/// checks without wrapping factory calls in extra closures.
@MainActor
public protocol BackendContractMixin: AnyObject {
    associatedtype BackendUnderContract: InferenceBackend

    var contractBackendName: String { get }
    func makeContractBackend() -> BackendUnderContract
}

extension BackendContractMixin where Self: XCTestCase {
    @MainActor
    public func assertUniversalBackendContract(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        BackendContractChecks.assertAllInvariants(
            makingBackend: makeContractBackend,
            file: file,
            line: line
        )
    }
}

public protocol GrammarFailClosedContractMixin: BackendContractMixin {
    /// Instance-scoped capability-claims registry owned by this test case.
    /// Declare as a stored property, e.g.
    /// `let capabilityClaimRegistry = BackendContractChecks.ClaimRegistry()`.
    /// See ``BackendContractChecks/ClaimRegistry``.
    var capabilityClaimRegistry: BackendContractChecks.ClaimRegistry { get }
}

extension GrammarFailClosedContractMixin where Self: XCTestCase {
    @MainActor
    public func assertGrammarFailClosedContract(
        forbiddenRequestURL: URL? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await BackendContractChecks.assertGrammarFailClosedContract(
            capabilityClaimRegistry,
            backendName: contractBackendName,
            makingBackend: makeContractBackend,
            forbiddenRequestURL: forbiddenRequestURL,
            file: file,
            line: line
        )
    }
}

