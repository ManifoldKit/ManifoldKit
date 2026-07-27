import XCTest
@testable import ManifoldFoundation
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
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

    // MARK: - Unknown context window resolves per-provider, not by sentinel

    /// `ClaudeBackend` used to detect "the table had no entry" by comparing the
    /// manifest's `contextWindow` against the literal `8192` that
    /// `ModelManifest.unknown()` fabricated in another module. With absence on
    /// the type it reads `?? 200_000` instead; this pins the resulting window.
    func test_claude_unknownModel_capabilitiesUseAnthropic200kFallback() {
        let backend = ClaudeBackend()
        backend.modelName = "claude-imaginary-9000"

        XCTAssertNil(backend.manifest?.contextWindow,
                     "An unrecognised Claude model must have no measured window")
        XCTAssertEqual(backend.capabilities.maxContextTokens, 200_000,
                       "Anthropic's mainstream baseline is the backend's own fallback for an unknown window")
    }

    /// A model the table *does* cover must keep its real window rather than
    /// being swept into the fallback.
    func test_claude_knownModel_capabilitiesUseTableWindow() {
        let backend = ClaudeBackend()
        backend.modelName = "claude-sonnet-4-7-20260101"

        XCTAssertEqual(backend.manifest?.contextWindow, 1_000_000)
        XCTAssertEqual(backend.capabilities.maxContextTokens, 1_000_000,
                       "A measured 1M window must reach capabilities untouched")
    }

    /// Forward regression pin, not a revert-detector: this passes on `main`
    /// too, because `gpt-4`'s table entry already carried a real 8,192 window.
    /// It exists so that reintroducing a `contextWindow == 8192` "is this
    /// unknown?" test anywhere in the resolution path goes red — the collision
    /// that shape cannot survive, since `gpt-4` genuinely *is* an 8k model.
    /// The revert-detector for the sentinel itself is
    /// `ModelManifestTests.test_genuine8kWindow_isDistinguishableFromUnknown`.
    func test_openAI_genuine8kModel_isNotMistakenForUnknown() {
        let backend = OpenAIBackend()
        backend.modelName = "gpt-4"

        XCTAssertEqual(backend.manifest?.contextWindow, 8192,
                       "gpt-4's real window is 8k — a measured value, not a sentinel")
        XCTAssertEqual(backend.capabilities.maxContextTokens, 8192,
                       "A genuine 8k model must NOT be inflated to the 128k unknown-model fallback")
    }

    /// …and the unknown case is resolved by a different path — the backend's
    /// own conservative constant — rather than by a shared magic number.
    ///
    /// The value matches `gpt-4`'s genuine window above *by coincidence*, which
    /// is precisely why the manifest-level assertions differ (`8192` vs `nil`):
    /// that is the distinction the old sentinel could not express.
    ///
    /// It also pins behaviour parity with pre-optional `main`. A table miss used
    /// to produce `unknown()`'s fabricated 8192, so `capabilities` reported 8k;
    /// letting the factory's unreachable `?? 128_000` fire instead would have
    /// silently raised an unrecognised model's budget 16×.
    func test_openAI_unknownModel_capabilitiesUseConservativeFallback() {
        let backend = OpenAIBackend()
        backend.modelName = "gpt-imaginary-9000"

        XCTAssertNil(backend.manifest?.contextWindow,
                     "A table miss must report no measured window")
        XCTAssertEqual(backend.capabilities.maxContextTokens,
                       Int32(OpenAIBackend.unknownModelContextWindow),
                       "An unrecognised model keeps the conservative budget it had before contextWindow became optional — this backend also serves small local LM Studio models")
    }

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
        XCTAssertNil(manifest.contextWindow,
                     "An unrecognised OpenAI model has an unknown window; OpenAIBackend applies the 128k fallback itself")
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
