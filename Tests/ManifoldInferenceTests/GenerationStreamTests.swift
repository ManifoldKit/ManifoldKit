import XCTest
@testable import ManifoldInference

@MainActor
final class GenerationStreamTests: XCTestCase {

    // MARK: - Event Delivery

    func test_eventsDeliversAllTokens() async throws {
        let inner = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.yield(.token("Hello"))
            continuation.yield(.token(" world"))
            continuation.finish()
        }
        let stream = GenerationStream(inner)

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }
        // Sabotage check: replacing `continuation.yield(.token(...))` with no-ops causes this to fail
        XCTAssertEqual(tokens, ["Hello", " world"])
    }

    func test_eventsDeliversUsage() async throws {
        let inner = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.yield(.usage(TokenUsage(promptTokens: 10, completionTokens: 5)))
            continuation.finish()
        }
        let stream = GenerationStream(inner)

        var usages: [(Int, Int)] = []
        for try await event in stream.events {
            if case .usage(let usage) = event {
                usages.append((usage.promptTokens, usage.completionTokens))
            }
        }
        // Sabotage check: removing the .usage yield from the inner stream causes count to be 0
        XCTAssertEqual(usages.count, 1)
        XCTAssertEqual(usages[0].0, 10)
        XCTAssertEqual(usages[0].1, 5)
    }

    // MARK: - Error Propagation

    func test_errorPropagatesThroughEvents() async {
        let expectedError = NSError(domain: "test", code: 42)
        let inner = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.yield(.token("partial"))
            continuation.finish(throwing: expectedError)
        }
        let stream = GenerationStream(inner)

        var tokens: [String] = []
        do {
            for try await event in stream.events {
                if case .token(let text) = event {
                    tokens.append(text)
                }
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual((error as NSError).code, 42)
        }
        XCTAssertEqual(tokens, ["partial"])
    }

    // MARK: - Phase Management

    func test_initialPhaseIsConnecting() {
        let inner = AsyncThrowingStream<GenerationEvent, Error> { $0.finish() }
        let stream = GenerationStream(inner)
        // Sabotage check: changing the initial phase in GenerationStream.init causes this to fail
        XCTAssertEqual(stream.phase, .connecting)
    }

    func test_setPhaseUpdatesPhase() {
        let inner = AsyncThrowingStream<GenerationEvent, Error> { $0.finish() }
        let stream = GenerationStream(inner)

        stream.setPhase(.streaming)
        XCTAssertEqual(stream.phase, .streaming)

        stream.setPhase(.done)
        XCTAssertEqual(stream.phase, .done)
    }

    func test_setPhaseToFailed() {
        let inner = AsyncThrowingStream<GenerationEvent, Error> { $0.finish() }
        let stream = GenerationStream(inner)

        stream.setPhase(.failed("Network error"))
        XCTAssertEqual(stream.phase, .failed("Network error"))
    }

    func test_setPhaseToRetrying() {
        let inner = AsyncThrowingStream<GenerationEvent, Error> { $0.finish() }
        let stream = GenerationStream(inner)

        stream.setPhase(.retrying(attempt: 2, of: 3))
        XCTAssertEqual(stream.phase, .retrying(attempt: 2, of: 3))
    }

    // MARK: - Idle Timeout Configuration

    func test_idleTimeoutNilByDefault() {
        let inner = AsyncThrowingStream<GenerationEvent, Error> { $0.finish() }
        let stream = GenerationStream(inner)
        // Sabotage check: setting a non-nil default for idleTimeout in init causes this to fail
        XCTAssertNil(stream.idleTimeout)
    }

    func test_idleTimeoutStoredWhenProvided() {
        let inner = AsyncThrowingStream<GenerationEvent, Error> { $0.finish() }
        let stream = GenerationStream(inner, idleTimeout: .seconds(120))
        XCTAssertEqual(stream.idleTimeout, .seconds(120))
    }

    // MARK: - Idle Timeout Behavior

    func test_idleTimeout_throwsWhenNoEvents() async throws {
        let inner = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            // Never yield any events — simulate a stalled stream.
            Task {
                try? await Task.sleep(for: .seconds(10))
                continuation.finish()
            }
        }
        let stream = GenerationStream(inner, idleTimeout: .milliseconds(100))

        do {
            for try await _ in stream.events {}
            XCTFail("Should have thrown timeout error")
        } catch let error as CloudBackendError {
            // Sabotage check: removing the idle timeout race in events causes the stream to hang instead of throwing
            guard case .timeout = error else {
                XCTFail("Expected .timeout, got \(error)")
                return
            }
        }
    }

    func test_idleTimeout_setsPhaseToStalled() async throws {
        let inner = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            Task {
                try? await Task.sleep(for: .seconds(10))
                continuation.finish()
            }
        }
        let stream = GenerationStream(inner, idleTimeout: .milliseconds(100))

        do {
            for try await _ in stream.events {}
        } catch {
            // Expected timeout
        }
        // Poll until the @MainActor phase-update task has set .stalled, with a deadline.
        let deadline = Date().addingTimeInterval(2.0)
        while stream.phase != .stalled && Date() < deadline { await Task.yield() }

        // Sabotage check: removing `setPhase(.stalled)` from the timeout path causes this to fail
        XCTAssertEqual(stream.phase, .stalled)
    }

    func test_idleTimeout_doesNotFireWhenEventsArrive() async throws {
        let inner = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            Task {
                for i in 0..<5 {
                    try? await Task.sleep(for: .milliseconds(20))
                    continuation.yield(.token("t\(i)"))
                }
                continuation.finish()
            }
        }
        // Timeout is 200ms, events arrive every 20ms — should complete normally.
        let stream = GenerationStream(inner, idleTimeout: .milliseconds(200))

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }
        XCTAssertEqual(tokens.count, 5)
    }

    // MARK: - Cancellation

    func test_cancellationStopsEventDelivery() async throws {
        let inner = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            Task {
                for i in 0..<100 {
                    if Task.isCancelled { break }
                    continuation.yield(.token("t\(i)"))
                    try? await Task.sleep(for: .milliseconds(10))
                }
                continuation.finish()
            }
        }
        let stream = GenerationStream(inner)

        let task = Task {
            var count = 0
            for try await _ in stream.events {
                count += 1
                if count >= 3 { break }
            }
            return count
        }

        let count = try await task.value
        XCTAssertGreaterThanOrEqual(count, 3)
    }
}
