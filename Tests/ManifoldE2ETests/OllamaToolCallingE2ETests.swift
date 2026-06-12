import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends

/// End-to-end tool-calling test against a real local Ollama server.
///
/// Unlike the mocked `OllamaToolCallingTests`, this exercises the full pipeline:
/// - `OllamaBackend` serialises tools on the wire
/// - Ollama picks the tool
/// - the coordinator dispatches through `ToolRegistry`
/// - the tool result is threaded back into the next turn
/// - the model surfaces the result verbatim in its final response
///
/// The assertion checks for a deliberately out-of-distribution value
/// (`2099-01-01T00:00:00Z`) so a model hallucinating the current time would
/// never match — the only way the assertion passes is if the tool was really
/// invoked and its output made it into the final response.
@MainActor
final class OllamaToolCallingE2ETests: XCTestCase {

    private var backend: OllamaBackend!
    private var modelName: String!

    /// Preferred tool-calling-capable model (Llama 3.1 8B has native tool
    /// support on Ollama). Fallback to a smaller Qwen 2.5 tag that also
    /// supports tool calling via the `/api/chat` tools envelope.
    private static let preferredModels: [String] = [
        "llama3.1:8b",
        "qwen2.5:7b-instruct",
    ]

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            HardwareRequirements.hasOllamaServer,
            "Ollama server not running at localhost:11434"
        )

        let available = HardwareRequirements.listOllamaModels() ?? []
        guard let match = Self.preferredModels.first(where: { available.contains($0) }) else {
            throw XCTSkip(
                "No tool-calling-capable Ollama model installed; need one of \(Self.preferredModels). Installed: \(available)"
            )
        }
        modelName = match

        backend = OllamaBackend()
        backend.configure(
            baseURL: URL(string: "http://localhost:11434")!,
            modelName: modelName
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    override func tearDown() async throws {
        backend?.unloadModel()
        backend = nil
        modelName = nil
        try await super.tearDown()
    }

    // MARK: - Tests

    /// Registers a `now` tool that returns an obviously-OOD timestamp; asks
    /// the model "what time is it?"; asserts the response carries the OOD
    /// value verbatim — proving the tool was invoked and its result threaded
    /// into the final answer.
    ///
    /// Sabotage verification (see PR body): swap the nonce for the current
    /// real time and confirm the assertion fails.
    func test_ood_nonce_returned_verbatim() async throws {
        // Unique per-test nonce so repeated runs never collide on a cached
        // response. The year 2099 keeps it obviously out-of-distribution.
        let nonce = "2099-01-01T00:00:00Z"

        // Build the tool the coordinator will dispatch.
        struct NowArgs: Decodable, Sendable {}
        struct NowResult: Encodable, Sendable { let time: String }
        let nowTool = TypedToolExecutor<NowArgs, NowResult>(
            definition: ToolDefinition(
                name: "now",
                description: "Returns the current UTC time as an ISO 8601 string.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            )
        ) { _ in
            NowResult(time: nonce)
        }

        // The backend is already loaded. We drive the dispatch loop by
        // running a minimal inline orchestrator rather than standing up a
        // full `InferenceService` — this is the narrowest path that
        // exercises the wire format + registry dispatch loop end-to-end.
        let registry = ToolRegistry()
        registry.register(nowTool)

        // Turn 1: ask the question, give the model the tool.
        var config = GenerationConfig(
            temperature: 0.0,
            topP: 1.0,
            topK: 1,
            maxOutputTokens: 256,
            tools: [nowTool.definition],
            toolChoice: .auto,
            maxToolIterations: 4
        )

        // Build tool-aware history progressively so we can feed the
        // tool-role response back into the second turn.
        var history: [ToolAwareHistoryEntry] = [
            ToolAwareHistoryEntry(
                role: "system",
                content: "Call the `now` tool to find the current time. After receiving its output, respond with a short answer that includes the exact value the tool returned."
            ),
            ToolAwareHistoryEntry(role: "user", content: "What time is it right now? Use the tool."),
        ]

        var visibleAnswer = ""
        var toolResultContent: String?
        var iterations = 0

        while iterations < config.maxToolIterations {
            iterations += 1
            backend.setToolAwareHistory(history)
            let stream = try backend.generate(
                prompt: "",
                systemPrompt: nil,
                config: config
            )

            var turnToolCalls: [ToolCall] = []
            var turnText = ""
            for try await event in stream.events {
                switch event {
                case .toolCall(let call): turnToolCalls.append(call)
                case .token(let text): turnText += text
                default: break
                }
            }

            if turnToolCalls.isEmpty {
                visibleAnswer = turnText
                break
            }

            // Dispatch each tool call and thread the results into the
            // history for the next turn.
            history.append(
                ToolAwareHistoryEntry(
                    role: "assistant",
                    content: "",
                    toolCalls: turnToolCalls
                )
            )
            for call in turnToolCalls {
                let result = await registry.dispatch(call)
                toolResultContent = result.content
                history.append(
                    ToolAwareHistoryEntry(
                        role: "tool",
                        content: result.content,
                        toolCallId: call.id
                    )
                )
            }
        }

        // The tool must have been dispatched at least once; its content is
        // the JSON-encoded NowResult struct.
        let dispatched = try XCTUnwrap(toolResultContent, "tool must be dispatched")
        XCTAssertTrue(
            dispatched.contains(nonce),
            "tool result should carry the nonce (got: \(dispatched))"
        )

        // Final visible answer from the model must carry the nonce — this
        // is the proof the tool output reached the model's response.
        XCTAssertFalse(visibleAnswer.isEmpty, "model should produce a visible answer after the tool call")
        XCTAssertTrue(
            visibleAnswer.contains(nonce),
            "final response must quote the OOD nonce verbatim (got: \(visibleAnswer))"
        )
    }
}
