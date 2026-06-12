#if MLX
import XCTest
import ManifoldInference
import ManifoldTestSupport
import ManifoldBackends
@_spi(Testing) import ManifoldMLX

/// Real-MLX exercise of type-aware, per-layer prompt-cache reuse on a **hybrid
/// architecture** (mixed cache types across layers — e.g. a Qwen3-Next-style
/// model that combines full-attention layers with recurrent / sliding-window
/// layers). See issue #1597.
///
/// This is the live counterpart to the Metal-free unit coverage in
/// `MLXPromptCacheCoordinatorTests`. It is gated on a **dedicated** discovery
/// variable, `MLX_HYBRID_TEST_MODEL`, rather than the generic `MLX_TEST_MODEL`
/// used by the rest of the integration suite: the homogeneous KVCacheSimple
/// models most machines have on disk would not actually exercise the hybrid
/// path. When no hybrid model is configured the whole suite skips cleanly — it
/// never fakes a pass.
///
/// Run (Xcode / Metal) via:
/// ```
/// MLX_HYBRID_TEST_MODEL=/path/to/qwen3-next-mlx scripts/test-mlx-integration.sh
/// ```
///
/// What it asserts:
/// - Two consecutive shared-prefix turns complete without crashing (the old
///   homogeneity gate turned reuse OFF for these models; the per-layer path must
///   not destabilise them).
/// - Whatever `.kvCacheReuse` the warm turn emits carries a non-negative count —
///   either a real prefix reuse (when every layer is reducible to the byte-exact
///   prefix) or no event at all (graceful degradation with a logged reason). It
///   must never reuse a wrong/negative amount.
@MainActor
final class MLXHybridCacheReuseIntegrationTests: XCTestCase {

    private var modelURL: URL!
    private var loadedBackends: [MLXBackend] = []

    private let firstUserPrompt = "Tell me about cats."
    private let secondUserPrompt = "Now tell me about dogs."

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "Requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.hasMetalDevice, "Requires Metal GPU")

        // Dedicated hybrid selector — a generic MLX_TEST_MODEL is almost always
        // a homogeneous attention model and would not cover the hybrid path.
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["MLX_HYBRID_TEST_MODEL"], !raw.isEmpty else {
            throw XCTSkip(
                "Set MLX_HYBRID_TEST_MODEL to a local recurrent+attention hybrid MLX model "
                + "(e.g. a Qwen3-Next checkpoint) to exercise per-layer hybrid cache reuse."
            )
        }
        guard let url = HardwareRequirements.findMLXModelDirectory(
            environment: ["MLX_TEST_MODEL": raw]
        ) else {
            throw XCTSkip("MLX_HYBRID_TEST_MODEL did not resolve to a valid MLX model directory: \(raw)")
        }
        try XCTSkipIf(
            MLXModelProbe.requiresVLMFactory(at: url),
            "KV-cache reuse is gated off for VLMs — not a hybrid-cache scenario."
        )
        modelURL = url
    }

    override func tearDown() async throws {
        for backend in loadedBackends.reversed() {
            backend.unloadModel()
        }
        loadedBackends.removeAll()
        modelURL = nil
        try await super.tearDown()
    }

    private var deterministicConfig: GenerationConfig {
        GenerationConfig(
            temperature: 0.0,
            topP: 1.0,
            repeatPenalty: 1.0,
            seed: 749,
            maxOutputTokens: 16,
            maxThinkingTokens: 0
        )
    }

    private func runTurn(on backend: MLXBackend, prompt: String) async throws -> [GenerationEvent] {
        let stream = try backend.generate(prompt: prompt, systemPrompt: nil, config: deterministicConfig)
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }
        return events
    }

    private func assistantText(_ events: [GenerationEvent]) -> String {
        events.reduce(into: "") { acc, event in
            if case .token(let chunk) = event { acc += chunk }
        }
    }

    private func reuseCount(_ events: [GenerationEvent]) -> Int? {
        for event in events {
            if case .kvCacheReuse(let count) = event { return count }
        }
        return nil
    }

    func test_hybridModel_twoSharedPrefixTurns_reuseOrDegradeSafely() async throws {
        let backend = MLXBackend(enableKVCacheReuse: true)
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 2048))
        loadedBackends.append(backend)

        backend.resetConversation()
        let turn1 = try await runTurn(on: backend, prompt: firstUserPrompt)
        let turn1Text = assistantText(turn1)
        XCTAssertFalse(turn1Text.isEmpty, "Turn 1 must produce a reply on the hybrid model")
        XCTAssertNil(reuseCount(turn1), "Turn 1 has no prior cache — .kvCacheReuse must not fire")

        backend.setConversationHistory([
            ("user", firstUserPrompt),
            ("assistant", turn1Text),
            ("user", secondUserPrompt),
        ])
        let turn2 = try await runTurn(on: backend, prompt: secondUserPrompt)

        // The model is a hybrid: depending on its exact layer composition the
        // warm turn either reuses a real prefix (every layer reducible to the
        // byte-exact common prefix) or degrades to a full prefill with a logged
        // reason. Both are correct; an unsafe/negative reuse is not.
        if let reused = reuseCount(turn2) {
            XCTAssertGreaterThan(
                reused, 0,
                "A hybrid reuse hit must restore a non-zero, byte-exact prefix (model: \(modelURL.lastPathComponent))"
            )
        }
        XCTAssertFalse(
            assistantText(turn2).isEmpty,
            "Turn 2 must still produce a coherent reply whether or not the cache was reused"
        )
    }
}
#endif
