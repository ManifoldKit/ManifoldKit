#if Ollama
import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends

/// End-to-end tests for thinking/reasoning model behaviour on a real Ollama server.
///
/// These tests are separated from `OllamaE2ETests` because they are slow
/// (~180 s on qwen3.5:4b) and often run selectively during thinking-feature
/// iteration. Keeping them in their own file makes `-only-testing` targeting
/// straightforward without pulling in the full Ollama suite.
///
/// Skipped automatically when Ollama is unreachable or no model is available.
@MainActor
final class OllamaThinkingE2ETests: XCTestCase {

    private var backend: OllamaBackend!
    private var modelName: String!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(HardwareRequirements.hasOllamaServer, "Ollama server not running at localhost:11434")

        guard let model = HardwareRequirements.findOllamaModel() else {
            throw XCTSkip("No Ollama model available")
        }
        modelName = model

        backend = OllamaBackend()
        backend.configure(
            baseURL: URL(string: "http://localhost:11434")!,
            modelName: modelName
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    override func tearDown() async throws {
        backend?.unloadModel()
        backend = nil
        modelName = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Prompt that reliably provokes chain-of-thought on reasoning models.
    private static let reasoningPrompt = """
    Solve this carefully: a train leaves station A at 3pm travelling 60 mph, \
    and another leaves station B at 4pm travelling 80 mph toward it. The \
    stations are 300 miles apart. At what time do they meet?
    """

    /// Process-lifetime cache keyed by model name so the probe runs at most
    /// once per `swift test` invocation. Each entry is a `Task` so the first
    /// caller triggers the probe and later callers await the same result without
    /// racing.
    private static var cachedProbes: [String: Task<Bool, Error>] = [:]

    /// Drives a short probe generation to classify the selected model as
    /// thinking or non-thinking. Returns `true` when the model emits
    /// `.thinkingToken` events before the first visible `.token`.
    ///
    /// Result is memoized per model name so repeated calls within the same
    /// test process return immediately.
    private func probeModelEmitsThinking() async throws -> Bool {
        let model = modelName!
        if let existing = Self.cachedProbes[model] {
            return try await existing.value
        }
        let backendRef = backend!
        let task = Task<Bool, Error> { @MainActor in
            let config = GenerationConfig(
                temperature: 0.3,
                maxOutputTokens: 64,
                maxThinkingTokens: 16
            )
            let stream = try backendRef.generate(
                prompt: Self.reasoningPrompt,
                systemPrompt: nil,
                config: config
            )
            var sawThinking = false
            for try await event in stream.events {
                switch event {
                case .thinkingToken:
                    sawThinking = true
                case .token:
                    return sawThinking
                default:
                    continue
                }
            }
            return sawThinking
        }
        Self.cachedProbes[model] = task
        return try await task.value
    }

    // MARK: - Thinking Tests

    /// Test A — Thinking models must emit `.thinkingToken` events and fire
    /// exactly one `.thinkingCompleted` before the first visible `.token`.
    func testThinkingModel_emitsThinkingEventsBeforeVisibleOutput() async throws {
        // qwen3.5:4b can spend well over 1k tokens reasoning through the
        // train-meeting prompt before emitting any visible content. When
        // `maxThinkingTokens == nil` OllamaBackend reserves 2048 extra on the
        // wire for detected thinking models, so on-wire `num_predict` is
        // `maxOutputTokens + 2048`. 2048 visible gives heavy thinkers room
        // to finish reasoning *and* surface at least one post-thinking token,
        // which is what the final assertion requires.
        let config = GenerationConfig(temperature: 0.3, maxOutputTokens: 2048)
        let stream = try backend.generate(
            prompt: Self.reasoningPrompt,
            systemPrompt: nil,
            config: config
        )

        var thinkingTokenCount = 0
        var thinkingCompleteCount = 0
        var firstTokenAfterThinkingComplete: Bool?
        var visibleText = ""
        var sawFirstVisibleToken = false

        for try await event in stream.events {
            switch event {
            case .thinkingToken:
                thinkingTokenCount += 1
                if sawFirstVisibleToken {
                    XCTFail("Received .thinkingToken after visible .token — reasoning must precede visible output on this backend")
                }
            case .thinkingCompleted:
                thinkingCompleteCount += 1
                if !sawFirstVisibleToken {
                    firstTokenAfterThinkingComplete = true
                }
            case .token(let text):
                visibleText += text
                sawFirstVisibleToken = true
                if firstTokenAfterThinkingComplete == nil {
                    firstTokenAfterThinkingComplete = false
                }
            default:
                continue
            }
        }

        try XCTSkipIf(
            thinkingTokenCount == 0,
            "selected model '\(modelName!)' does not produce thinking tokens — skipping thinking-specific assertions"
        )

        XCTAssertEqual(
            thinkingCompleteCount,
            1,
            "Exactly one .thinkingCompleted event must fire (got \(thinkingCompleteCount), model: \(modelName!))"
        )
        XCTAssertEqual(
            firstTokenAfterThinkingComplete,
            true,
            ".thinkingCompleted must fire before the first visible .token (model: \(modelName!))"
        )
        XCTAssertFalse(
            visibleText.isEmpty,
            "Thinking model must still emit a visible response (model: \(modelName!))"
        )
    }

    /// Test B — `maxThinkingTokens=0` must suppress reasoning while still
    /// producing visible output.
    func testThinkingModel_maxThinkingTokensZero_suppressesReasoning() async throws {
        let isThinkingModel = try await probeModelEmitsThinking()
        try XCTSkipIf(
            !isThinkingModel,
            "selected model '\(modelName!)' does not produce thinking tokens — maxThinkingTokens=0 assertion is vacuous"
        )

        // Reasoning is suppressed here, so 256 tokens is plenty for the
        // visible answer alone — test only asserts visibleText is non-empty.
        let config = GenerationConfig(
            temperature: 0.3,
            maxOutputTokens: 256,
            maxThinkingTokens: 0
        )
        let stream = try backend.generate(
            prompt: Self.reasoningPrompt,
            systemPrompt: nil,
            config: config
        )

        var thinkingTokenCount = 0
        var thinkingCompleteCount = 0
        var visibleText = ""

        for try await event in stream.events {
            switch event {
            case .thinkingToken:
                thinkingTokenCount += 1
            case .thinkingCompleted:
                thinkingCompleteCount += 1
            case .token(let text):
                visibleText += text
            default:
                continue
            }
        }

        XCTAssertEqual(
            thinkingTokenCount,
            0,
            "maxThinkingTokens=0 must suppress every .thinkingToken event (got \(thinkingTokenCount), model: \(modelName!))"
        )
        XCTAssertEqual(
            thinkingCompleteCount,
            0,
            "maxThinkingTokens=0 must fire zero .thinkingCompleted events (got \(thinkingCompleteCount), model: \(modelName!))"
        )
        XCTAssertFalse(
            visibleText.isEmpty,
            "Visible response must still arrive when reasoning is suppressed (model: \(modelName!))"
        )
    }

    /// Test C — `maxThinkingTokens=5` must cap reasoning emission; OllamaBackend
    /// drops thinking chunks once `thinkingTokenCount >= limit`, so only the
    /// first few lines survive.
    func testThinkingModel_maxThinkingTokensCapped_limitsReasoning() async throws {
        let isThinkingModel = try await probeModelEmitsThinking()
        try XCTSkipIf(
            !isThinkingModel,
            "selected model '\(modelName!)' does not produce thinking tokens — cap assertion is vacuous"
        )

        // OllamaBackend drops thinking chunks client-side once the 5th event
        // arrives, but the server still generates the full reasoning trace —
        // `num_predict` on the wire is `maxOutputTokens + maxThinkingTokens`,
        // so the budget has to cover server-side reasoning PLUS a non-empty
        // visible answer. qwen3.5:4b in particular emits 1000+ reasoning
        // tokens on the train-meeting prompt even when the client is dropping
        // `thinkingToken` events. 4096 visible + 5 thinking gives heavy
        // thinkers enough runway to finish reasoning server-side AND produce
        // a visible answer.
        let config = GenerationConfig(
            temperature: 0.3,
            maxOutputTokens: 4096,
            maxThinkingTokens: 5
        )
        let stream = try backend.generate(
            prompt: Self.reasoningPrompt,
            systemPrompt: nil,
            config: config
        )

        var thinkingTokenCount = 0
        var thinkingCompleteCount = 0
        var visibleText = ""

        for try await event in stream.events {
            switch event {
            case .thinkingToken:
                thinkingTokenCount += 1
            case .thinkingCompleted:
                thinkingCompleteCount += 1
            case .token(let text):
                visibleText += text
            default:
                continue
            }
        }

        // Allow generous headroom over the cap — OllamaBackend counts per
        // NDJSON line, so the observed count hovers near but rarely exceeds the
        // limit by more than a handful. 20 is well above 5 and well below what
        // an uncapped run would produce for this prompt.
        XCTAssertLessThan(
            thinkingTokenCount,
            20,
            "maxThinkingTokens=5 must meaningfully cap reasoning emission (got \(thinkingTokenCount), model: \(modelName!))"
        )
        XCTAssertEqual(
            thinkingCompleteCount,
            1,
            "Exactly one .thinkingCompleted event must fire even when capped (got \(thinkingCompleteCount), model: \(modelName!))"
        )
        XCTAssertFalse(
            visibleText.isEmpty,
            "Capped thinking must not starve visible output (model: \(modelName!))"
        )
    }
}
#endif
