import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for ``FallbackBackend`` — the error-advance routing chain (#1935).
///
/// The chain tries backends in order, advances on a routable (retryable) error
/// raised *before the first content token*, returns the first success, and
/// aggregates per-backend errors into ``FallbackExhaustedError`` when all fail.
final class FallbackBackendTests: XCTestCase {

    // MARK: - Fixtures

    /// A retryable cloud error (transient — should advance).
    private var retryable: CloudBackendError { .rateLimited(retryAfter: nil) }

    /// A non-retryable cloud error (terminal — must fail fast, not advance).
    private var nonRetryable: CloudBackendError { .authenticationFailed(provider: "test") }

    private func loadedMock(
        tokens: [String] = ["ok"],
        caps: BackendCapabilities = BackendCapabilities()
    ) -> MockInferenceBackend {
        let mock = MockInferenceBackend(capabilities: caps)
        mock.isModelLoaded = true
        mock.tokensToYield = tokens
        return mock
    }

    /// Drains a fallback chain to completion, collecting tokens. Throws the
    /// terminal error if the stream fails.
    private func drain(
        _ backend: FallbackBackend,
        prompt: String = "hi"
    ) async throws -> [String] {
        let stream = try backend.generate(prompt: prompt, systemPrompt: nil, config: GenerationConfig())
        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event { tokens.append(t) }
        }
        return tokens
    }

    // MARK: - Advance on retryable error

    func testAdvancesOnRetryableError() async throws {
        let failing = loadedMock()
        // No tokens, then a retryable stream error → pre-first-token failure.
        failing.tokensToYield = []
        failing.shouldThrowInsideStream = retryable
        let second = loadedMock(tokens: ["from-second"])

        let chain = FallbackBackend(backends: [failing, second])
        let tokens = try await drain(chain)

        XCTAssertEqual(tokens, ["from-second"])
        XCTAssertEqual(failing.generateCallCount, 1)
        XCTAssertEqual(second.generateCallCount, 1)
    }

    func testAdvancesOnSynchronousRetryableThrow() async throws {
        // generate() itself throwing (vs throwing inside the stream) is also a
        // pre-first-token failure and must advance.
        let failing = loadedMock()
        failing.shouldThrowOnGenerate = retryable
        let second = loadedMock(tokens: ["recovered"])

        let chain = FallbackBackend(backends: [failing, second])
        let tokens = try await drain(chain)

        XCTAssertEqual(tokens, ["recovered"])
    }

    // MARK: - First success wins

    func testReturnsFirstSuccessWithoutAdvancing() async throws {
        let first = loadedMock(tokens: ["primary"])
        let second = loadedMock(tokens: ["secondary"])

        let chain = FallbackBackend(backends: [first, second])
        let tokens = try await drain(chain)

        XCTAssertEqual(tokens, ["primary"])
        XCTAssertEqual(first.generateCallCount, 1)
        // The second backend must never be touched once the first succeeds.
        XCTAssertEqual(second.generateCallCount, 0)
    }

    // MARK: - Fail fast on non-retryable error

    func testDoesNotAdvanceOnNonRetryableError() async throws {
        let failing = loadedMock()
        failing.tokensToYield = []
        failing.shouldThrowInsideStream = nonRetryable
        let second = loadedMock(tokens: ["should-not-reach"])

        let chain = FallbackBackend(backends: [failing, second])

        do {
            _ = try await drain(chain)
            XCTFail("Expected the non-retryable error to propagate")
        } catch let error as CloudBackendError {
            guard case .authenticationFailed = error else {
                return XCTFail("Expected authenticationFailed, got \(error)")
            }
            XCTAssertFalse(error.isRetryable)
        }
        // Fail-fast: the second backend must NOT be invoked.
        XCTAssertEqual(second.generateCallCount, 0)
    }

    // MARK: - All fail → aggregate last error

    func testPropagatesAggregateWhenAllFail() async throws {
        let a = loadedMock(); a.tokensToYield = []; a.shouldThrowInsideStream = retryable
        let b = loadedMock(); b.tokensToYield = []; b.shouldThrowInsideStream = retryable
        let c = loadedMock(); c.tokensToYield = []
        c.shouldThrowInsideStream = CloudBackendError.providerOverloaded(provider: "x", retryAfter: nil)

        let chain = FallbackBackend(backends: [a, b, c])

        do {
            _ = try await drain(chain)
            XCTFail("Expected FallbackExhaustedError")
        } catch let exhausted as FallbackExhaustedError {
            // All three errors aggregated, in attempt order.
            XCTAssertEqual(exhausted.perBackendErrors.count, 3)
            XCTAssertFalse(exhausted.isRetryable)
            // Last error is the most-relevant terminal cause.
            XCTAssertTrue(exhausted.lastError is CloudBackendError)
        }
        XCTAssertEqual(a.generateCallCount, 1)
        XCTAssertEqual(b.generateCallCount, 1)
        XCTAssertEqual(c.generateCallCount, 1)
    }

    // MARK: - Order preservation

    func testPreservesBackendOrder() async throws {
        // First two fail retryably; the third succeeds. Order must hold.
        let first = loadedMock(); first.tokensToYield = []; first.shouldThrowInsideStream = retryable
        let second = loadedMock(); second.tokensToYield = []; second.shouldThrowInsideStream = retryable
        let third = loadedMock(tokens: ["third-wins"])

        let chain = FallbackBackend(backends: [first, second, third])
        let tokens = try await drain(chain)

        XCTAssertEqual(tokens, ["third-wins"])
        XCTAssertEqual(first.generateCallCount, 1)
        XCTAssertEqual(second.generateCallCount, 1)
        XCTAssertEqual(third.generateCallCount, 1)
    }

    // MARK: - No fail-over after first token (streaming semantics)

    func testDoesNotAdvanceAfterFirstTokenByDefault() async throws {
        // Backend yields one real token, THEN throws a retryable error.
        let failing = loadedMock(tokens: ["partial"])
        failing.shouldThrowInsideStream = retryable
        let second = loadedMock(tokens: ["should-not-reach"])

        let chain = FallbackBackend(backends: [failing, second])

        var received: [String] = []
        do {
            let stream = try chain.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
            for try await event in stream.events {
                if case .token(let t) = event { received.append(t) }
            }
            XCTFail("Expected the post-token error to propagate")
        } catch let error as CloudBackendError {
            guard case .rateLimited = error else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
        }
        // The partial token reached the consumer.
        XCTAssertEqual(received, ["partial"])
        // The chain must NOT have failed over — partial output was already seen.
        XCTAssertEqual(second.generateCallCount, 0)
    }

    func testAdvancesAfterFirstTokenWhenOptedIn() async throws {
        // Same shape, but advanceAfterFirstToken discards partial output and
        // restarts on the next backend.
        let failing = loadedMock(tokens: ["discarded-partial"])
        failing.shouldThrowInsideStream = retryable
        let second = loadedMock(tokens: ["restarted"])

        let policy = FallbackPolicy(advanceAfterFirstToken: true)
        let chain = FallbackBackend(backends: [failing, second], policy: policy)

        let stream = try chain.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        var received: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event { received.append(t) }
        }
        // Both the partial (pre-failover) and the restart tokens are forwarded.
        XCTAssertEqual(received, ["discarded-partial", "restarted"])
        XCTAssertEqual(second.generateCallCount, 1)
    }

    // MARK: - Per-backend retry composes with fallback

    func testPerBackendRetriesBeforeAdvancing() async throws {
        // The first backend always fails retryably; with perBackendRetries=2 it
        // should be retried (3 generate() calls total via withRetry) before the
        // chain advances to the success backend. RecordingRetrySleeper keeps the
        // test deterministic with no real wall-clock delay.
        let recorder = RecordingRetrySleeper()
        let failing = loadedMock(); failing.tokensToYield = []; failing.shouldThrowInsideStream = retryable
        let second = loadedMock(tokens: ["after-retries"])

        let policy = FallbackPolicy(perBackendRetries: 2)
        let chain = FallbackBackend(backends: [failing, second], policy: policy, retrySleeper: recorder.asSleeper)

        let tokens = try await drain(chain)

        XCTAssertEqual(tokens, ["after-retries"])
        // withRetry(maxRetries: 2) → initial + 2 retries = 3 attempts.
        XCTAssertEqual(failing.generateCallCount, 3)
        // Two retry delays were requested (and recorded, not slept).
        XCTAssertEqual(recorder.recordedSleeps.count, 2)
        XCTAssertEqual(second.generateCallCount, 1)
    }

    // MARK: - Capability union matches RouterBackend

    func testCapabilityUnionMatchesRouter() async throws {
        let a = loadedMock(caps: BackendCapabilities(
            maxContextTokens: 2048,
            supportsToolCalling: false,
            supportsThinking: true
        ))
        let b = loadedMock(caps: BackendCapabilities(
            maxContextTokens: 32_000,
            supportsToolCalling: true,
            supportsThinking: false
        ))

        let fallback = FallbackBackend(backends: [a, b])
        let router = RouterBackend(children: [a, b])

        // Same union helper underneath — must agree field-for-field.
        XCTAssertEqual(fallback.capabilities, router.capabilities)
        XCTAssertEqual(fallback.capabilities.maxContextTokens, 32_000)
        XCTAssertTrue(fallback.capabilities.supportsToolCalling)
        XCTAssertTrue(fallback.capabilities.supportsThinking)
    }

    // MARK: - Builder ergonomics

    func testWithFallbacksBuilder() async throws {
        let primary = loadedMock(); primary.tokensToYield = []; primary.shouldThrowInsideStream = retryable
        let secondary = loadedMock(tokens: ["builder-recovered"])

        let chain = primary.withFallbacks([secondary])
        let tokens = try await drain(chain)

        XCTAssertEqual(tokens, ["builder-recovered"])
        XCTAssertEqual(chain.backends.count, 2)
    }

    func testWithFallbacksFreeFunction() async throws {
        let primary = loadedMock(tokens: ["free-fn"])
        let secondary = loadedMock(tokens: ["unused"])

        let chain = withFallbacks([primary, secondary])
        let tokens = try await drain(chain)

        XCTAssertEqual(tokens, ["free-fn"])
        XCTAssertEqual(secondary.generateCallCount, 0)
    }
}
