#if MLX
import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldMLX

/// Real-model validation for MLX KV-cache prefix reuse.
///
/// These tests are Xcode-only for the same reason as `MLXModelE2ETests`: MLX's
/// Metal shader library is not built by `swift test`. The suite is intentionally
/// hardware-gated and fixture-gated, and skips rather than failing when no
/// eligible local MLX text model is available.
@MainActor
final class MLXKVPersistenceIntegrationTests: XCTestCase {

    private var modelURL: URL!
    private var loadedBackends: [MLXBackend] = []

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "Requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.hasMetalDevice, "Requires Metal GPU")

        guard let mlxDir = HardwareRequirements.findMLXModelDirectory() else {
            throw XCTSkip(
                "No loadable MLX model found on disk. Install a local MLX snapshot with config.json, tokenizer, and safetensors weights."
            )
        }
        try XCTSkipIf(
            MLXBackend.requiresVLMFactory(at: mlxDir),
            "KV-cache reuse v1 is intentionally limited to text-only MLX models; VLM/MoE fixtures are out of scope."
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

    private struct TimedGenerationResult {
        let text: String
        let events: [GenerationEvent]
        let firstTokenLatency: Duration
    }

    private struct SecondTurnSample {
        let firstTurnText: String
        let secondTurn: TimedGenerationResult
    }

    private let longSharedPrefixPrompt = Array(
        repeating: "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu.",
        count: 90
    ).joined(separator: " ")

    private let followUpPrompt = "Using the earlier context only, answer with exactly the single word READY."
    private let performanceSampleCount = 5

    private var deterministicConfig: GenerationConfig {
        GenerationConfig(
            temperature: 0.0,
            topP: 1.0,
            repeatPenalty: 1.0,
            seed: 749,
            maxOutputTokens: 12,
            maxThinkingTokens: 0
        )
    }

    private var performanceConfig: GenerationConfig {
        GenerationConfig(
            temperature: 0.0,
            topP: 1.0,
            repeatPenalty: 1.0,
            seed: 749,
            maxOutputTokens: 1,
            maxThinkingTokens: 0
        )
    }

    private func loadBackend(enableReuse: Bool) async throws -> MLXBackend {
        let backend = MLXBackend(enableKVCacheReuse: enableReuse)
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 2048))
        loadedBackends.append(backend)
        return backend
    }

    private func generateTimed(
        on backend: MLXBackend,
        prompt: String,
        systemPrompt: String? = nil,
        config: GenerationConfig
    ) async throws -> TimedGenerationResult {
        let stream = try backend.generate(
            prompt: prompt,
            systemPrompt: systemPrompt,
            config: config
        )

        let clock = ContinuousClock()
        let start = clock.now
        var firstTokenLatency: Duration?
        var text = ""
        var events: [GenerationEvent] = []

        for try await event in stream.events {
            events.append(event)
            if case .token(let chunk) = event {
                if firstTokenLatency == nil {
                    firstTokenLatency = clock.now - start
                }
                text += chunk
            }
        }

        return TimedGenerationResult(
            text: text,
            events: events,
            firstTokenLatency: try XCTUnwrap(
                firstTokenLatency,
                "Generation must emit at least one visible token"
            )
        )
    }

    private func runSecondTurnSample(
        on backend: MLXBackend,
        config: GenerationConfig
    ) async throws -> SecondTurnSample {
        backend.resetConversation()

        let firstTurn = try await generateTimed(
            on: backend,
            prompt: longSharedPrefixPrompt,
            config: config
        )
        XCTAssertFalse(firstTurn.text.isEmpty, "Turn 1 must produce text so the follow-up history is well formed")

        backend.setConversationHistory([
            ("user", longSharedPrefixPrompt),
            ("assistant", firstTurn.text),
            ("user", followUpPrompt),
        ])

        let secondTurn = try await generateTimed(
            on: backend,
            prompt: followUpPrompt,
            config: config
        )
        return SecondTurnSample(firstTurnText: firstTurn.text, secondTurn: secondTurn)
    }

    private func warmRuntime(on backend: MLXBackend) async throws {
        backend.resetConversation()
        _ = try await generateTimed(
            on: backend,
            prompt: "Reply with exactly READY.",
            config: performanceConfig
        )
        backend.resetConversation()
    }

    private func waitForIdle(_ backend: MLXBackend, timeoutSeconds: Int = 5) async throws {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while backend.isGenerating, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(backend.isGenerating, "Backend should have stopped generating before the next turn begins")
    }

    private func firstReuseCount(in events: [GenerationEvent]) -> Int? {
        for event in events {
            if case .kvCacheReuse(let count) = event {
                return count
            }
        }
        return nil
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    func test_kvCacheReuse_deterministicWarmSecondTurn_matchesColdSecondTurn() async throws {
        let warmBackend = try await loadBackend(enableReuse: true)
        let warmSample = try await runSecondTurnSample(on: warmBackend, config: deterministicConfig)

        let warmReuse = try XCTUnwrap(
            firstReuseCount(in: warmSample.secondTurn.events),
            "Warm second turn must emit .kvCacheReuse or this correctness test is vacuous"
        )
        XCTAssertGreaterThan(warmReuse, 0, "Warm path must reuse a non-zero prompt prefix")

        warmBackend.unloadModel()

        let coldBackend = try await loadBackend(enableReuse: false)
        coldBackend.setConversationHistory([
            ("user", longSharedPrefixPrompt),
            ("assistant", warmSample.firstTurnText),
            ("user", followUpPrompt),
        ])
        let coldTurn2 = try await generateTimed(
            on: coldBackend,
            prompt: followUpPrompt,
            config: deterministicConfig
        )

        XCTAssertNil(
            firstReuseCount(in: coldTurn2.events),
            "Disabling reuse must remove the kvCacheReuse hit for the same follow-up prompt"
        )
        XCTAssertEqual(
            warmSample.secondTurn.text,
            coldTurn2.text,
            "Greedy second-turn output must match between warm and cold paths; otherwise cache restore changed the model result"
        )

        // Sabotage check: disabling the restore path (or shifting the reused prompt
        // positions) removes the reuse hit or changes the cold/warm output equality.
    }

    func test_kvCacheReuse_cancelledSecondTurnPreservesCompletedSnapshot() async throws {
        let backend = try await loadBackend(enableReuse: true)

        backend.resetConversation()
        let firstTurn = try await generateTimed(
            on: backend,
            prompt: longSharedPrefixPrompt,
            config: deterministicConfig
        )
        XCTAssertFalse(firstTurn.text.isEmpty)

        let sharedHistory = [
            ("user", longSharedPrefixPrompt),
            ("assistant", firstTurn.text),
            ("user", followUpPrompt),
        ]
        backend.setConversationHistory(sharedHistory)

        let cancelledStream = try backend.generate(
            prompt: followUpPrompt,
            systemPrompt: nil,
            config: performanceConfig
        )
        for try await event in cancelledStream.events {
            if case .token = event {
                break
            }
        }
        try await waitForIdle(backend)

        backend.setConversationHistory(sharedHistory)
        let retriedTurn = try await generateTimed(
            on: backend,
            prompt: followUpPrompt,
            config: performanceConfig
        )

        let reuse = try XCTUnwrap(
            firstReuseCount(in: retriedTurn.events),
            "Retrying after a cancelled second turn must still hit the prior completed snapshot"
        )
        XCTAssertGreaterThan(reuse, 0)

        // Sabotage check: clearing the stored prompt snapshot on cancellation removes
        // the retry-path reuse hit and makes this assertion fail.
    }

    func test_kvCacheReuse_warmSecondTurnImprovesTTFTByAtLeast2x() async throws {
        let warmBackend = try await loadBackend(enableReuse: true)
        try await warmRuntime(on: warmBackend)
        var warmSamples: [Double] = []
        for _ in 0..<performanceSampleCount {
            let result = try await runSecondTurnSample(on: warmBackend, config: performanceConfig)
            let reuse = try XCTUnwrap(
                firstReuseCount(in: result.secondTurn.events),
                "Warm-path performance sample must emit .kvCacheReuse to prove the cache actually hit"
            )
            XCTAssertGreaterThan(reuse, 0)
            warmSamples.append(durationSeconds(result.secondTurn.firstTokenLatency))
        }
        warmBackend.unloadModel()

        let coldBackend = try await loadBackend(enableReuse: false)
        try await warmRuntime(on: coldBackend)
        var coldSamples: [Double] = []
        for _ in 0..<performanceSampleCount {
            let result = try await runSecondTurnSample(on: coldBackend, config: performanceConfig)
            XCTAssertNil(firstReuseCount(in: result.secondTurn.events))
            coldSamples.append(durationSeconds(result.secondTurn.firstTokenLatency))
        }

        let warmMedian = median(warmSamples)
        let coldMedian = median(coldSamples)
        let improvement = coldMedian / warmMedian

        XCTAssertGreaterThan(
            improvement,
            2.0,
            "Warm second-turn TTFT should improve by >2x over cold prefill for a long shared prefix (cold median: \(coldMedian)s, warm median: \(warmMedian)s)"
        )

        // Sabotage check: disabling `enableKVCacheReuse` (or preventing the cache
        // snapshot from being restored) collapses the improvement ratio toward 1x.
    }

    func test_kvCacheReuse_missPathOverheadStaysNearColdBaseline() async throws {
        let reuseBackend = try await loadBackend(enableReuse: true)
        let unrelatedPrompt = "This is an unrelated prompt with no reusable prefix."
        let config = performanceConfig
        try await warmRuntime(on: reuseBackend)

        var reuseMissSamples: [Double] = []
        for _ in 0..<performanceSampleCount {
            reuseBackend.resetConversation()
            let miss = try await generateTimed(
                on: reuseBackend,
                prompt: unrelatedPrompt,
                config: config
            )
            XCTAssertNil(firstReuseCount(in: miss.events))
            reuseMissSamples.append(durationSeconds(miss.firstTokenLatency))
        }
        reuseBackend.unloadModel()

        let coldBackend = try await loadBackend(enableReuse: false)
        try await warmRuntime(on: coldBackend)
        var coldSamples: [Double] = []
        for _ in 0..<performanceSampleCount {
            coldBackend.resetConversation()
            let cold = try await generateTimed(
                on: coldBackend,
                prompt: unrelatedPrompt,
                config: config
            )
            XCTAssertNil(firstReuseCount(in: cold.events))
            coldSamples.append(durationSeconds(cold.firstTokenLatency))
        }

        let reuseMissMedian = median(reuseMissSamples)
        let coldMedian = median(coldSamples)
        let overheadRatio = reuseMissMedian / coldMedian

        XCTAssertLessThan(
            overheadRatio,
            1.25,
            "Reuse-enabled miss path should stay within 25% of the cold baseline (miss median: \(reuseMissMedian)s, cold median: \(coldMedian)s)"
        )

        // Sabotage check: adding expensive restore work on zero-prefix misses pushes
        // the miss path well above the cold baseline and fails the ratio assertion.
    }
}
#endif
