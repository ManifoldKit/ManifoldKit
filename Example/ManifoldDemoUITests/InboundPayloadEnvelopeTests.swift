import XCTest
import ManifoldInference

/// Unit-level coverage for the App Group envelope written by
/// ``AskManifoldDemoIntent`` and read back by ``ManifoldDemoApp``.
///
/// The envelope file (`InboundPayloadEnvelope.swift`) is compiled into
/// both the demo app target and this UITests bundle so the wire-format
/// contract — prompt + attachments + source — can be exercised without
/// driving Shortcuts or launching the demo. The contract matters
/// because `MessagePart` attachments must survive the JSON round trip
/// or attachments dropped by the writer would silently disappear from
/// the user message that ``ChatViewModel/ingest(_:)`` seeds.
final class InboundPayloadEnvelopeTests: XCTestCase {

    func test_envelope_roundTripsPromptAndSource() throws {
        let envelope = InboundPayloadEnvelope(
            prompt: "summarize this article",
            attachments: [],
            source: "appIntent"
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(InboundPayloadEnvelope.self, from: data)

        XCTAssertEqual(decoded.prompt, "summarize this article")
        XCTAssertEqual(decoded.source, "appIntent")
        XCTAssertTrue(decoded.attachments.isEmpty)
    }

    func test_envelope_roundTripsAttachmentsEndToEnd() throws {
        // Cover all `MessagePart` cases that an Action / Share Extension
        // could plausibly hand off: text alongside the prompt, an inline
        // image, and a reasoning block. If any case fails to round-trip
        // through the App Group envelope, attachments dropped silently
        // by the writer would surface here.
        let attachments: [MessagePart] = [
            .text("relevant context"),
            .image(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png"),
            .thinking("model reasoning carried verbatim", signature: "sig-abc"),
        ]
        let envelope = InboundPayloadEnvelope(
            prompt: "act on the attached payload",
            attachments: attachments,
            source: "shareExtension"
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(InboundPayloadEnvelope.self, from: data)

        XCTAssertEqual(decoded.prompt, "act on the attached payload")
        XCTAssertEqual(decoded.source, "shareExtension")
        XCTAssertEqual(decoded.attachments, attachments)
    }

    func test_envelope_decodesLegacyShapeWithoutAttachmentsField() throws {
        // PR #666 shipped an envelope with only `prompt` + `source` — any
        // payload sitting in App Group defaults from a previous build
        // must continue to decode rather than panicking on a missing key.
        let legacyJSON = #"{"prompt":"hello","source":"appIntent"}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(InboundPayloadEnvelope.self, from: legacyJSON)

        XCTAssertEqual(decoded.prompt, "hello")
        XCTAssertEqual(decoded.source, "appIntent")
        XCTAssertTrue(decoded.attachments.isEmpty)
    }

    func test_envelope_emitsAttachmentsKeyWhenNonEmpty() throws {
        // Pin the wire format: a non-empty `attachments` array must
        // serialise under the literal key `"attachments"` so the reader
        // in `ManifoldDemoApp.handleOpenURL(_:)` (and any future
        // out-of-process consumer) can find it.
        let envelope = InboundPayloadEnvelope(
            prompt: "p",
            attachments: [.text("a")],
            source: "appIntent"
        )

        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(object?["attachments"])
        XCTAssertEqual((object?["attachments"] as? [Any])?.count, 1)
    }
}
