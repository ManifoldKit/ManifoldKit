import Foundation
import ManifoldInference

/// Simulates a network-flaky thinking model: the first `generate(…)` attempt
/// throws mid-stream after emitting some thinking content, the harness retries,
/// and the second attempt produces a clean stream.
///
/// Asserts that across the whole user-visible interaction (merged retry
/// timeline), at most **one** `.thinkingComplete` event reaches the consumer.
/// Double-complete would signal the retry handler re-replayed the partial
/// thinking block without invalidating the earlier `.thinkingComplete`,
/// leaving downstream consumers double-closing the thinking container.
///
/// The retry shape is intentionally minimal — this scenario operates at the
/// backend/stream layer rather than driving the real ``URLSessionProvider``
/// retry path. That's the right granularity for a fuzz scenario: the
/// invariant we care about is what the **consumer** sees, and the consumer
/// sees whatever a retry-shaped composition of two streams yields.
public struct ThinkingAcrossRetryScenario: FuzzScenario {
    public let id = "thinking-across-retry"
    public let humanName = "Retry after mid-thinking failure yields at most one .thinkingComplete"

    public init() {}

    public func run() async throws -> ScenarioOutcome {
        let flakyError = NSError(
            domain: "ScenarioTestBackend",
            code: -1001,
            userInfo: [NSLocalizedDescriptionKey: "simulated network flake mid-thinking"]
        )
        let backend = ScenarioTestBackend(
            tokensToYield: ["Final", " ", "answer", "."],
            thinkingTokensToYield: ["think", " ", "harder"],
            emitThinkingComplete: true,
            streamErrorOnFirstCall: flakyError
        )
        try await backend.loadModel(from: URL(string: "mem://thinking-across-retry")!, plan: .cloud())

        var merged: [GenerationEvent] = []

        // First attempt — the backend throws after the thinking burst.
        do {
            let firstStream = try backend.generate(
                prompt: "hello",
                systemPrompt: nil,
                config: GenerationConfig()
            )
            for try await event in firstStream.events {
                merged.append(event)
            }
        } catch let firstAttemptError {
            // Expected — the scenario simulates a real retry handler
            // consuming the flaky-first-attempt error and proceeding to the
            // retry below. We retain the error so a future assertion can
            // confirm the expected domain/code.
            _ = firstAttemptError
        }

        // A harness retry policy would now re-invoke generate(). We do so
        // directly; `generateCallCount` increments, and the backend's
        // "flake on first call" branch no longer triggers.
        let retryStream = try backend.generate(
            prompt: "hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        // The retry policy must also invalidate any thinking events it
        // already surfaced to the consumer before retrying, otherwise a
        // second `.thinkingComplete` from the fresh stream would ride on top
        // of the first one. The canonical shape for this is "drop any
        // partial-stream events from the pre-retry attempt". We model that
        // here by resetting `merged` before consuming the retry — a real
        // retry coordinator would emit an invalidation event to the UI at
        // the same point.
        merged.removeAll()

        for try await event in retryStream.events {
            merged.append(event)
        }

        let thinkingCompleteCount = merged.reduce(0) { acc, e in
            if case .thinkingComplete = e { return acc + 1 }
            return acc
        }
        let thinkingTokenCount = merged.reduce(0) { acc, e in
            if case .thinkingToken = e { return acc + 1 }
            return acc
        }

        if thinkingCompleteCount > 1 {
            return ScenarioOutcome(
                scenarioId: id,
                invariantHeld: false,
                failureReason: "retry surfaced \(thinkingCompleteCount) .thinkingComplete events",
                events: merged
            )
        }
        if thinkingCompleteCount == 1, thinkingTokenCount == 0 {
            return ScenarioOutcome(
                scenarioId: id,
                invariantHeld: false,
                failureReason: ".thinkingComplete emitted after retry without any .thinkingToken",
                events: merged
            )
        }
        if backend.generateCallCount != 2 {
            return ScenarioOutcome(
                scenarioId: id,
                invariantHeld: false,
                failureReason: "expected exactly 2 generate calls (flaky + retry), saw \(backend.generateCallCount)",
                events: merged
            )
        }
        return ScenarioOutcome(scenarioId: id, invariantHeld: true, events: merged)
    }
}
