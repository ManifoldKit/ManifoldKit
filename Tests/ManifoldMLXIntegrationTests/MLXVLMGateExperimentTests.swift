#if MLX
import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldMLX

/// Confirms the VLM-side KV-reuse gate is currently on.
///
/// `MLXBackend` ANDs `enableKVCacheReuse` with `!routeThroughVLMFactory` at
/// `MLXBackend.swift:830` and stores the result at `:837`, so even when a
/// caller asks for reuse explicitly, VLMs always fall through to the
/// no-reuse path. This experiment proves that gate is in fact closed: load a
/// VLM, ask for reuse, and assert no `.kvCacheReuse` event ever fires.
///
/// **When the VLM gate is removed in a future PR, flip the assertion to
/// expect reuse > 0** and rename the test accordingly. Until then, this
/// reads as a regression guard for the audit's claim that VLM sessions pay
/// full prompt-prefill cost on every turn.
///
/// Opt-in via the `MLX_VLM_TEST_MODEL` environment variable — separate from
/// `MLX_TEST_MODEL` because VLMs are a different (and considerably larger)
/// download. The selector accepts either an absolute path or a substring of
/// a model directory name under `~/Documents/Models/`. When the env var is
/// not set, the test skips cleanly so default CI runs stay green.
@MainActor
final class MLXVLMGateExperimentTests: XCTestCase {

    private var modelURL: URL!
    private var loadedBackends: [MLXBackend] = []

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "Requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.hasMetalDevice, "Requires Metal GPU")

        let env = ProcessInfo.processInfo.environment
        guard let selector = env["MLX_VLM_TEST_MODEL"], !selector.isEmpty else {
            throw XCTSkip(
                "Set MLX_VLM_TEST_MODEL to a local MLX VLM directory (or a name substring under ~/Documents/Models/) to run the VLM gate experiment."
            )
        }

        let resolved = try resolveVLMModelURL(selector: selector)
        try XCTSkipUnless(
            MLXBackend.requiresVLMFactory(at: resolved),
            "MLX_VLM_TEST_MODEL=\(selector) does not resolve to a VLM (requiresVLMFactory returned false). Pick a model with vision_config or text_config.enable_moe_block."
        )
        modelURL = resolved
    }

    override func tearDown() async throws {
        for backend in loadedBackends.reversed() {
            backend.unloadModel()
        }
        loadedBackends.removeAll()
        modelURL = nil
        try await super.tearDown()
    }

    // MARK: - Selector

    /// Resolves the env-var selector to a model URL on disk.
    ///
    /// Mirrors the override semantics in ``HardwareRequirements`` —
    /// absolute path wins outright, otherwise the value is treated as a
    /// directory-name substring and fed to `findMLXModelDirectory`. The
    /// dedicated env var keeps the VLM and text-only test flows independent
    /// so a developer can have both downloaded at once.
    private func resolveVLMModelURL(selector: String) throws -> URL {
        let expanded = (selector as NSString).expandingTildeInPath
        if expanded.contains("/") {
            let url = URL(fileURLWithPath: expanded)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        // Override discovery so `findMLXModelDirectory` actually scans
        // ~/Documents/Models/ even when neither MLX_TEST_MODEL nor
        // MANIFOLD_DISCOVER_LOCAL_MODELS is set.
        var searchEnv = ProcessInfo.processInfo.environment
        searchEnv["MANIFOLD_DISCOVER_LOCAL_MODELS"] = "1"
        if let url = HardwareRequirements.findMLXModelDirectory(
            nameContains: selector,
            environment: searchEnv
        ) {
            return url
        }
        throw XCTSkip("MLX_VLM_TEST_MODEL=\(selector) did not resolve to a loadable model directory.")
    }

    // MARK: - Helpers

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

    private let firstUserPrompt = "Tell me about cats."
    private let secondUserPrompt = "Now tell me about dogs."

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

    // MARK: - Experiment

    /// Loads a VLM with `enableKVCacheReuse: true` and runs two turns sharing
    /// a prefix. Asserts no `.kvCacheReuse` event fires on either turn —
    /// confirms the gate at `MLXBackend.swift:830,837` is currently closed for
    /// every VLM regardless of caller intent.
    func test_vlmGateCurrentlyDisablesReuse() async throws {
        let backend = try await loadBackend(enableReuse: true)

        backend.resetConversation()
        let turn1Events = try await runTurn(on: backend, prompt: firstUserPrompt)
        let turn1Text = collectAssistantText(from: turn1Events)
        XCTAssertFalse(turn1Text.isEmpty, "Turn 1 must produce a reply on the VLM under test")

        backend.setConversationHistory([
            ("user", firstUserPrompt),
            ("assistant", turn1Text),
            ("user", secondUserPrompt),
        ])
        let turn2Events = try await runTurn(on: backend, prompt: secondUserPrompt)

        XCTAssertNil(
            reuseCount(in: turn1Events),
            "Turn 1 has no prior cache; .kvCacheReuse must not fire."
        )
        XCTAssertNil(
            reuseCount(in: turn2Events),
            """
            VLM gate experiment: enableKVCacheReuse=true on a VLM should produce \
            zero .kvCacheReuse events because MLXBackend ANDs reuse with \
            !routeThroughVLMFactory. If this assertion starts failing, the gate \
            has been removed and this test should flip to assert reuse > 0.
            """
        )
    }
}
#endif
