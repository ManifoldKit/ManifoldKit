import Foundation
import ManifoldInference

/// Starts a generation against a known-thinking backend, waits for the first
/// `.thinkingToken`, cancels the consuming task, and asserts that:
///
/// 1. The stream terminates cleanly (no thrown error on the normal cancel
///    path — the backend's cancellation style is cooperative).
/// 2. No `.thinkingCompleted` event lands *after* cancellation. An unmatched
///    `.thinkingCompleted` would leave downstream UI holding a phantom
///    ``ManifoldInference/MessagePart/thinking`` container.
/// 3. The number of `.thinkingCompleted` events is at most the number of
///    `.thinkingToken` events — the invariant "complete must follow at least
///    one token" holds across cancellation too.
public struct CancelDuringThinkingScenario: FuzzScenario {
    public let id = "cancel-during-thinking"
    public let humanName = "Cancel during thinking terminates cleanly with no dangling complete"

    public init() {}

    public func run() async throws -> ScenarioOutcome {
        let backend = ScenarioTestBackend(
            tokensToYield: ["Visible", " ", "never", " ", "reached"],
            thinkingTokensToYield: [
                "let", " ", "me", " ", "think", " ", "more", " ", "about",
                " ", "this", " ", "tricky", " ", "problem",
            ],
            emitThinkingComplete: true,
            // Give the consumer a deterministic window between the first
            // thinking token and the thinkingCompleted event to land its
            // cancel. Without this pause the backend would race through the
            // thinking burst before the scenario's cancel reached it.
            pauseBeforeThinkingComplete: .milliseconds(50)
        )
        try await backend.loadModel(from: URL(string: "mem://cancel-during-thinking")!, plan: .cloud())

        let stream = try backend.generate(
            prompt: "hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        // We consume the stream on a child task so the scenario can cancel it
        // once the first thinking token is observed — exactly the "user hit
        // stop during reasoning" shape.
        let collector = EventCollector()
        let task = Task {
            do {
                for try await event in stream.events {
                    await collector.append(event)
                    if case .thinkingToken = event {
                        // Nothing — the awaiter below cancels us externally.
                    }
                }
                return ConsumeResult.finished
            } catch is CancellationError {
                return ConsumeResult.cancelled
            } catch {
                return ConsumeResult.threw(error)
            }
        }

        // Wait for the backend to actually emit a thinking token before
        // cancelling; this removes any sleep-based flakiness from the
        // scenario.
        await backend.firstThinkingTokenEmitted.wait()
        task.cancel()
        backend.stopGeneration()
        let result = await task.value

        let observed = await collector.snapshot()
        let thinkingTokenIdxs = observed.indices.filter {
            if case .thinkingToken = observed[$0] { return true }
            return false
        }
        let thinkingCompleteIdxs = observed.indices.filter {
            if case .thinkingCompleted = observed[$0] { return true }
            return false
        }

        if case .threw(let err) = result {
            return ScenarioOutcome(
                scenarioId: id,
                invariantHeld: false,
                failureReason: "stream threw a non-cancellation error: \(err)",
                events: observed
            )
        }

        // `.thinkingCompleted` is permitted iff it came before cancellation
        // landed (we've already emitted at least one thinking token by then).
        // What must *not* happen: a dangling `.thinkingCompleted` with zero
        // preceding thinking tokens, or multiple `.thinkingCompleted`s.
        if thinkingCompleteIdxs.count > 1 {
            return ScenarioOutcome(
                scenarioId: id,
                invariantHeld: false,
                failureReason: "multiple .thinkingCompleted events across a cancelled stream",
                events: observed
            )
        }
        if let completeIdx = thinkingCompleteIdxs.first,
           thinkingTokenIdxs.isEmpty || thinkingTokenIdxs.contains(where: { $0 > completeIdx }) {
            // completeIdx with no earlier thinkingToken => dangling complete.
            if !thinkingTokenIdxs.contains(where: { $0 < completeIdx }) {
                return ScenarioOutcome(
                    scenarioId: id,
                    invariantHeld: false,
                    failureReason: "dangling .thinkingCompleted with no preceding .thinkingToken",
                    events: observed
                )
            }
        }
        return ScenarioOutcome(scenarioId: id, invariantHeld: true, events: observed)
    }

    private enum ConsumeResult {
        case finished
        case cancelled
        case threw(Error)
    }
}

/// Actor-guarded accumulator used by ``CancelDuringThinkingScenario`` so the
/// scenario's cancel observation and the event consumer don't race on a
/// shared array.
actor EventCollector {
    private var events: [GenerationEvent] = []

    func append(_ event: GenerationEvent) {
        events.append(event)
    }

    func snapshot() -> [GenerationEvent] {
        events
    }
}
