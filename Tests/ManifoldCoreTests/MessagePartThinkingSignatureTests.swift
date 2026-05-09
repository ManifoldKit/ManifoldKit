import XCTest
import ManifoldInference

/// Tests for #482 / #604: ``MessagePart/thinking(_:signature:)`` Codable
/// round-trip with the new optional signature payload, multi-block
/// ``ChatMessageRecord`` round-trip, and backward compatibility with the
/// pre-#604 bare-string wire format.
final class MessagePartThinkingSignatureTests: XCTestCase {

    // MARK: - 1. Codable round-trip with signature

    func test_thinking_withSignature_roundtripsViaJSON() throws {
        let part: MessagePart = .thinking("reasoning text", signature: "sig_abc123")

        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)

        XCTAssertEqual(decoded, [part],
            ".thinking with a signature must survive JSON round-trip with the signature preserved verbatim")
        XCTAssertEqual(decoded.first?.thinkingContent, "reasoning text")
        XCTAssertEqual(decoded.first?.thinkingSignature, "sig_abc123")

        // Sabotage check: encoding the signature into a typo'd field name
        // (e.g. `sig` instead of `signature`) would round-trip to
        // signature == nil and this assertion would fail.
    }

    func test_thinking_withoutSignature_roundtripsViaJSON() throws {
        // Signature-less thinking is the common path for non-Anthropic
        // backends (MLX inline `<think>`, OpenAI `reasoning_content`,
        // Llama `<think>` tags). The encoder must omit `signature` from the
        // payload rather than emit `"signature": null` so persisted JSON
        // stays compact.
        let part: MessagePart = .thinking("local reasoning", signature: nil)

        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)

        XCTAssertEqual(decoded, [part])
        XCTAssertEqual(decoded.first?.thinkingContent, "local reasoning")
        XCTAssertNil(decoded.first?.thinkingSignature)
    }

    // MARK: - 2. Wire format pin — signature lives inside the thinking object

    func test_thinking_wireFormat_signatureNestedUnderThinking() throws {
        let part: MessagePart = .thinking("text", signature: "sig_xyz")
        let data = try JSONEncoder().encode([part])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        // Pin the wire shape: `{"thinking": {"text": "...", "signature": "..."}}`.
        // The key `signature` must appear nested under the `thinking`
        // discriminator, not at the array element top level. A silent
        // refactor that hoisted the signature out of the nested object
        // would strand every persisted row.
        XCTAssertTrue(json.contains(#""signature":"sig_xyz""#),
            "Signature must be present in the wire payload. Saw: \(json)")
        XCTAssertTrue(json.contains(#""text":"text""#),
            "Thinking text must be encoded under the `text` key. Saw: \(json)")
    }

    // MARK: - 3. Legacy bare-string format still decodes

    /// Pre-#604 persisted rows used the bare-string form
    /// `{"thinking": "text"}`. Existing stores must continue to decode
    /// without migration when the new optional signature lands.
    func test_thinking_legacyBareStringForm_decodesAsThinkingWithNilSignature() throws {
        let legacyJSON = #"[{"thinking":"old reasoning"}]"#
        let data = Data(legacyJSON.utf8)

        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].thinkingContent, "old reasoning",
            "Legacy bare-string `.thinking` rows must decode to the same text content")
        XCTAssertNil(decoded[0].thinkingSignature,
            "Legacy rows have no signature — must decode as nil rather than empty string or skipping")

        // Sabotage check: removing the `DecodingError.typeMismatch` fallback
        // in `MessagePart.init(from:)` would cause this decode to throw,
        // stranding every pre-#604 thinking row.
    }

    // MARK: - 4. ChatMessageRecord with multiple thinking parts

    func test_chatMessageRecord_multipleThinkingParts_encodeDecode() throws {
        // Two distinct reasoning rounds within one assistant turn —
        // backends that emit multiple `content_block_start{type:"thinking"}`
        // events produce this shape. Each must keep its own signature.
        let parts: [MessagePart] = [
            .thinking("first round of thought", signature: "sig_1"),
            .thinking("second round, different signature", signature: "sig_2"),
            .text("Final visible answer."),
        ]
        let record = ChatMessageRecord(role: .assistant, contentParts: parts, sessionID: UUID())

        // Round-trip via JSON to mirror what ManifoldSchemaV4.ChatMessage does.
        let data = try JSONEncoder().encode(record.contentParts)
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)

        XCTAssertEqual(decoded.count, 3,
            "Multiple thinking parts must encode and decode independently — no merging")
        XCTAssertEqual(decoded[0].thinkingSignature, "sig_1")
        XCTAssertEqual(decoded[1].thinkingSignature, "sig_2",
            "Each thinking part keeps its own signature; signatures must not be coalesced or replaced")
        XCTAssertEqual(decoded[2].textContent, "Final visible answer.")
    }

    // MARK: - 5. textContent excludes thinking even with signature

    func test_textContent_returnsNil_forThinkingWithSignature() {
        let part: MessagePart = .thinking("internal reasoning", signature: "sig")
        XCTAssertNil(part.textContent,
            ".textContent must remain nil regardless of whether a signature is attached")
    }

    // MARK: - 6. Equality respects the signature

    func test_equality_signatureMismatch_partsAreUnequal() {
        let a: MessagePart = .thinking("x", signature: "sig_1")
        let b: MessagePart = .thinking("x", signature: "sig_2")
        XCTAssertNotEqual(a, b,
            "Two thinking parts with the same text but different signatures must compare unequal — " +
            "Anthropic rejects mismatched signatures, so equality must be signature-aware")

        let c: MessagePart = .thinking("x", signature: nil)
        let d: MessagePart = .thinking("x", signature: "sig_1")
        XCTAssertNotEqual(c, d, "nil vs non-nil signature is a real difference")
    }
}
