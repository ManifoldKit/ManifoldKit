import XCTest
@testable import ManifoldBackends
@testable import ManifoldInference
import ManifoldTestSupport

/// Cross-backend invariants that ``ModelManifest`` must uphold.
///
/// The load-bearing rule: any backend whose configured model emits
/// ``GenerationEvent/thinkingToken(_:)`` events MUST also report
/// `manifest.supportsThinking == true`. Consumer UI gates the reasoning
/// disclosure group on the static capability flag — if the flag and the
/// stream lie to each other, reasoning content is silently dropped.
final class ModelManifestContractTests: XCTestCase {

    // MARK: - Cloud backends — supportsThinking matches the manifest table

    func test_claude_sonnet4_manifestReflectsThinking() throws {
        let backend = ClaudeBackend()
        backend.modelName = "claude-sonnet-4-5"
        let manifest = try XCTUnwrap(backend.manifest)
        XCTAssertEqual(manifest.supportsThinking, true,
                       "Claude Sonnet 4.x is a thinking model — manifest must reflect that")
        // The capability flag derives from the manifest in our wiring.
        XCTAssertTrue(backend.capabilities.supportsThinking,
                      "BackendCapabilities must surface the manifest's thinking flag")
    }

    func test_claude_3_5_sonnet_manifestDoesNotAdvertiseThinking() throws {
        let backend = ClaudeBackend()
        backend.modelName = "claude-3-5-sonnet-20241022"
        let manifest = try XCTUnwrap(backend.manifest)
        XCTAssertEqual(manifest.supportsThinking, false,
                       "Claude 3.5 Sonnet predates extended thinking")
        XCTAssertFalse(backend.capabilities.supportsThinking,
                       "BackendCapabilities must mirror the manifest")
    }

    func test_openAI_o1_manifestRejectsSeed() throws {
        let backend = OpenAIBackend()
        backend.modelName = "o1-mini"
        let manifest = try XCTUnwrap(backend.manifest)
        XCTAssertEqual(manifest.supportsSeed, false,
                       "o1-mini rejects seed — manifest must declare that so the wire layer omits it")
    }

    func test_openAI_gpt4o_manifestAcceptsSeed() throws {
        let backend = OpenAIBackend()
        backend.modelName = "gpt-4o"
        let manifest = try XCTUnwrap(backend.manifest)
        XCTAssertEqual(manifest.supportsSeed, true)
    }

    func test_openAI_unknownModel_returnsConservativeManifest() throws {
        let backend = OpenAIBackend()
        backend.modelName = "made-up-3000"
        let manifest = try XCTUnwrap(backend.manifest)
        XCTAssertEqual(manifest.contextWindow, 8192,
                       "Unknown OpenAI model must fall back to the 8k default")
        XCTAssertEqual(manifest.supportsSeed, false,
                       "Unknown OpenAI model must not advertise seed")
    }

    // MARK: - MockInferenceBackend — invariant scaffolding

    /// Demonstrates that callers using ``MockInferenceBackend`` to simulate
    /// a thinking-capable backend pair the capability flag and the stream:
    /// the test fails if a mock that yields `.thinkingToken` events forgets
    /// to set `supportsThinking: true` in its capabilities.
    func test_mockBackend_thinkingEventEmitter_reportsSupportsThinking() async throws {
        let caps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 8192,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsThinking: true
        )
        let mock = MockInferenceBackend(capabilities: caps)
        mock.thinkingTokensToYield = ["thought-A", "thought-B"]

        try await mock.loadModel(from: URL(fileURLWithPath: "/tmp/mock"), plan: .cloud())
        let stream = try mock.generate(prompt: "Hi", systemPrompt: nil, config: GenerationConfig())

        var sawThinking = false
        for try await event in stream.events {
            if case .thinkingToken = event { sawThinking = true }
        }
        XCTAssertTrue(sawThinking, "Mock yielded thinking tokens but the consumer never saw one")
        XCTAssertTrue(mock.capabilities.supportsThinking,
                      "Backends emitting .thinkingToken must report supportsThinking == true")
    }
}
