import XCTest
import ManifoldInference

/// Unit tests for the ``MessagePart/toolCall`` and ``MessagePart/toolResult``
/// cases — Codable round-tripping, accessor behaviour, and `textContent`
/// exclusion.
///
/// These are pure value-type tests; see `SchemaV3ToV4MigrationTests` for
/// SwiftData integration coverage.
final class MessagePartToolCasesTests: XCTestCase {

    // MARK: - Codable round-trip

    func test_toolCall_codableRoundtrip() throws {
        let call = ToolCall(
            id: "call_abc123",
            toolName: "get_weather",
            arguments: #"{"city":"London"}"#
        )
        let part: MessagePart = .toolCall(call)

        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)

        XCTAssertEqual(decoded, [part],
            ".toolCall must survive Codable round-trip with all fields preserved")

        // Pin the wire-format discriminator so a silent rename (e.g. `.toolCall`
        // → `.tool_call`) would break old persisted rows and be caught by this
        // test rather than shipping to production.
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""toolCall""#),
            "Persisted JSON must use the literal key 'toolCall' — renaming the case silently migrates every store")
    }

    func test_toolResult_codableRoundtrip_success() throws {
        let result = ToolResult(
            callId: "call_abc123",
            content: #"{"temp":72}"#,
            isError: false
        )
        let part: MessagePart = .toolResult(result)

        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)

        XCTAssertEqual(decoded, [part])
    }

    func test_toolResult_codableRoundtrip_errorFlag() throws {
        // Agent A may later layer structured error kinds on top of isError; the
        // Bool remains the wire contract and must round-trip faithfully.
        let result = ToolResult(
            callId: "call_xyz",
            content: "timeout after 30s",
            isError: true
        )
        let part: MessagePart = .toolResult(result)

        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)

        XCTAssertEqual(decoded, [part])
        XCTAssertEqual(decoded.first?.toolResultContent?.isError, true)
    }

    // MARK: - Mixed array round-trip

    func test_allFiveCases_mixedArray_codableRoundtrip() throws {
        let parts: [MessagePart] = [
            .text("Let me check the weather."),
            .thinking("The user wants the current conditions."),
            .toolCall(ToolCall(id: "c1", toolName: "get_weather", arguments: #"{"city":"Paris"}"#)),
            .toolResult(ToolResult(callId: "c1", content: #"{"temp":18}"#, isError: false)),
            .image(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), mimeType: "image/jpeg"),
            .text("It's 18°C in Paris."),
        ]

        let data = try JSONEncoder().encode(parts)
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)

        XCTAssertEqual(decoded, parts,
            "Mixed array of all five MessagePart cases must round-trip intact, preserving order")
    }

    // MARK: - textContent exclusion

    func test_textContent_returnsNil_forToolCall() {
        let part: MessagePart = .toolCall(
            ToolCall(id: "c1", toolName: "t", arguments: "{}")
        )
        XCTAssertNil(part.textContent,
            ".textContent must be nil for .toolCall (consistent with .thinking and .image)")
    }

    func test_textContent_returnsNil_forToolResult() {
        let part: MessagePart = .toolResult(
            ToolResult(callId: "c1", content: "ok", isError: false)
        )
        XCTAssertNil(part.textContent,
            ".textContent must be nil for .toolResult")
    }

    // MARK: - Accessor computed properties

    func test_toolCallContent_returnsAssociatedValue() {
        let call = ToolCall(id: "c1", toolName: "echo", arguments: #"{"s":"hi"}"#)
        let part: MessagePart = .toolCall(call)

        XCTAssertEqual(part.toolCallContent, call)
        XCTAssertNil(part.toolResultContent)
    }

    func test_toolResultContent_returnsAssociatedValue() {
        let result = ToolResult(callId: "c1", content: "42", isError: false)
        let part: MessagePart = .toolResult(result)

        XCTAssertEqual(part.toolResultContent, result)
        XCTAssertNil(part.toolCallContent)
    }

    func test_accessors_returnNil_forOtherCases() {
        XCTAssertNil(MessagePart.text("x").toolCallContent)
        XCTAssertNil(MessagePart.text("x").toolResultContent)
        XCTAssertNil(MessagePart.thinking("x").toolCallContent)
        XCTAssertNil(MessagePart.thinking("x").toolResultContent)
        XCTAssertNil(MessagePart.image(data: Data(), mimeType: "image/png").toolCallContent)
        XCTAssertNil(MessagePart.image(data: Data(), mimeType: "image/png").toolResultContent)
    }
}
