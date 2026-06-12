import XCTest
import ManifoldInference
import ManifoldTestSupport
import ManifoldBackendTestKit

/// Local-backend contract suite — mock participant + universal cancellation
/// invariant.
///
/// The scenario implementations live in
/// ``ManifoldBackendTestKit/LocalBackendContractRunner`` so each backend
/// package runs the same checks: the MLX and Llama participants live in
/// `MLXLocalBackendContractTests` / `LlamaLocalBackendContractTests` (which
/// move to manifold-mlx / manifold-llama with their backends, #1749); the
/// Foundation participant lives in `FoundationLocalBackendContractTests`.
/// This file keeps the participants that stay in core: the scripted mock and
/// the backend-agnostic cooperative-cancellation invariant.
final class LocalBackendContractTests: XCTestCase {

    /// MockInferenceBackend participant.
    ///
    /// Scripted to yield `["Hello", " ", "world"]`, matching
    /// `Tests/Fixtures/backends/mock/streaming/simple-prompt/expected.jsonl`.
    private static let mockParticipant = LocalBackendContractParticipant(
        label: "mock",
        fixtureDirectory: "mock",
        capabilities: BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            supportsStreaming: true,
            isRemote: false
        ),
        requiresSlowTests: false,
        makeBackend: {
            let backend = MockInferenceBackend()
            // MockInferenceBackend.loadModel only throws when shouldThrowOnLoad
            // is set; the default factory never sets it, so this is safe to
            // ignore via a do/catch rather than try?.
            do {
                try await backend.loadModel(
                    from: URL(string: "unused:")!,
                    plan: .testStub(effectiveContextSize: 512)
                )
            } catch {
                // No-op: default MockInferenceBackend never throws on load.
            }
            backend.tokensToYield = ["Hello", " ", "world"]
            return backend
        }
    )

    // MARK: - Scenarios

    func test_generate_simplePrompt_emitsTokensInOrder() async throws {
        try await LocalBackendContractRunner.assertSimplePromptEmitsTokensInOrder(
            participant: Self.mockParticipant,
            fixturesRoot: LocalBackendContractRunner.locateFixturesRoot()
        )
    }

    func test_generate_stopsGenerating_afterStreamEnd() async throws {
        try await LocalBackendContractRunner.assertStopsGeneratingAfterStreamEnd(
            participant: Self.mockParticipant
        )
    }

    func test_capabilityGate_disclaimedRequirementThrows() async {
        await LocalBackendContractRunner.assertCapabilityGateDisclaimedRequirementThrows(
            participant: Self.mockParticipant
        )
    }

    /// Cancelling the stream mid-way halts emission within a bounded deadline.
    ///
    /// Uses ``SlowMockBackend`` directly (not participant fixture path) because
    /// this is a universal invariant about cooperative cancellation — it does
    /// not depend on fixture content. The slow backend delays 5 seconds per
    /// token; a 20-token stream would run for ~100s without cancellation.
    /// We cancel early and verify fewer than 20 tokens were seen, proving the
    /// stream stopped rather than exhausted.
    func test_generate_cancelMidStream_haltsBelowBudget() async throws {
        // A slow backend: 20 tokens at 5s per token = ~100s without cancellation.
        let backend = SlowMockBackend(tokenCount: 20, delayMilliseconds: 5_000)

        let stream = try backend.generate(
            prompt: "count",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        // Collect tokens in a child Task whose return value is read after
        // cancellation, avoiding the Swift 6 data-race on a mutable captured
        // variable shared between the outer function and the Task closure.
        let drainTask = Task<Int, Error> {
            var count = 0
            for try await event in stream.events {
                if case .token = event {
                    count += 1
                }
            }
            return count
        }

        // Yield briefly so the stream emission task starts.
        try await Task.sleep(for: .milliseconds(50))

        // Cancel via the drain task rather than stopGeneration() because this
        // tests cooperative cancellation (Task.isCancelled checks in the backend).
        drainTask.cancel()

        // Wait for cancellation to propagate. The 200ms window is generous
        // given that SlowMockBackend checks Task.isCancelled before each token.
        try await Task.sleep(for: .milliseconds(200))

        // The task was cancelled; its result is either the count at
        // cancellation time or a CancellationError. Both prove that not all
        // 20 tokens were consumed.
        let tokensSeen: Int
        do {
            tokensSeen = try await drainTask.value
        } catch is CancellationError {
            tokensSeen = 0
        }

        XCTAssertLessThan(
            tokensSeen,
            20,
            "cancel mid-stream must halt emission before all 20 tokens are yielded"
        )
    }
}
