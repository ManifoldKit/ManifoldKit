import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Verifies that ``GenerationQueue`` derives a tool-call GBNF grammar from
/// `config.tools` (#1859) for grammar-capable backends, and that the rules
/// around explicit caller grammars and the capability flag are honored.
@MainActor
final class EnqueueToolGrammarWiringTests: XCTestCase {

    private func tool(_ name: String) -> ToolDefinition {
        ToolDefinition(name: name, description: "d", parameters: .object([:]))
    }

    private func makeBackend(grammar: Bool) -> MockInferenceBackend {
        let backend = MockInferenceBackend(capabilities: BackendCapabilities(
            supportsToolCalling: true,
            supportsGrammarConstrainedSampling: grammar
        ))
        backend.isModelLoaded = true
        backend.tokensToYield = ["x"]
        return backend
    }

    func test_grammarCapableBackend_withTools_derivesToolGrammar() async throws {
        let backend = makeBackend(grammar: true)
        let service = InferenceService(backend: backend, name: "Mock")

        let (_, stream) = try service.enqueue(
            messages: [("user", "hi")],
            tools: [tool("get_weather"), tool("get_time")]
        )
        for try await _ in stream.events {}

        let grammar = try XCTUnwrap(backend.lastConfig?.grammar)
        // Default toolChoice is .auto → the queue injects the permissive grammar
        // (#1961), not the strict union.
        let expected = try XCTUnwrap(
            ToolGrammarBuilder().buildGrammar(
                for: [tool("get_weather"), tool("get_time")],
                mode: .permissive
            )
        )
        XCTAssertEqual(grammar, expected, "queue must assign the ToolGrammarBuilder output")
        XCTAssertTrue(grammar.contains("\\\"get_weather\\\""))
        XCTAssertTrue(grammar.contains("\\\"get_time\\\""))
    }

    // MARK: - toolChoice-aware injection (#1961)

    func test_autoToolChoice_injectsProsePermissiveGrammar() async throws {
        let backend = makeBackend(grammar: true)
        let service = InferenceService(backend: backend, name: "Mock")

        let (_, stream) = try service.enqueue(
            messages: [("user", "hi")],
            tools: [tool("a"), tool("b")],
            toolChoice: .auto
        )
        for try await _ in stream.events {}

        let grammar = try XCTUnwrap(backend.lastConfig?.grammar)
        // Regression for manifold-llama#55: a multi-tool .auto config must not
        // force an immediate stop — the prose escape keeps the first token free.
        XCTAssertTrue(grammar.contains("| prose"), "auto must admit a prose alternative")
        XCTAssertTrue(grammar.contains("prose-head ::= [^{]"))
    }

    func test_requiredToolChoice_injectsStrictGrammar() async throws {
        let backend = makeBackend(grammar: true)
        let service = InferenceService(backend: backend, name: "Mock")

        let (_, stream) = try service.enqueue(
            messages: [("user", "hi")],
            tools: [tool("a"), tool("b")],
            toolChoice: .required
        )
        for try await _ in stream.events {}

        let grammar = try XCTUnwrap(backend.lastConfig?.grammar)
        XCTAssertFalse(grammar.contains("prose"), "required must preserve the forced-call union")
    }

    func test_namedToolChoice_injectsSingleToolGrammar() async throws {
        let backend = makeBackend(grammar: true)
        let service = InferenceService(backend: backend, name: "Mock")

        let (_, stream) = try service.enqueue(
            messages: [("user", "hi")],
            tools: [tool("a"), tool("b"), tool("c")],
            toolChoice: .tool(name: "b")
        )
        for try await _ in stream.events {}

        let grammar = try XCTUnwrap(backend.lastConfig?.grammar)
        let rootLine = grammar.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertEqual(rootLine, "root ::= toolcall-0", "named tool → exactly one branch")
        XCTAssertTrue(grammar.contains("\\\"b\\\""))
    }

    func test_noneToolChoice_injectsNoGrammar() async throws {
        let backend = makeBackend(grammar: true)
        let service = InferenceService(backend: backend, name: "Mock")

        let (_, stream) = try service.enqueue(
            messages: [("user", "hi")],
            tools: [tool("a")],
            toolChoice: .none
        )
        for try await _ in stream.events {}

        XCTAssertNil(backend.lastConfig?.grammar, ".none must not inject a tool-call grammar")
    }

    func test_nonGrammarBackend_withTools_leavesGrammarNil() async throws {
        let backend = makeBackend(grammar: false)
        let service = InferenceService(backend: backend, name: "Mock")

        let (_, stream) = try service.enqueue(
            messages: [("user", "hi")],
            tools: [tool("get_weather")]
        )
        for try await _ in stream.events {}

        XCTAssertNil(backend.lastConfig?.grammar, "no grammar capability → no derived grammar")
    }

    func test_explicitCallerGrammar_isPreserved() async throws {
        let backend = makeBackend(grammar: true)
        let service = InferenceService(backend: backend, name: "Mock")

        let caller = "root ::= \"x\""
        let (_, stream) = try service.enqueue(
            messages: [("user", "hi")],
            grammar: caller,
            tools: [tool("get_weather")]
        )
        for try await _ in stream.events {}

        XCTAssertEqual(
            backend.lastConfig?.grammar,
            caller,
            "an explicit caller grammar must always win over the derived tool grammar"
        )
    }

    func test_grammarCapableBackend_noTools_leavesGrammarNil() async throws {
        let backend = makeBackend(grammar: true)
        let service = InferenceService(backend: backend, name: "Mock")

        let (_, stream) = try service.enqueue(messages: [("user", "hi")])
        for try await _ in stream.events {}

        XCTAssertNil(backend.lastConfig?.grammar, "no tools → nothing to constrain")
    }
}
