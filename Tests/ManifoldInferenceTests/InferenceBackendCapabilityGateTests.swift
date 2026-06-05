import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for ``InferenceBackend/generateEnforcingCapabilities(prompt:systemPrompt:config:)``
/// — the capability gate that the footgun audit promoted from a RouterBackend-only
/// check to the single-backend dispatch boundary (class A — "two paths, one guard").
///
/// Without it, a host that set ``GenerationConfig/requiredCapabilities`` and ran
/// against a single concrete backend had the constraint silently ignored: the
/// backend generated anyway, downgrading the request with no error.
final class InferenceBackendCapabilityGateTests: XCTestCase {

    private func minimalCaps() -> BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 2048,
            supportsToolCalling: false,
            supportsThinking: false
        )
    }

    private func toolCapableCaps() -> BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 8192,
            supportsToolCalling: true
        )
    }

    func test_throwsWhenBackendCannotSatisfyRequirement_withoutCallingGenerate() throws {
        let backend = MockInferenceBackend(capabilities: minimalCaps())
        backend.isModelLoaded = true
        let config = GenerationConfig(requiredCapabilities: [.toolCalling])

        XCTAssertThrowsError(
            try backend.generateEnforcingCapabilities(prompt: "hi", systemPrompt: nil, config: config)
        ) { error in
            guard case InferenceError.noBackendSatisfiesRequirements(let unmet) = error else {
                return XCTFail("Expected .noBackendSatisfiesRequirements, got \(error)")
            }
            XCTAssertEqual(unmet, [.toolCalling])
        }
        // The gate must fail fast BEFORE dispatching to the backend — a silently
        // downgraded generation is exactly the bug this closes.
        XCTAssertEqual(backend.generateCallCount, 0, "generate must not run when requirements are unmet")
    }

    func test_passesWhenBackendSatisfiesRequirement() throws {
        let backend = MockInferenceBackend(capabilities: toolCapableCaps())
        backend.isModelLoaded = true
        let config = GenerationConfig(requiredCapabilities: [.toolCalling])

        XCTAssertNoThrow(
            try backend.generateEnforcingCapabilities(prompt: "hi", systemPrompt: nil, config: config)
        )
        XCTAssertEqual(backend.generateCallCount, 1)
    }

    func test_emptyRequirements_isNoOp_andDispatches() throws {
        let backend = MockInferenceBackend(capabilities: minimalCaps())
        backend.isModelLoaded = true
        let config = GenerationConfig() // requiredCapabilities defaults empty

        XCTAssertNoThrow(
            try backend.generateEnforcingCapabilities(prompt: "hi", systemPrompt: nil, config: config)
        )
        XCTAssertEqual(backend.generateCallCount, 1, "the standard chat path must be unaffected")
    }

    func test_reportsAllUnmetRequirements_sortedDeterministically() throws {
        let backend = MockInferenceBackend(capabilities: minimalCaps())
        backend.isModelLoaded = true
        let config = GenerationConfig(requiredCapabilities: [.toolCalling, .thinking])

        XCTAssertThrowsError(
            try backend.generateEnforcingCapabilities(prompt: "hi", systemPrompt: nil, config: config)
        ) { error in
            guard case InferenceError.noBackendSatisfiesRequirements(let unmet) = error else {
                return XCTFail("Expected .noBackendSatisfiesRequirements, got \(error)")
            }
            // Both are unmet; order is deterministic (sortKey) so logs/diffs are stable.
            XCTAssertEqual(Set(unmet), [.toolCalling, .thinking])
            XCTAssertEqual(unmet, unmet.sorted { $0.sortKey < $1.sortKey })
        }
    }
}
