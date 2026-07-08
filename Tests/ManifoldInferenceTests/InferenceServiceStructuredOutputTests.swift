import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for the typed `respond<T>()` structured-output round-trip and its
/// `StructuredOutputRouter` wiring in `GenerationQueue` (#1915).
@MainActor
final class InferenceServiceStructuredOutputTests: XCTestCase {

    // MARK: - Fixtures

    /// Hand-written conformance — no `@ToolSchema` macro required (Macros trait
    /// is off in default builds; the API must work without it).
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

    /// Capabilities for a backend with no constrained-decoding support — forces
    /// the router down to `.jsonPrompting`.
    private func weakCapabilities() -> BackendCapabilities {
        BackendCapabilities(
            supportsStructuredOutput: false,
            supportsGrammarConstrainedSampling: false,
            supportsGuidedStructuredOutput: false
        )
    }

    /// Tokenises a string into single-character fragments so the mock streams
    /// it like real token output rather than one blob.
    private func tokens(_ s: String) -> [String] { s.map { String($0) } }

    // MARK: - (a) Happy path

    func test_respond_decodesValidJSON_andPreservesRawText() async throws {
        let json = #"{"city":"Paris","celsius":21}"#
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        backend.tokensToYield = tokens(json)
        let service = InferenceService(backend: backend, name: "Mock")

        let result = try await service.respond(Weather.self, to: "Weather in Paris?")

        XCTAssertEqual(result.value, Weather(city: "Paris", celsius: 21))
        XCTAssertEqual(result.rawText, json)
    }

    func test_respond_extractsJSONFromSurroundingProse() async throws {
        // Weak backends append prose / code fences around the object on the
        // prompt-fallback path; respond must still decode.
        let wrapped = "Sure! Here you go:\n```json\n{\"city\":\"Oslo\",\"celsius\":3}\n```"
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        backend.tokensToYield = [wrapped]
        let service = InferenceService(backend: backend, name: "Mock")

        let result = try await service.respond(Weather.self, to: "Weather in Oslo?")

        XCTAssertEqual(result.value, Weather(city: "Oslo", celsius: 3))
    }

    // MARK: - (b) Router wiring — the previously-untested path

    func test_respond_invokesRouter_lowersSchemaToGrammar_onGrammarBackend() async throws {
        // A grammar-capable backend must end up with config.grammar set by the
        // router lowering, and structuredOutput cleared.
        let caps = BackendCapabilities(supportsGrammarConstrainedSampling: true)
        let backend = MockInferenceBackend(capabilities: caps)
        backend.isModelLoaded = true
        backend.tokensToYield = tokens(#"{"city":"Rome","celsius":30}"#)
        let service = InferenceService(backend: backend, name: "Mock")

        let result = try await service.respond(Weather.self, to: "Weather in Rome?")

        let config = try XCTUnwrap(backend.lastConfig, "generate() was not called")
        let hints = try XCTUnwrap(backend.lastHints, "generate() was not called")
        // Router selected GBNF: grammar lowered onto config, strategy hint cleared.
        XCTAssertNotNil(config.grammar, "router did not lower the schema to a GBNF grammar")
        XCTAssertNil(hints.structuredOutput, "grammar path should clear the strategy hint")
        XCTAssertEqual(result.strategy, .gbnf(try XCTUnwrap(config.grammar)))

        // Sabotage check (run manually before commit, then remove): breaking the
        // `StructuredOutputRouter.selectStrategy` call in GenerationQueue's
        // enqueue chokepoint (e.g. forcing the `.guided` arm) leaves
        // config.grammar nil here and fails this assertion — confirming the
        // test actually exercises the wiring. Verified failing, then restored.
    }

    func test_respond_routerSelectsJSONSchema_onStructuredOutputBackend() async throws {
        // A backend that supports json-schema but NOT grammar keeps the
        // .jsonSchema strategy on config for the downstream cloud encoder.
        let caps = BackendCapabilities(supportsStructuredOutput: true)
        let backend = MockInferenceBackend(capabilities: caps)
        backend.isModelLoaded = true
        backend.tokensToYield = tokens(#"{"city":"Bern","celsius":12}"#)
        let service = InferenceService(backend: backend, name: "Mock")

        let result = try await service.respond(Weather.self, to: "Weather in Bern?")

        let config = try XCTUnwrap(backend.lastConfig)
        let hints = try XCTUnwrap(backend.lastHints)
        XCTAssertNil(config.grammar, "non-grammar backend must not receive a grammar")
        guard case .jsonSchema = hints.structuredOutput else {
            return XCTFail("expected .jsonSchema strategy to remain on hints, got \(String(describing: hints.structuredOutput))")
        }
        guard case .jsonSchema = result.strategy else {
            return XCTFail("expected reported strategy .jsonSchema, got \(result.strategy)")
        }
    }

    // MARK: - (c) jsonPrompting fallback

    func test_respond_jsonPromptingFallback_injectsSchemaIntoSystemPrompt() async throws {
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        backend.tokensToYield = tokens(#"{"city":"Lima","celsius":18}"#)
        let service = InferenceService(backend: backend, name: "Mock")

        let result = try await service.respond(Weather.self, to: "Weather in Lima?")

        let systemPrompt = try XCTUnwrap(backend.lastSystemPrompt, "no system prompt was passed to the backend")
        XCTAssertTrue(
            systemPrompt.contains("JSON Schema"),
            "expected the schema instruction to be injected into the system prompt"
        )
        XCTAssertTrue(
            systemPrompt.contains(#""city""#),
            "expected the actual schema properties in the injected instruction"
        )
        XCTAssertEqual(result.strategy, .jsonPrompting)
        XCTAssertNil(backend.lastConfig?.grammar)
    }

    // MARK: - (d) Decode failure → typed error (precondition for #1916)

    func test_respond_decodeFailure_surfacesTypedError() async throws {
        let garbage = "this is not json at all"
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        backend.tokensToYield = [garbage]
        let service = InferenceService(backend: backend, name: "Mock")

        do {
            _ = try await service.respond(Weather.self, to: "Weather?")
            XCTFail("expected a decode failure")
        } catch let error as StructuredOutputError {
            guard case .decodeFailure(let rawText, let underlying) = error else {
                return XCTFail("expected .decodeFailure, got \(error)")
            }
            XCTAssertEqual(rawText, garbage, "raw text must be preserved for the reask loop (#1916)")
            XCTAssertFalse(underlying.isEmpty, "underlying decode error must be surfaced")
        }
    }

    // MARK: - (#1916) Bounded validation-reask loop

    /// JSON that is schema-valid but violates an enum constraint — exercises the
    /// validator-failure reask path (not just decode failures).
    private struct Unit: Decodable, Sendable, SchemaProviding, Equatable {
        let units: String

        static var jsonSchema: JSONSchemaValue {
            .object([
                "type": .string("object"),
                "properties": .object([
                    "units": .object([
                        "type": .string("string"),
                        "enum": .array([.string("metric"), .string("imperial")]),
                    ]),
                ]),
                "required": .array([.string("units")]),
            ])
        }
    }

    // (a) invalid attempt 1, valid attempt 2 → succeeds in exactly 2 generations.
    func test_reask_invalidThenValid_succeedsInTwoGenerations() async throws {
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        // Per-turn scripting: turn 1 = garbage (decode fails), turn 2 = valid.
        backend.tokensToYieldPerTurn = [
            ["not json"],
            tokens(#"{"city":"Paris","celsius":21}"#),
        ]
        let service = InferenceService(backend: backend, name: "Mock")

        let result = try await service.respond(
            Weather.self,
            to: "Weather in Paris?",
            reask: ReaskPolicy(maxAttempts: 2)
        )

        XCTAssertEqual(result.value, Weather(city: "Paris", celsius: 21))
        XCTAssertEqual(backend.generateCallCount, 2, "exactly two generations should have run (one reask)")
    }

    // (b) always-invalid → throws reaskBudgetExhausted after maxAttempts generations.
    func test_reask_alwaysInvalid_throwsBudgetExhausted() async throws {
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        backend.tokensToYield = ["never valid json"]
        let service = InferenceService(backend: backend, name: "Mock")

        do {
            _ = try await service.respond(
                Weather.self,
                to: "Weather?",
                reask: ReaskPolicy(maxAttempts: 3)
            )
            XCTFail("expected reaskBudgetExhausted")
        } catch let error as StructuredOutputError {
            guard case .reaskBudgetExhausted(let lastError, let attempts) = error else {
                return XCTFail("expected .reaskBudgetExhausted, got \(error)")
            }
            XCTAssertEqual(attempts, 3, "should report the full budget it burned")
            XCTAssertFalse(lastError.isEmpty, "must carry the last failure message")
        }
        XCTAssertEqual(backend.generateCallCount, 3, "should run exactly maxAttempts generations")
    }

    // (c) the reask follow-up prompt carries the ValidationFailure message.
    func test_reask_followUpPromptContainsValidationFailureMessage() async throws {
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        // Turn 1: enum-violating but otherwise schema-valid JSON. Turn 2: valid.
        backend.tokensToYieldPerTurn = [
            tokens(#"{"units":"celsius"}"#),
            tokens(#"{"units":"metric"}"#),
        ]
        let service = InferenceService(backend: backend, name: "Mock")

        _ = try await service.respond(
            Unit.self,
            to: "Pick units",
            reask: ReaskPolicy(maxAttempts: 2, includeRawOutput: true)
        )

        // The second generation's prompt (the assembled conversation) must
        // contain the validator's model-readable message about the enum.
        let lastPrompt = try XCTUnwrap(backend.lastPrompt, "no prompt reached the backend")
        XCTAssertTrue(
            lastPrompt.contains("must be one of: metric, imperial"),
            "reask follow-up should embed the validator failure message; got: \(lastPrompt)"
        )
        // includeRawOutput echoes the bad output back as an assistant turn.
        XCTAssertTrue(
            lastPrompt.contains("celsius"),
            "includeRawOutput should echo the bad output into the reask conversation"
        )
    }

    // (d) schema-valid-but-enum-violating JSON triggers reask via the validator
    // path (decode would succeed — only the validator catches it).
    func test_reask_schemaValidButEnumViolating_triggersReask() async throws {
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        backend.tokensToYieldPerTurn = [
            tokens(#"{"units":"kelvin"}"#),   // decodes fine, violates enum
            tokens(#"{"units":"imperial"}"#), // valid
        ]
        let service = InferenceService(backend: backend, name: "Mock")

        let result = try await service.respond(
            Unit.self,
            to: "Pick units",
            reask: ReaskPolicy(maxAttempts: 2)
        )

        XCTAssertEqual(result.value, Unit(units: "imperial"))
        XCTAssertEqual(backend.generateCallCount, 2, "validator failure must trigger a reask, not pass through")
    }

    // (e) maxAttempts:1 disables reask — a single failed attempt throws immediately
    // with no retry. Confirms the budget gate is live.
    func test_reask_maxAttemptsOne_throwsImmediatelyWithoutRetry() async throws {
        let backend = MockInferenceBackend(capabilities: weakCapabilities())
        backend.isModelLoaded = true
        backend.tokensToYield = ["not json"]
        let service = InferenceService(backend: backend, name: "Mock")

        do {
            _ = try await service.respond(
                Weather.self,
                to: "Weather?",
                reask: ReaskPolicy(maxAttempts: 1)
            )
            XCTFail("expected immediate failure")
        } catch let error as StructuredOutputError {
            guard case .reaskBudgetExhausted(_, let attempts) = error else {
                return XCTFail("expected .reaskBudgetExhausted, got \(error)")
            }
            XCTAssertEqual(attempts, 1)
        }
        XCTAssertEqual(backend.generateCallCount, 1, "maxAttempts:1 must not retry")
    }
}
