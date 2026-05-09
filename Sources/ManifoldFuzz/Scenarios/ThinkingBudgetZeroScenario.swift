import Foundation
import ManifoldInference

/// Drives a known-thinking backend with `maxThinkingTokens = 0` and asserts
/// that:
///
/// 1. Zero `.thinkingToken` events ever fire.
/// 2. Zero `.thinkingComplete` events fire (since no reasoning was emitted).
/// 3. Visible output still appears.
///
/// Once P4 wires Ollama's `think: false` through, this scenario replays
/// against the real backend and proves the wire-level disable path. Pre-P4 it
/// verifies the client-side cap in ``ScenarioTestBackend``, which mirrors the
/// drop-on-zero-limit path in `OllamaBackend.parseResponseStream`.
public struct ThinkingBudgetZeroScenario: FuzzScenario {
    public let id = "thinking-budget-zero"
    public let humanName = "Thinking budget = 0 produces no thinking events"

    public init() {}

    public func run() async throws -> ScenarioOutcome {
        let backend = ScenarioTestBackend(
            tokensToYield: ["Visible", " ", "output", "."],
            thinkingTokensToYield: ["should", " ", "not", " ", "leak"],
            emitThinkingComplete: true
        )
        try await backend.loadModel(from: URL(string: "mem://thinking-budget-zero")!, plan: .cloud())

        var config = GenerationConfig()
        config.maxThinkingTokens = 0

        let stream = try backend.generate(
            prompt: "hello",
            systemPrompt: nil,
            config: config
        )

        var observed: [GenerationEvent] = []
        for try await event in stream.events {
            observed.append(event)
        }

        let thinkingTokenCount = observed.reduce(0) { acc, e in
            if case .thinkingToken = e { return acc + 1 }
            return acc
        }
        let thinkingCompleteCount = observed.reduce(0) { acc, e in
            if case .thinkingComplete = e { return acc + 1 }
            return acc
        }
        let visibleCount = observed.reduce(0) { acc, e in
            if case .token = e { return acc + 1 }
            return acc
        }

        if thinkingTokenCount > 0 {
            return ScenarioOutcome(
                scenarioId: id,
                invariantHeld: false,
                failureReason: "emitted \(thinkingTokenCount) thinking tokens despite maxThinkingTokens=0",
                events: observed
            )
        }
        if thinkingCompleteCount > 0 {
            return ScenarioOutcome(
                scenarioId: id,
                invariantHeld: false,
                failureReason: "emitted .thinkingComplete despite zero thinking tokens",
                events: observed
            )
        }
        if visibleCount == 0 {
            return ScenarioOutcome(
                scenarioId: id,
                invariantHeld: false,
                failureReason: "no visible tokens emitted — disabling thinking starved visible output",
                events: observed
            )
        }
        return ScenarioOutcome(scenarioId: id, invariantHeld: true, events: observed)
    }
}
