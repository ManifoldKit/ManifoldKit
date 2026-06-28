import XCTest
@testable import ManifoldTelemetryOTLP
import ManifoldInference

/// Unit tests for ``OTLPSpanSerializer``.
///
/// Verifies the OTLP/JSON wire shape without a network round-trip.
final class OTLPSerializerTests: XCTestCase {

    // MARK: - Helpers

    private func makeSpan(
        kind: SpanKind = .llm,
        parentSpanID: SpanID? = nil,
        end: Date? = Date(timeIntervalSince1970: 1_000_001),
        status: SpanStatus = .ok,
        attributes: [String: AttributeValue] = [:]
    ) -> GenSpan {
        let traceID = TraceID(bytes: Array(repeating: 0xAB, count: 16))
        let spanID = SpanID(bytes: Array(repeating: 0xCD, count: 8))
        let context = SpanContext(traceID: traceID, spanID: spanID, parentSpanID: parentSpanID)
        return GenSpan(
            context: context,
            kind: kind,
            name: "test-span",
            start: Date(timeIntervalSince1970: 1_000_000),
            end: end,
            attributes: attributes,
            status: status
        )
    }

    private func parsedSpan(from span: GenSpan) throws -> [String: Any] {
        let data = try OTLPSpanSerializer.payload(for: span)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resourceSpans = try XCTUnwrap(root["resourceSpans"] as? [[String: Any]])
        let scopeSpans = try XCTUnwrap(resourceSpans.first?["scopeSpans"] as? [[String: Any]])
        let spans = try XCTUnwrap(scopeSpans.first?["spans"] as? [[String: Any]])
        return try XCTUnwrap(spans.first)
    }

    // MARK: - IDs

    func test_traceId_isLowercaseHex() throws {
        let span = makeSpan()
        let obj = try parsedSpan(from: span)
        let traceId = try XCTUnwrap(obj["traceId"] as? String)
        XCTAssertEqual(traceId.count, 32)
        XCTAssertTrue(traceId.allSatisfy { $0.isHexDigit })
        // Sabotage: if we passed spanId bytes instead, length would be 16.
    }

    func test_spanId_isLowercaseHex() throws {
        let span = makeSpan()
        let obj = try parsedSpan(from: span)
        let spanId = try XCTUnwrap(obj["spanId"] as? String)
        XCTAssertEqual(spanId.count, 16)
    }

    func test_parentSpanId_absentForRootSpan() throws {
        let span = makeSpan(parentSpanID: nil)
        let obj = try parsedSpan(from: span)
        XCTAssertNil(obj["parentSpanId"])
    }

    func test_parentSpanId_presentForChildSpan() throws {
        let parentID = SpanID(bytes: Array(repeating: 0xEF, count: 8))
        let span = makeSpan(parentSpanID: parentID)
        let obj = try parsedSpan(from: span)
        let parentSpanId = try XCTUnwrap(obj["parentSpanId"] as? String)
        XCTAssertEqual(parentSpanId.count, 16)
        XCTAssertEqual(parentSpanId, parentID.description)
    }

    // MARK: - Timestamps

    func test_startTimeUnixNano_isQuotedDecimalString() throws {
        let span = makeSpan()
        let obj = try parsedSpan(from: span)
        let nano = try XCTUnwrap(obj["startTimeUnixNano"] as? String)
        // 1_000_000 seconds × 1e9 ns/s = 1_000_000_000_000_000 (10^15) nanoseconds.
        XCTAssertEqual(nano, "1000000000000000")
        // Sabotage: returning an Int instead of String would fail XCTUnwrap above.
    }

    func test_endTimeUnixNano_presentWhenEndIsSet() throws {
        let span = makeSpan(end: Date(timeIntervalSince1970: 1_000_001))
        let obj = try parsedSpan(from: span)
        let nano = try XCTUnwrap(obj["endTimeUnixNano"] as? String)
        // 1_000_001 seconds × 1e9 ns/s = 1_000_001_000_000_000 nanoseconds.
        XCTAssertEqual(nano, "1000001000000000")
    }

    func test_endTimeUnixNano_absentWhenEndIsNil() throws {
        let span = makeSpan(end: nil)
        let obj = try parsedSpan(from: span)
        XCTAssertNil(obj["endTimeUnixNano"])
    }

    // MARK: - Kind

    func test_kind_llmMapsToClient() throws {
        let span = makeSpan(kind: .llm)
        let obj = try parsedSpan(from: span)
        let k = try XCTUnwrap(obj["kind"] as? Int)
        // OTel GenAI conventions: LLM calls are outbound → SPAN_KIND_CLIENT (3).
        XCTAssertEqual(k, 3)
        // Sabotage: returning 1 (SPAN_KIND_INTERNAL) instead would fail this.
    }

    func test_kind_chainMapsToInternal() throws {
        let span = makeSpan(kind: .chain)
        let obj = try parsedSpan(from: span)
        let k = try XCTUnwrap(obj["kind"] as? Int)
        XCTAssertEqual(k, 1)  // SPAN_KIND_INTERNAL
    }

    func test_kind_toolMapsToInternal() throws {
        let span = makeSpan(kind: .tool)
        let obj = try parsedSpan(from: span)
        let k = try XCTUnwrap(obj["kind"] as? Int)
        XCTAssertEqual(k, 1)  // SPAN_KIND_INTERNAL
    }

    // MARK: - Status

    func test_status_unset() throws {
        let span = GenSpan(
            context: .root(), kind: .llm, name: "s",
            start: Date(timeIntervalSince1970: 0), status: .unset
        )
        let obj = try parsedSpan(from: span)
        let status = try XCTUnwrap(obj["status"] as? [String: Any])
        XCTAssertEqual(status["code"] as? Int, 0)
        XCTAssertNil(status["message"])
    }

    func test_status_ok() throws {
        let span = makeSpan(status: .ok)
        let obj = try parsedSpan(from: span)
        let status = try XCTUnwrap(obj["status"] as? [String: Any])
        XCTAssertEqual(status["code"] as? Int, 1)
    }

    func test_status_error() throws {
        let span = makeSpan(status: .error("rateLimited"))
        let obj = try parsedSpan(from: span)
        let status = try XCTUnwrap(obj["status"] as? [String: Any])
        XCTAssertEqual(status["code"] as? Int, 2)
        XCTAssertEqual(status["message"] as? String, "rateLimited")
    }

    // MARK: - Attributes

    func test_openInferenceKind_isFirstAttribute() throws {
        let span = makeSpan(kind: .llm)
        let obj = try parsedSpan(from: span)
        let attrs = try XCTUnwrap(obj["attributes"] as? [[String: Any]])
        let first = try XCTUnwrap(attrs.first)
        XCTAssertEqual(first["key"] as? String, "openinference.span.kind")
        let val = try XCTUnwrap(first["value"] as? [String: Any])
        XCTAssertEqual(val["stringValue"] as? String, "LLM")
    }

    func test_stringAttribute_encodedAsStringValue() throws {
        let span = makeSpan(attributes: ["gen_ai.system": .string("Claude")])
        let obj = try parsedSpan(from: span)
        let attrs = try XCTUnwrap(obj["attributes"] as? [[String: Any]])
        let genAISystem = attrs.first { ($0["key"] as? String) == "gen_ai.system" }
        let val = try XCTUnwrap(genAISystem?["value"] as? [String: Any])
        XCTAssertEqual(val["stringValue"] as? String, "Claude")
    }

    func test_intAttribute_encodedAsQuotedString() throws {
        let span = makeSpan(attributes: ["gen_ai.usage.prompt_tokens": .int(120)])
        let obj = try parsedSpan(from: span)
        let attrs = try XCTUnwrap(obj["attributes"] as? [[String: Any]])
        let tokenAttr = attrs.first { ($0["key"] as? String) == "gen_ai.usage.prompt_tokens" }
        let val = try XCTUnwrap(tokenAttr?["value"] as? [String: Any])
        // Proto3 JSON mapping: int64 → quoted decimal string, not a JSON number.
        XCTAssertEqual(val["intValue"] as? String, "120")
        XCTAssertNil(val["intValue"] as? Int, "intValue must not be a JSON number")
        // Sabotage: using intValue: 120 (JSON int) instead of "120" fails the String cast.
    }

    func test_doubleAttribute_encodedAsDoubleValue() throws {
        let span = makeSpan(attributes: ["gen_ai.latency.wall_clock_ms": .double(900.5)])
        let obj = try parsedSpan(from: span)
        let attrs = try XCTUnwrap(obj["attributes"] as? [[String: Any]])
        let latAttr = attrs.first { ($0["key"] as? String) == "gen_ai.latency.wall_clock_ms" }
        let val = try XCTUnwrap(latAttr?["value"] as? [String: Any])
        XCTAssertEqual((val["doubleValue"] as? Double) ?? 0, 900.5, accuracy: 0.001)
    }

    func test_boolAttribute_encodedAsBoolValue() throws {
        let span = makeSpan(attributes: ["streaming": .bool(true)])
        let obj = try parsedSpan(from: span)
        let attrs = try XCTUnwrap(obj["attributes"] as? [[String: Any]])
        let boolAttr = attrs.first { ($0["key"] as? String) == "streaming" }
        let val = try XCTUnwrap(boolAttr?["value"] as? [String: Any])
        XCTAssertEqual(val["boolValue"] as? Bool, true)
    }

    // MARK: - Envelope

    func test_envelope_resourceCarriesSDKName() throws {
        let data = try OTLPSpanSerializer.payload(for: makeSpan())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resourceSpans = try XCTUnwrap(root["resourceSpans"] as? [[String: Any]])
        let resource = try XCTUnwrap(resourceSpans.first?["resource"] as? [String: Any])
        let attrs = try XCTUnwrap(resource["attributes"] as? [[String: Any]])
        let sdk = attrs.first { ($0["key"] as? String) == "telemetry.sdk.name" }
        let val = try XCTUnwrap(sdk?["value"] as? [String: Any])
        XCTAssertEqual(val["stringValue"] as? String, "ManifoldKit")
    }

    func test_envelope_scopeNameIsModuleName() throws {
        let data = try OTLPSpanSerializer.payload(for: makeSpan())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resourceSpans = try XCTUnwrap(root["resourceSpans"] as? [[String: Any]])
        let scopeSpans = try XCTUnwrap(resourceSpans.first?["scopeSpans"] as? [[String: Any]])
        let scope = try XCTUnwrap(scopeSpans.first?["scope"] as? [String: Any])
        XCTAssertEqual(scope["name"] as? String, "ManifoldTelemetryOTLP")
    }
}
