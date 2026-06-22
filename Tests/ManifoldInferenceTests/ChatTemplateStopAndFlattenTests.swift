import XCTest
@testable import ManifoldInference

/// Regression + policy tests for #1944's flatten() tool-drop fix, the stop-
/// sequence merge policy, and `GenerationConfig.stopSequences` Codable
/// back-compat.
final class ChatTemplateStopAndFlattenTests: XCTestCase {

    // MARK: - flatten-residual tool-drop regression (#1944)

    /// A templateless model (`chatTemplateRaw == nil`) carrying a `.toolResult`
    /// part must render that tool content into the fallback prompt. Before the
    /// fix the fallback used `flatten()`, which dropped tool parts entirely.
    func test_enumFallback_rendersToolResultContent() throws {
        let toolResult = ToolResult(callId: "call_1", content: "The weather is 21C and sunny.")
        let messages: [StructuredMessage] = [
            StructuredMessage(role: "user", content: "What's the weather?"),
            StructuredMessage(role: "assistant", parts: [
                .toolCall(ToolCall(id: "call_1", toolName: "get_weather", arguments: "{\"city\":\"Dublin\"}")),
            ]),
            StructuredMessage(role: "tool", parts: [.toolResult(toolResult)]),
        ]

        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: nil)
        let prompt = try renderer.render(messages: messages, systemPrompt: nil, tools: [])

        // The tool result content must survive into the prompt (regression).
        XCTAssertTrue(
            prompt.contains("The weather is 21C and sunny."),
            "Tool result content must reach the enum-fallback prompt (#1944); got:\n\(prompt)"
        )
        // And the tool call name should also be present.
        XCTAssertTrue(
            prompt.contains("get_weather"),
            "Tool call name should reach the prompt; got:\n\(prompt)"
        )
    }

    /// Direct unit check of the projection that backs the fix: tool parts fold
    /// into the textual content rather than disappearing, and the callId is
    /// included so parallel results can be paired to their originating calls.
    func test_toolAwareProjection_foldsToolParts() {
        let messages: [StructuredMessage] = [
            StructuredMessage(role: "tool", parts: [
                .toolResult(ToolResult(callId: "c", content: "RESULT-TEXT")),
            ]),
        ]
        let projected = GenerationHistoryInstaller.toolAwareProjection(messages)
        XCTAssertEqual(projected.count, 1)
        XCTAssertTrue(projected[0].content.contains("RESULT-TEXT"))
        // The callId must be present so the model can pair the result to its call.
        XCTAssertTrue(projected[0].content.contains("(c)"), "callId must appear in projected content")

        // Sabotage-counterpart: the legacy flatten() drops it (proves the two
        // projections genuinely differ on tool parts — the bug was using this).
        let flattened = GenerationHistoryInstaller.flatten(messages)
        XCTAssertFalse(
            flattened[0].content.contains("RESULT-TEXT"),
            "flatten() is the lossy string-only seam; it must still drop tool parts"
        )
    }

    /// Parallel tool results must each carry their callId so the model can pair
    /// each result back to the originating call. Without the id, N bare result
    /// lines give the model no way to match result→call when multiple tool calls
    /// were issued on the same assistant turn.
    func test_toolAwareProjection_includesCallIdInResult() {
        let messages: [StructuredMessage] = [
            StructuredMessage(role: "tool", parts: [
                .toolResult(ToolResult(callId: "call_weather", content: "18C and sunny")),
                .toolResult(ToolResult(callId: "call_stocks", content: "AAPL 203.45")),
            ]),
        ]
        let projected = GenerationHistoryInstaller.toolAwareProjection(messages)
        XCTAssertEqual(projected.count, 1)

        let content = projected[0].content
        // Both callIds must appear so results are pairable to their calls.
        XCTAssertTrue(content.contains("(call_weather)"), "first callId must be present")
        XCTAssertTrue(content.contains("(call_stocks)"), "second callId must be present")
        // Content values survive.
        XCTAssertTrue(content.contains("18C and sunny"), "first result content must be present")
        XCTAssertTrue(content.contains("AAPL 203.45"), "second result content must be present")

        // Sabotage: without the fix the ids would be absent; calling flatten()
        // confirms the lossy baseline still drops everything, making it a valid
        // discriminant for the toolAwareProjection assertions above.
        let flattened = GenerationHistoryInstaller.flatten(messages)
        XCTAssertFalse(
            flattened[0].content.contains("call_weather"),
            "flatten() drops tool parts — proving callId presence above is genuine"
        )
    }

    /// Error results must use the `[tool_error]` prefix so the model knows the
    /// tool invocation failed — and must still include the callId for pairing.
    func test_toolAwareProjection_errorResultUsesErrorPrefix() {
        let messages: [StructuredMessage] = [
            StructuredMessage(role: "tool", parts: [
                .toolResult(ToolResult(callId: "call_fail", content: "timeout", errorKind: .timeout)),
            ]),
        ]
        let projected = GenerationHistoryInstaller.toolAwareProjection(messages)
        let content = projected[0].content
        XCTAssertTrue(content.contains("[tool_error]"), "error results must use [tool_error] prefix")
        XCTAssertTrue(content.contains("(call_fail)"), "error result must still carry callId for pairing")
        XCTAssertFalse(content.contains("[tool_result]"), "error must NOT use success prefix")
    }

    // MARK: - stop-sequence merge policy

    @MainActor
    func test_mergePolicy_callerOverridesTemplateDefault() {
        let queue = GenerationQueue()
        queue.selectedPromptTemplateProvider = { .chatML }
        // chatML's template default is ["<|im_end|>"].
        var config = GenerationConfig()
        config.stopSequences = ["CUSTOM_STOP"]
        let merged = queue.applyingTemplateStopSequences(to: config)
        XCTAssertEqual(merged.stopSequences, ["CUSTOM_STOP"], "Caller-supplied stops win outright")
    }

    @MainActor
    func test_mergePolicy_emptyInheritsTemplateDefault() {
        let queue = GenerationQueue()
        queue.selectedPromptTemplateProvider = { .llama3 }
        var config = GenerationConfig()
        config.stopSequences = []
        let merged = queue.applyingTemplateStopSequences(to: config)
        XCTAssertEqual(merged.stopSequences, ["<|eot_id|>"], "Empty stops inherit the template default")
    }

    @MainActor
    func test_mergePolicy_embeddedJinjaNoDefault_leavesEmpty() {
        let queue = GenerationQueue()
        queue.selectedPromptTemplateProvider = { .chatML }
        queue.selectedChatTemplateRawProvider = { "{% for m in messages %}{{ m }}{% endfor %}" }
        var config = GenerationConfig()
        config.stopSequences = []
        let merged = queue.applyingTemplateStopSequences(to: config)
        XCTAssertEqual(merged.stopSequences, [], "Embedded-Jinja has no derived default; stays empty")
    }

    // MARK: - GenerationConfig.stopSequences Codable back-compat

    func test_codable_roundTrip_withStopSequences() throws {
        var config = GenerationConfig()
        config.stopSequences = ["<|im_end|>", "STOP"]
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)
        XCTAssertEqual(decoded.stopSequences, ["<|im_end|>", "STOP"])
    }

    func test_codable_roundTrip_emptyStopSequences_omitsKeyButDecodesEmpty() throws {
        let config = GenerationConfig() // empty stopSequences
        let data = try JSONEncoder().encode(config)
        // Empty list is omitted from the payload (preserves prior shape).
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("stopSequences"), "Empty stopSequences must be omitted from the payload")
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)
        XCTAssertEqual(decoded.stopSequences, [])
    }

    func test_codable_decodeOldJSON_lackingStopSequencesKey() throws {
        // Simulate an old persisted payload that pre-dates the key: encode a
        // config (empty stopSequences are already omitted) and strip any
        // stopSequences key to be certain none is present, then decode.
        let original = GenerationConfig()
        let data = try JSONEncoder().encode(original)
        var dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        dict.removeValue(forKey: "stopSequences")
        XCTAssertNil(dict["stopSequences"], "Fixture must lack the key")
        let strippedData = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: strippedData)
        XCTAssertEqual(decoded.stopSequences, [], "Missing key decodes to empty (back-compat)")
    }
}
