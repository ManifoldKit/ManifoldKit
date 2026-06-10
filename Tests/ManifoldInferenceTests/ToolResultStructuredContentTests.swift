import XCTest
@testable import ManifoldInference

/// Tests for the ``ToolResult/structuredContent`` sidecar and the
/// ``ToolResultPart`` vocabulary introduced as P2.5a future-proofing.
///
/// Classification: Unit — no I/O, no SwiftData, no actor hops.
final class ToolResultStructuredContentTests: XCTestCase {

    // MARK: - ToolResultPart round-trips

    func test_textPart_roundTrips() throws {
        let part = ToolResultPart.text("Sunny, 22°C")

        let encoded = try JSONEncoder().encode(part)
        let decoded = try JSONDecoder().decode(ToolResultPart.self, from: encoded)

        // Sabotage check: removing the "text" case from ToolResultPart.init(from:)
        // would decode into .unknown(type: "text") and fail XCTAssertEqual.
        XCTAssertEqual(decoded, .text("Sunny, 22°C"))
    }

    func test_textPart_encodesWithTypeDiscriminator() throws {
        let part = ToolResultPart.text("hello")
        let encoded = try JSONEncoder().encode(part)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(obj["type"] as? String, "text")
        XCTAssertEqual(obj["text"] as? String, "hello")
    }

    // MARK: - Unknown type decode tolerance

    func test_unknownPartType_decodesWithoutThrowing() throws {
        // A future server sends a part type this SDK doesn't know yet.
        let futurePayload = #"{"type":"image","url":"https://example.com/img.png"}"#.data(using: .utf8)!

        // Must NOT throw — forward-compat contract.
        let decoded = try JSONDecoder().decode(ToolResultPart.self, from: futurePayload)

        // Sabotage check: throwing in the default branch of init(from:) would
        // cause this test to fail with a DecodingError.
        if case .unknown(let typeString) = decoded {
            XCTAssertEqual(typeString, "image")
        } else {
            XCTFail("Expected .unknown(type:), got \(decoded)")
        }
    }

    func test_unknownPartType_roundTripPreservesTypeString() throws {
        // .unknown can be re-encoded and the type field survives.
        let part = ToolResultPart.unknown(type: "video")
        let encoded = try JSONEncoder().encode(part)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(obj["type"] as? String, "video")
    }

    // MARK: - ToolResult round-trips with structuredContent populated

    func test_toolResult_roundTrips_withStructuredContent() throws {
        let parts: [ToolResultPart] = [.text("line1"), .text("line2")]
        let result = ToolResult(
            callId: "c-1",
            content: "line1\nline2",
            structuredContent: parts
        )

        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: encoded)

        // Sabotage check: not encoding structuredContent causes decoded.structuredContent to be nil.
        XCTAssertEqual(decoded.callId, "c-1")
        XCTAssertEqual(decoded.content, "line1\nline2")
        XCTAssertEqual(decoded.structuredContent, parts)
        XCTAssertFalse(decoded.isError)
    }

    func test_toolResult_roundTrips_withMixedParts() throws {
        let parts: [ToolResultPart] = [.text("Known"), .unknown(type: "future")]
        let result = ToolResult(
            callId: "c-2",
            content: "Known",
            structuredContent: parts
        )

        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: encoded)

        XCTAssertEqual(decoded.structuredContent?.count, 2)
        XCTAssertEqual(decoded.structuredContent?[0], .text("Known"))
        XCTAssertEqual(decoded.structuredContent?[1], .unknown(type: "future"))
    }

    // MARK: - Legacy decode (no structuredContent key) → nil

    func test_legacyPayload_decodesWithNilStructuredContent() throws {
        // Pre-sidecar payloads have no "structuredContent" key. They must decode
        // successfully with structuredContent == nil.
        let legacy = #"{"callId":"x","content":"y"}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ToolResult.self, from: legacy)

        // Sabotage check: using `decode` instead of `decodeIfPresent` for
        // structuredContent would throw a keyNotFound error here.
        XCTAssertNil(decoded.structuredContent)
        XCTAssertEqual(decoded.callId, "x")
        XCTAssertEqual(decoded.content, "y")
    }

    // MARK: - Encode nil structuredContent → key absent

    func test_nilStructuredContent_omitsKeyFromJSON() throws {
        let result = ToolResult(callId: "c", content: "ok")
        let encoded = try JSONEncoder().encode(result)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        // Sabotage check: using `encode` instead of `encodeIfPresent` would
        // emit a null or empty-array value for the key, breaking backward compat.
        XCTAssertNil(obj["structuredContent"], "nil structuredContent must not appear in encoded JSON")
        // Confirm other fields are still present
        XCTAssertNotNil(obj["callId"])
        XCTAssertNotNil(obj["content"])
    }

    // MARK: - All existing call sites compile unchanged (default nil)

    func test_existingCallSites_compilesWithNoStructuredContent() throws {
        // Verifies the defaulted parameter keeps all pre-existing construction
        // sites source-compatible. The compiler enforces this; this runtime
        // test just confirms the field is nil when omitted.
        let a = ToolResult(callId: "a", content: "x")
        let b = ToolResult(callId: "b", content: "x", errorKind: .timeout)
        let c = ToolResult(callId: "c", content: "x", errorKind: nil, dialog: "Hello")

        XCTAssertNil(a.structuredContent)
        XCTAssertNil(b.structuredContent)
        XCTAssertNil(c.structuredContent)
    }

    // MARK: - Equatable / Hashable

    func test_resultsWithDifferentStructuredContent_areNotEqual() {
        let a = ToolResult(callId: "c", content: "x", structuredContent: [.text("foo")])
        let b = ToolResult(callId: "c", content: "x", structuredContent: nil)
        XCTAssertNotEqual(a, b)
    }

    func test_resultsWithEqualStructuredContent_areEqual() {
        let a = ToolResult(callId: "c", content: "x", structuredContent: [.text("foo")])
        let b = ToolResult(callId: "c", content: "x", structuredContent: [.text("foo")])
        XCTAssertEqual(a, b)
    }

    func test_toolResultPart_equatable_textVsUnknown() {
        XCTAssertNotEqual(ToolResultPart.text("x"), ToolResultPart.unknown(type: "x"))
    }

    func test_toolResultPart_hashable_canBeUsedInSet() {
        let parts: Set<ToolResultPart> = [.text("a"), .text("a"), .unknown(type: "b")]
        XCTAssertEqual(parts.count, 2)
    }

    // MARK: - Array of unknown parts in full payload

    func test_fullPayloadWithUnknownPart_decodesWithoutThrowing() throws {
        // Simulate a future server response containing an unknown part alongside
        // a known text part.
        let payload = """
        {
          "callId": "abc",
          "content": "fallback",
          "structuredContent": [
            {"type": "text", "text": "known"},
            {"type": "audio", "url": "https://example.com/audio.mp3"}
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ToolResult.self, from: payload)

        XCTAssertEqual(decoded.callId, "abc")
        XCTAssertEqual(decoded.content, "fallback")
        XCTAssertEqual(decoded.structuredContent?.count, 2)
        XCTAssertEqual(decoded.structuredContent?[0], .text("known"))
        XCTAssertEqual(decoded.structuredContent?[1], .unknown(type: "audio"))
    }
}
