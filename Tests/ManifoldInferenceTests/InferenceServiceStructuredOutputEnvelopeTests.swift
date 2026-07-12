import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for ``InferenceService/structured(_:messages:config:policy:)`` — the
/// structured-output reliability envelope (#2205): retry/circuit-breaker
/// policy, stream-stall detection distinct from parse failure, and
/// empty-output classification so a grammar/JSON-mode call that streams zero
/// content never decodes into a silent, vacuous success.
@MainActor
final class InferenceServiceStructuredOutputEnvelopeTests: XCTestCase {

    // MARK: - Fixtures

    private struct Weather: Decodable, Sendable, SchemaProviding, Equatable {
        let city: String
        let celsius: Int

        static var jsonSchema: JSONSchemaValue {
            .object([
                "type": .string("object"),
                "properties": .object([
                    "city": .object(["type": .string("string")]),
                    "celsius": .object(["type": .string("integer")]),
                ]),
                "required": .array([.string("city"), .string("celsius")]),
            ])
        }
    }

    /// No constrained-decoding support — forces the router down to
    /// `.jsonPrompting`, matching how a real weak/local backend would route.
    private func weakCapabilities() -> BackendCapabilities {
        BackendCapabilities(
            supportsStructuredOutput: false,
            supportsGrammarConstrainedSampling: false,
            supportsGuidedStructuredOutput: false
        )
    }

    private func tokens(_ s: String) -> [String] { s.map { String($0) } }

    // MARK: - (a) Happy path

    func test_structured_happyPath_decodesValidJSON() async throws {
        let json = #"{"city":"Paris","celsius":21}"#
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        backend.tokensToYield = tokens(json)
        let service = InferenceService(backend: backend, name: "Mock")

        let result = try await service.structured(Weather.self, to: "Weather in Paris?")

        switch result {
        case .success(let output):
            XCTAssertEqual(output.value, Weather(city: "Paris", celsius: 21))
            XCTAssertEqual(output.rawText, json)
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
        XCTAssertEqual(backend.generateCallCount, 1, "the default policy must not retry a successful attempt")
    }

    // MARK: - (b) Retry then succeed

    func test_structured_retryThenSucceed_emptyOutputThenValid() async throws {
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        // Turn 1: streams nothing (empty output). Turn 2: valid JSON.
        backend.tokensToYieldPerTurn = [
            [],
            tokens(#"{"city":"Oslo","celsius":3}"#),
        ]
        let service = InferenceService(backend: backend, name: "Mock")

        let result = try await service.structured(
            Weather.self,
            to: "Weather in Oslo?",
            policy: StructuredOutputReliabilityPolicy(maxRetries: 1, retryDelay: .milliseconds(1))
        )

        switch result {
        case .success(let output):
            XCTAssertEqual(output.value, Weather(city: "Oslo", celsius: 3))
        case .failure(let error):
            XCTFail("expected success after retry, got \(error)")
        }
        XCTAssertEqual(backend.generateCallCount, 2, "exactly one retry should have run")

        // Sabotage check (run manually before commit, then remove): forcing
        // the empty-output guard to `continue` unconditionally instead of
        // proceeding to decode on non-empty text makes this loop forever /
        // never reach turn 2 — confirms the guard only fires on truly empty
        // text. Verified failing when the guard condition was inverted,
        // then restored.
    }

    // MARK: - (c) Retry exhausted — classified as unparsable

    func test_structured_retryExhausted_classifiesAsUnparsable() async throws {
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        backend.tokensToYield = ["never valid json"]
        let service = InferenceService(backend: backend, name: "Mock")

        let result = try await service.structured(
            Weather.self,
            to: "Weather?",
            policy: StructuredOutputReliabilityPolicy(maxRetries: 2, retryDelay: .milliseconds(1))
        )

        switch result {
        case .success:
            XCTFail("expected failure")
        case .failure(let error):
            guard case let .unparsable(rawText, underlying, attempts) = error else {
                return XCTFail("expected .unparsable, got \(error)")
            }
            XCTAssertEqual(rawText, "never valid json")
            XCTAssertFalse(underlying.isEmpty)
            XCTAssertEqual(attempts, 3, "should report the full attempt budget (1 + 2 retries)")
        }
        XCTAssertEqual(backend.generateCallCount, 3, "should run exactly maxRetries+1 generations")
    }

    // MARK: - (d) Stall → distinct timeout classification

    func test_structured_stall_classifiesAsTimeout_distinctFromParseFailure() async throws {
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        backend.tokensToYield = ["never", "arrives", "in", "time"]
        // Gate every token; never call advance(), so the stream produces no
        // events at all and the idle-timeout monitor is the only thing that
        // terminates the request. No `Task.sleep(nanoseconds: .max)` — the
        // gate suspends via a checked continuation with no timer of its own.
        let gate = TokenEmissionGate()
        backend.tokenEmissionGate = gate
        let service = InferenceService(backend: backend, name: "Mock")

        let result = try await service.structured(
            Weather.self,
            to: "Weather?",
            policy: StructuredOutputReliabilityPolicy(stallTimeout: .milliseconds(80))
        )

        switch result {
        case .success:
            XCTFail("expected a stall timeout, not success")
        case .failure(let error):
            guard case let .stalled(elapsed, attempts) = error else {
                return XCTFail("expected .stalled (distinct from .unparsable), got \(error)")
            }
            XCTAssertEqual(elapsed, .milliseconds(80))
            XCTAssertEqual(attempts, 1)
        }

        // Release the gate so the backend's still-suspended generation task
        // can finish and doesn't leak past the test.
        await gate.release()

        // Sabotage check (run manually before commit, then remove): swapping
        // the `catch InferenceError.idleTimeout` arm to fall into the
        // generic `catch { throw error }` arm makes this test fail with an
        // uncaught idleTimeout error instead of a classified `.stalled`
        // result — confirms the classification is actually wired, not just
        // coincidentally matching. Verified failing, then restored.
    }

    // MARK: - (e) Empty output → failure, never a silent success

    func test_structured_emptyOutput_classifiedAsFailure_notSilentSuccess() async throws {
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        backend.tokensToYield = [] // streams zero content tokens
        let service = InferenceService(backend: backend, name: "Mock")

        let result = try await service.structured(Weather.self, to: "Weather?")

        switch result {
        case .success(let output):
            XCTFail("empty stream must never decode into a silent success; got \(output)")
        case .failure(let error):
            guard case let .emptyOutput(attempts) = error else {
                return XCTFail("expected .emptyOutput, got \(error)")
            }
            XCTAssertEqual(attempts, 1, "default policy runs exactly one attempt")
        }
        XCTAssertEqual(backend.generateCallCount, 1, "default policy (maxRetries: 0) must not retry")
    }

    func test_structured_emptyOutput_whitespaceOnlyIsAlsoClassifiedAsEmpty() async throws {
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        backend.tokensToYield = ["   ", "\n"]
        let service = InferenceService(backend: backend, name: "Mock")

        let result = try await service.structured(Weather.self, to: "Weather?")

        guard case .failure(.emptyOutput) = result else {
            return XCTFail("expected .emptyOutput for whitespace-only content, got \(result)")
        }
    }

    // MARK: - (f) Cancellation is a distinct classification

    func test_structured_cancellation_classifiedAsCancelled() async throws {
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        // First attempt streams empty output almost instantly, so the task
        // reliably lands inside the retry-delay sleep (which responds
        // immediately to cancellation) by the time we cancel it.
        backend.tokensToYield = []
        let service = InferenceService(backend: backend, name: "Mock")

        let task = Task {
            try await service.structured(
                Weather.self,
                to: "Weather?",
                policy: StructuredOutputReliabilityPolicy(maxRetries: 1, retryDelay: .seconds(5))
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()

        let result = try await task.value
        guard case .failure(.cancelled) = result else {
            return XCTFail("expected .cancelled, got \(result)")
        }
    }
}
