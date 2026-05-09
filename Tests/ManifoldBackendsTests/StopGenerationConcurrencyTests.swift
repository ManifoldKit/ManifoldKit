import XCTest
import ManifoldInference
import ManifoldTestSupport

/// Regression tests for #418: `stopGeneration()` / decode-loop interaction thread-safety.
///
/// These tests use `MockInferenceBackend` so they run in CI without hardware. They
/// verify that calling `stopGeneration()` concurrently from multiple tasks while a
/// generation is in progress terminates cleanly and leaves the backend in a consistent
/// state — the same contract the `Atomic<Bool>` fix in `LlamaBackend` enforces.
final class StopGenerationConcurrencyTests: XCTestCase {

    private let modelURL = URL(fileURLWithPath: "/tmp/fake-model")

    // MARK: - Concurrent stopGeneration (hardware not required)

    /// Regression for #418: concurrent `stopGeneration()` calls must not produce a
    /// data race. The mock backend's `activeContinuation` is written from the
    /// generation task and nulled from `stopGeneration()` — exercising the same
    /// producer/consumer pattern as the `cancelled` flag in `LlamaBackend`.
    ///
    /// Thread Sanitizer must report zero violations when this test runs.
    func test_stopGeneration_calledConcurrentlyWhileGenerating_terminatesCleanly() async throws {
        // Give the mock a long token list so generation is still running when
        // the concurrent stop fires.
        let tokens = (0..<200).map { "tok\($0)" }
        let backend = MockInferenceBackend()
        backend.tokensToYield = tokens
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let stream = try backend.generate(prompt: "test", systemPrompt: nil, config: GenerationConfig())

        // Spawn 10 concurrent tasks, each calling stopGeneration(). The first call
        // finishes the continuation; subsequent calls are no-ops (activeContinuation
        // is nil). None must race.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    backend.stopGeneration()
                }
            }
        }

        // Drain the stream — it must finish (possibly with zero tokens) rather than hang.
        var collectedTokens: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event {
                collectedTokens.append(t)
            }
        }

        // After all concurrent stops and a drained stream, isGenerating must be false.
        XCTAssertFalse(backend.isGenerating,
                       "isGenerating must be false after stopGeneration() terminates the stream")
        // stopCallCount reflects all concurrent invocations — must be exactly 10.
        XCTAssertEqual(backend.stopCallCount, 10,
                       "Each concurrent stopGeneration() call must be counted")
        // Tokens collected may be 0 to N depending on task interleaving — just
        // verify the count is within the valid range.
        XCTAssertLessThanOrEqual(collectedTokens.count, tokens.count,
                                 "Cannot have collected more tokens than were configured to yield")
    }

    /// A single `stopGeneration()` call from a concurrent task while the stream is
    /// being consumed must terminate the stream without deadlocking or throwing.
    ///
    /// This is the minimal reproducer for the race described in #418: one writer
    /// (the stop caller) and one reader (the stream consumer) with no explicit
    /// synchronisation between them — only the atomic cancellation flag.
    func test_stopGeneration_fromConcurrentTask_whileConsumingStream_terminatesStream() async throws {
        let backend = MockInferenceBackend()
        backend.tokensToYield = (0..<500).map { "t\($0)" }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let stream = try backend.generate(prompt: "test", systemPrompt: nil, config: GenerationConfig())

        // Fire the stop from a detached task — detached tasks don't inherit the
        // structured-concurrency requirement for `sending` captures, letting us
        // call stopGeneration() on the backend without a sendability violation.
        let stopTask = Task.detached {
            await Task.yield()  // let the consumer iterate at least once
            backend.stopGeneration()
        }

        // Consumer: drain the stream until it finishes (either by stop or naturally).
        var consumedTokens: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event {
                consumedTokens.append(t)
            }
        }

        await stopTask.value  // ensure stop task completed

        XCTAssertFalse(backend.isGenerating,
                       "isGenerating must be false after concurrent stop + stream drain")
        XCTAssertLessThanOrEqual(consumedTokens.count, 500,
                                 "Consumed token count must not exceed configured yield count")
    }
}
