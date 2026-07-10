import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

@MainActor
final class EnqueueGrammarPropagationTests: XCTestCase {

    func test_enqueue_withGrammar_forwardsToBackendConfig() async throws {
        // The mock enforces the BackendCapabilities contract: it throws
        // unsupportedGrammar when supportsGrammarConstrainedSampling is false
        // and a non-nil grammar is passed (T1.1 meta-contract). To test grammar
        // propagation here, we configure a mock that declares the capability.
        let backend = MockInferenceBackend(capabilities: BackendCapabilities(
            supportsGrammarConstrainedSampling: true
        ))
        backend.isModelLoaded = true
        backend.tokensToYield = ["x"]
        let service = InferenceService(backend: backend, name: "Mock")

        let grammar = "root ::= \"x\""
        let (_, stream) = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig(grammar: grammar))

        for try await _ in stream.events {}

        XCTAssertEqual(
            backend.lastConfig?.grammar,
            grammar,
            "grammar passed to enqueue must reach the backend via GenerationConfig.grammar"
        )
    }
}
