import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

@MainActor
final class EnqueueGrammarDefaultNilTests: XCTestCase {

    func test_enqueue_withoutGrammar_leavesConfigGrammarNil() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["x"]
        let service = InferenceService(backend: backend, name: "Mock")

        let (_, stream) = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig())

        for try await _ in stream.events {}

        let config = try XCTUnwrap(backend.lastConfig, "generate() was not called — stream may not have drained")
        XCTAssertNil(config.grammar)
    }
}
