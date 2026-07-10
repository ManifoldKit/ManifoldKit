import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Regression tests for issue #689: topK, minP, presencePenalty, frequencyPenalty,
/// and seed must flow from `InferenceService.enqueue(messages:...)` all the way
/// through `GenerationQueue` and into `GenerationConfig` as seen by the backend.
@MainActor
final class EnqueueAdvancedSamplerParamTests: XCTestCase {

    // MARK: - Helpers

    private func makeService() -> (InferenceService, MockInferenceBackend) {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["ok"]
        let service = InferenceService(backend: backend, name: "Mock")
        return (service, backend)
    }

    // MARK: - topK

    func test_enqueue_topK_propagatesToBackendConfig() async throws {
        let (service, backend) = makeService()
        let (_, stream) = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig(topK: 40))
        for try await _ in stream.events {}
        XCTAssertEqual(backend.lastConfig?.topK, 40,
                       "topK passed to enqueue must reach GenerationConfig.topK")
    }

    func test_enqueue_topK_nilByDefault() async throws {
        let (service, backend) = makeService()
        let (_, stream) = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig())
        for try await _ in stream.events {}
        XCTAssertNil(backend.lastConfig?.topK,
                     "topK must default to nil so backends apply their own default")
    }

    // MARK: - minP

    func test_enqueue_minP_propagatesToBackendConfig() async throws {
        let (service, backend) = makeService()
        let (_, stream) = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig(minP: 0.05))
        for try await _ in stream.events {}
        XCTAssertEqual(backend.lastConfig?.minP ?? 0, 0.05, accuracy: 1e-6,
                       "minP passed to enqueue must reach GenerationConfig.minP")
    }

    func test_enqueue_minP_nilByDefault() async throws {
        let (service, backend) = makeService()
        let (_, stream) = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig())
        for try await _ in stream.events {}
        XCTAssertNil(backend.lastConfig?.minP,
                     "minP must default to nil so backends apply their own default")
    }

    // MARK: - presencePenalty

    func test_enqueue_presencePenalty_propagatesToBackendConfig() async throws {
        let (service, backend) = makeService()
        let (_, stream) = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig(presencePenalty: 0.6))
        for try await _ in stream.events {}
        XCTAssertEqual(backend.lastConfig?.presencePenalty ?? 0, 0.6, accuracy: 1e-6,
                       "presencePenalty passed to enqueue must reach GenerationConfig.presencePenalty")
    }

    func test_enqueue_presencePenalty_nilByDefault() async throws {
        let (service, backend) = makeService()
        let (_, stream) = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig())
        for try await _ in stream.events {}
        XCTAssertNil(backend.lastConfig?.presencePenalty,
                     "presencePenalty must default to nil")
    }

    // MARK: - frequencyPenalty

    func test_enqueue_frequencyPenalty_propagatesToBackendConfig() async throws {
        let (service, backend) = makeService()
        let (_, stream) = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig(frequencyPenalty: 0.3))
        for try await _ in stream.events {}
        XCTAssertEqual(backend.lastConfig?.frequencyPenalty ?? 0, 0.3, accuracy: 1e-6,
                       "frequencyPenalty passed to enqueue must reach GenerationConfig.frequencyPenalty")
    }

    func test_enqueue_frequencyPenalty_nilByDefault() async throws {
        let (service, backend) = makeService()
        let (_, stream) = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig())
        for try await _ in stream.events {}
        XCTAssertNil(backend.lastConfig?.frequencyPenalty,
                     "frequencyPenalty must default to nil")
    }

    // MARK: - seed

    func test_enqueue_seed_propagatesToBackendConfig() async throws {
        let (service, backend) = makeService()
        let (_, stream) = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig(seed: 42))
        for try await _ in stream.events {}
        XCTAssertEqual(backend.lastConfig?.seed, 42,
                       "seed passed to enqueue must reach GenerationConfig.seed")
    }

    func test_enqueue_seed_nilByDefault() async throws {
        let (service, backend) = makeService()
        let (_, stream) = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig())
        for try await _ in stream.events {}
        XCTAssertNil(backend.lastConfig?.seed,
                     "seed must default to nil so backends use random sampling")
    }

    // MARK: - All params together

    func test_enqueue_allAdvancedParams_propagateToBackendConfig() async throws {
        let (service, backend) = makeService()
        let (_, stream) = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig(topK: 50, minP: 0.1, presencePenalty: 0.5, frequencyPenalty: 0.2, seed: 12345))
        for try await _ in stream.events {}

        let config = try XCTUnwrap(backend.lastConfig,
                                    "backend must receive a GenerationConfig")
        XCTAssertEqual(config.topK, 50)
        XCTAssertEqual(config.minP ?? 0, 0.1, accuracy: 1e-6)
        XCTAssertEqual(config.presencePenalty ?? 0, 0.5, accuracy: 1e-6)
        XCTAssertEqual(config.frequencyPenalty ?? 0, 0.2, accuracy: 1e-6)
        XCTAssertEqual(config.seed, 12345)
    }

    // MARK: - Nil fields do not disturb existing params

    func test_enqueue_nilFields_doNotAffectTemperatureOrTopP() async throws {
        let (service, backend) = makeService()
        let (_, stream) = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig(temperature: 0.8, topP: 0.95))
        for try await _ in stream.events {}

        let config = try XCTUnwrap(backend.lastConfig)
        XCTAssertEqual(Double(config.temperature), 0.8, accuracy: 1e-6)
        XCTAssertEqual(Double(config.topP), 0.95, accuracy: 1e-6)
        XCTAssertNil(config.topK)
        XCTAssertNil(config.minP)
        XCTAssertNil(config.presencePenalty)
        XCTAssertNil(config.frequencyPenalty)
        XCTAssertNil(config.seed)
    }
}
