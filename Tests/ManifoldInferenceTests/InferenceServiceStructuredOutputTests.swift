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
        // Router selected GBNF: grammar lowered onto config, strategy hint cleared.
        XCTAssertNotNil(config.grammar, "router did not lower the schema to a GBNF grammar")
        XCTAssertNil(config.structuredOutput, "grammar path should clear the strategy hint")
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
        XCTAssertNil(config.grammar, "non-grammar backend must not receive a grammar")
        guard case .jsonSchema = config.structuredOutput else {
            return XCTFail("expected .jsonSchema strategy to remain on config, got \(String(describing: config.structuredOutput))")
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
}
