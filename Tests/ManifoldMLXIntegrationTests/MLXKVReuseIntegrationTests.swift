#if MLX
import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldMLX

/// Real-MLX measurement of KV-cache prefix reuse across two consecutive turns.
///
/// Companion to ``MLXKVPersistenceIntegrationTests`` but focused narrowly on
/// the audit's open question: with `enableKVCacheReuse: true`, does a second
/// turn that shares a prefix with the first reliably emit a
/// `.kvCacheReuse(promptTokensReused:)` event with `promptTokensReused > 0`?
/// And as a sabotage check, does the same flow with reuse disabled (the
/// default) emit no `.kvCacheReuse` events?
///
/// Hardware-gated like the rest of the suite. Run via
/// `scripts/test-mlx-integration.sh` so the `MLX_TEST_MODEL` env var reaches
/// the xctest runner — `xcodebuild test ...` in isolation does not propagate
/// shell env into the test process for SwiftPM-generated schemes.
@MainActor
final class MLXKVReuseIntegrationTests: XCTestCase {

    private var modelURL: URL!
    private var loadedBackends: [MLXBackend] = []

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "Requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.hasMetalDevice, "Requires Metal GPU")

        guard let mlxDir = HardwareRequirements.findMLXModelDirectory() else {
            throw XCTSkip(
                "Set MLX_TEST_MODEL to a local MLX model directory (or run via scripts/test-mlx-integration.sh)."
            )
        }
        try XCTSkipIf(
            MLXBackend.requiresVLMFactory(at: mlxDir),
            "KV-cache reuse is gated off for VLMs — see MLXVLMGateExperimentTests for that path."
        )
        modelURL = mlxDir
    }

    override func tearDown() async throws {
        for backend in loadedBackends.reversed() {
            backend.unloadModel()
        }
        loadedBackends.removeAll()
        modelURL = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// Two short prompts whose first tokens diverge — turn 1 establishes the
    /// shared prefix (system + first user message) so turn 2 can reuse it.
    private let firstUserPrompt = "Tell me about cats."
    private let secondUserPrompt = "Now tell me about dogs."

    /// Greedy decoding so reuse hits aren't masked by sampling jitter, and a
    /// short cap keeps the wall-clock cost low even on slower machines.
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

    // MARK: - Helpers

    private func loadBackend(enableReuse: Bool) async throws -> MLXBackend {
        let backend = MLXBackend(enableKVCacheReuse: enableReuse)
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 2048))
        loadedBackends.append(backend)
        return backend
    }

    private func runTurn(
        on backend: MLXBackend,
        prompt: String
    ) async throws -> [GenerationEvent] {
        let stream = try backend.generate(
            prompt: prompt,
            systemPrompt: nil,
            config: deterministicConfig
        )
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    private func collectAssistantText(from events: [GenerationEvent]) -> String {
        var text = ""
        for event in events {
            if case .token(let chunk) = event {
                text += chunk
            }
        }
        return text
    }

    private func reuseCount(in events: [GenerationEvent]) -> Int? {
        for event in events {
            if case .kvCacheReuse(let count) = event {
                return count
            }
        }
        return nil
    }

    /// Drives the canonical "shared prefix" two-turn flow used by both
    /// reuse-enabled and reuse-disabled tests. Turn 1 generates a reply, the
    /// reply is folded into the conversation history, then turn 2 sends a
    /// follow-up that reuses the same prefix.
    private func runTwoTurns(on backend: MLXBackend) async throws -> (turn1: [GenerationEvent], turn2: [GenerationEvent]) {
        backend.resetConversation()
        let turn1Events = try await runTurn(on: backend, prompt: firstUserPrompt)
        let turn1Text = collectAssistantText(from: turn1Events)
        XCTAssertFalse(
            turn1Text.isEmpty,
            "Turn 1 must produce a non-empty reply so the follow-up history is well-formed"
        )

        backend.setConversationHistory([
            ("user", firstUserPrompt),
            ("assistant", turn1Text),
            ("user", secondUserPrompt),
        ])

        let turn2Events = try await runTurn(on: backend, prompt: secondUserPrompt)
        return (turn1Events, turn2Events)
    }

    // MARK: - Tests

    func test_twoTurnsEmitKVReuseWhenEnabled() async throws {
        let backend = try await loadBackend(enableReuse: true)
        let (turn1Events, turn2Events) = try await runTwoTurns(on: backend)

        XCTAssertNil(
            reuseCount(in: turn1Events),
            "Turn 1 has no prior cache to reuse — .kvCacheReuse must not fire on the first turn"
        )

        let reused = try XCTUnwrap(
            reuseCount(in: turn2Events),
            "Turn 2 must emit .kvCacheReuse when enableKVCacheReuse is on (model: \(modelURL.lastPathComponent))"
        )
        XCTAssertGreaterThan(
            reused,
            0,
            "Turn 2 must reuse a non-zero prompt prefix when sharing tokenizer-identical history"
        )
    }

    func test_kvReuseDisabledByDefault() async throws {
        // Explicit `enableKVCacheReuse: false` — also matches the default
        // constructor's behaviour, asserted separately below.
        XCTAssertFalse(
            MLXBackend().enableKVCacheReuse,
            "Default MLXBackend() must keep KV-cache reuse off — it's an opt-in feature"
        )

        let backend = try await loadBackend(enableReuse: false)
        let (turn1Events, turn2Events) = try await runTwoTurns(on: backend)

        XCTAssertNil(
            reuseCount(in: turn1Events),
            "Turn 1 must not emit .kvCacheReuse with reuse disabled"
        )
        XCTAssertNil(
            reuseCount(in: turn2Events),
            "Turn 2 must not emit .kvCacheReuse with reuse disabled — confirms the opt-in nature of the feature"
        )
    }
}
#endif
