import XCTest
@testable import ManifoldTools
import ManifoldInference

/// Unit coverage for ``BFCLRunRecord`` — the capture record that lets a live BFCL
/// run be cross-checked against canonical `bfcl-eval` offline. The cross-check is
/// only trustworthy if the record faithfully preserves the decoded calls and the
/// scores we computed, so these assert exact decoding and a stable wire shape.
final class BFCLDumpTests: XCTestCase {

    private func call(_ name: String, _ argsJSON: String) -> ToolCall {
        ToolCall(id: "c1", toolName: name, arguments: argsJSON)
    }

    // MARK: - parseArgs

    func test_parseArgs_decodesJSONObject_preservingTypes() {
        let value = BFCLRunRecord.parseArgs(#"{"a":5,"b":"x","c":1.5,"d":true}"#)
        XCTAssertEqual(value, .object([
            "a": .integer(5),
            "b": .string("x"),
            "c": .number(1.5),
            "d": .bool(true),
        ]))
    }

    func test_parseArgs_nonObjectPayload_fallsBackToRawString() {
        // A bare array is valid JSON but not an argument object — preserve it raw
        // so the cross-check sees exactly what we scored, not a silent drop.
        XCTAssertEqual(BFCLRunRecord.parseArgs("[1,2,3]"), .string("[1,2,3]"))
    }

    func test_parseArgs_unparseablePayload_fallsBackToRawString() {
        XCTAssertEqual(BFCLRunRecord.parseArgs("not json at all"), .string("not json at all"))
    }

    // MARK: - make

    func test_make_capturesDecodedCallsAndScores() {
        let record = BFCLRunRecord.make(
            id: "multiple_0",
            model: "ollama/llama3.1-8b",
            emittedCalls: [call("add", #"{"a":17,"b":4}"#)],
            astMatched: true,
            nameMatched: true
        )
        XCTAssertEqual(record.id, "multiple_0")
        XCTAssertEqual(record.model, "ollama/llama3.1-8b")
        XCTAssertEqual(record.decoded, [
            .init(name: "add", args: .object(["a": .integer(17), "b": .integer(4)])),
        ])
        XCTAssertTrue(record.astMatched)
        XCTAssertTrue(record.nameMatched)
    }

    func test_make_emptyCalls_yieldsEmptyDecoded() {
        let record = BFCLRunRecord.make(
            id: "multiple_1", model: "m", emittedCalls: [], astMatched: false, nameMatched: false
        )
        XCTAssertTrue(record.decoded.isEmpty)
        XCTAssertFalse(record.astMatched)
        XCTAssertFalse(record.nameMatched)
    }

    // MARK: - jsonLine wire shape

    func test_jsonLine_emitsSnakeCaseKeysAndRoundTrips() throws {
        let record = BFCLRunRecord.make(
            id: "multiple_5",
            model: "ollama/qwen3.5-9b",
            emittedCalls: [call("triangle_properties.get", #"{"sides":[3,4,5]}"#)],
            astMatched: false,
            nameMatched: true
        )
        let line = try record.jsonLine()

        // Single line (JSONL invariant) with snake_case score keys.
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.contains("\"ast_matched\":false"))
        XCTAssertTrue(line.contains("\"name_matched\":true"))

        // Round-trips back to the same logical content via a generic decode.
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["id"] as? String, "multiple_5")
        XCTAssertEqual(obj?["ast_matched"] as? Bool, false)
        let decoded = obj?["decoded"] as? [[String: Any]]
        XCTAssertEqual(decoded?.first?["name"] as? String, "triangle_properties.get")
    }
}
