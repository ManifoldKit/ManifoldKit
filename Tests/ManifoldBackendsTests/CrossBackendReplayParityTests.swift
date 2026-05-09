#if CloudSaaS || Ollama
import XCTest
import Foundation
@testable import ManifoldBackends
@testable import ManifoldCloud
@testable import ManifoldInference

/// Proves that captured real-vendor JSON fixtures each decode through their
/// backend's parser into an equivalent ``ToolCall`` shape.
///
/// The fixture files in `Fixtures/ToolCallReplay/` are minimal-but-realistic
/// single-call payloads for OpenAI Chat Completions, Anthropic Messages API,
/// and Ollama `/api/chat`. Each test decodes one fixture through the smallest
/// available entry point on the relevant backend and asserts:
///
/// - `toolName == "get_weather"`
/// - `arguments` JSON object contains `"city": "Dublin"` (normalised via
///   JSON round-trip before comparing so key order is irrelevant)
///
/// This pins the cross-backend wire-format alignment at the parser level,
/// not just at the mock level — any vendor schema change that silently breaks
/// a parser will surface here before it breaks a live integration.
///
/// ## Sabotage check
/// For the OpenAI fixture test: change the fixture's `"name"` field to
/// `"get_weather_wrong"`, confirm `XCTAssertEqual(call.toolName, "get_weather")`
/// fails. Remove the change before committing.
final class CrossBackendReplayParityTests: XCTestCase {

    // MARK: - Fixture loading

    private func fixtureURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ToolCallReplay/\(name)")
    }

    private func loadFixture(named name: String) throws -> String {
        let url = fixtureURL(named: name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Argument normalisation

    /// Parses a JSON arguments string into a `[String: String]` dictionary
    /// so cross-backend comparisons are insensitive to key order.
    private func parseArgs(_ arguments: String) throws -> [String: String] {
        let data = try XCTUnwrap(arguments.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return obj.compactMapValues { $0 as? String }
    }

    // MARK: - OpenAI fixture replay

    /// Decodes `openai_tool_call.json` through ``OpenAIBackend/parseWholeToolCalls(from:)``
    /// and asserts the resulting call matches the expected shape.
    ///
    /// Sabotage: change fixture 'name' to 'get_weather_wrong', confirm XCTAssertEqual on name fails.
#if CloudSaaS
    func test_openai_fixtureReplay_producesExpectedToolCall() throws {
        let json = try loadFixture(named: "openai_tool_call.json")

        let calls = OpenAIBackend.parseWholeToolCalls(from: json)

        XCTAssertEqual(calls.count, 1, "expected exactly one tool call in OpenAI fixture")
        let call = try XCTUnwrap(calls.first)

        XCTAssertEqual(call.name, "get_weather")
        XCTAssertEqual(call.id, "call_abc")

        let args = try parseArgs(call.arguments)
        XCTAssertEqual(args["city"], "Dublin", "arguments must contain city=Dublin")
    }
#endif

    // MARK: - Anthropic fixture replay

    /// Decodes `anthropic_tool_use.json` through
    /// ``ClaudeBackend/parseWholeMessageToolUseBlocks(from:)`` and asserts
    /// the resulting block matches the expected shape.
#if CloudSaaS
    func test_anthropic_fixtureReplay_producesExpectedToolCall() throws {
        let json = try loadFixture(named: "anthropic_tool_use.json")

        let blocks = try XCTUnwrap(ClaudeBackend.parseWholeMessageToolUseBlocks(from: json))

        XCTAssertEqual(blocks.count, 1, "expected exactly one tool_use block in Anthropic fixture")
        let block = try XCTUnwrap(blocks.first)

        XCTAssertEqual(block.name, "get_weather")
        XCTAssertEqual(block.id, "toolu_abc")

        let args = try parseArgs(block.serializedInput)
        XCTAssertEqual(args["city"], "Dublin", "serializedInput must contain city=Dublin")
    }
#endif

    // MARK: - Ollama fixture replay

    /// Decodes `ollama_tool_call.json` through ``OllamaBackend/parseLine(_:)``
    /// and asserts the resulting ``ToolCall`` matches the expected shape.
#if Ollama
    func test_ollama_fixtureReplay_producesExpectedToolCall() throws {
        let json = try loadFixture(named: "ollama_tool_call.json")

        let parsed = try XCTUnwrap(OllamaPayloadParser.parseLine(json), "parseLine returned nil for valid fixture")

        let toolCalls = try XCTUnwrap(parsed.toolCalls, "expected non-nil toolCalls in parsed line")
        XCTAssertEqual(toolCalls.count, 1, "expected exactly one tool call in Ollama fixture")
        let call = try XCTUnwrap(toolCalls.first)

        XCTAssertEqual(call.toolName, "get_weather")
        XCTAssertFalse(call.id.isEmpty, "synthesised id must be non-empty")

        let args = try parseArgs(call.arguments)
        XCTAssertEqual(args["city"], "Dublin", "arguments must contain city=Dublin")
    }
#endif

    // MARK: - Cross-backend parity gate

    /// Loads all three fixtures and confirms each parser returns the same
    /// normalised argument shape. Only executes when all three backend
    /// symbols are available; under `--disable-default-traits` both
    /// `CloudSaaS` and `Ollama` compile into the test binary so this runs
    /// in CI without any hardware.
    ///
    /// This is the cross-cutting assertion: different wire formats from
    /// three vendors must all resolve to `["city": "Dublin"]`.
#if CloudSaaS && Ollama
    func test_allVendors_argumentParity_cityDublin() throws {
        // OpenAI
        let openAIJson = try loadFixture(named: "openai_tool_call.json")
        let openAICalls = OpenAIBackend.parseWholeToolCalls(from: openAIJson)
        let openAIArgs = try parseArgs(try XCTUnwrap(openAICalls.first).arguments)

        // Anthropic
        let anthropicJson = try loadFixture(named: "anthropic_tool_use.json")
        let anthropicBlocks = try XCTUnwrap(ClaudeBackend.parseWholeMessageToolUseBlocks(from: anthropicJson))
        let anthropicArgs = try parseArgs(try XCTUnwrap(anthropicBlocks.first).serializedInput)

        // Ollama
        let ollamaJson = try loadFixture(named: "ollama_tool_call.json")
        let ollamaParsed = try XCTUnwrap(OllamaPayloadParser.parseLine(ollamaJson))
        let ollamaCall = try XCTUnwrap(ollamaParsed.toolCalls?.first)
        let ollamaArgs = try parseArgs(ollamaCall.arguments)

        // All three must agree on the argument payload.
        XCTAssertEqual(openAIArgs, anthropicArgs,
                       "OpenAI and Anthropic parsers must produce equivalent argument dictionaries")
        XCTAssertEqual(anthropicArgs, ollamaArgs,
                       "Anthropic and Ollama parsers must produce equivalent argument dictionaries")

        // Spot-check the key value so a wrong fixture doesn't sneak through
        // as "all equal" (e.g. all empty).
        XCTAssertEqual(openAIArgs["city"], "Dublin")
    }
#endif
}
#endif
