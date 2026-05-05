import XCTest
import BaseChatInference

/// Unit tests for ``MessagePart/generatedImage(_:)`` — Codable round-tripping,
/// wire-format pinning, accessor behaviour, and `textContent` exclusion.
///
/// Distinct from ``MessagePart/image(data:mimeType:)``: the `.image` case
/// carries raw bytes the *user* uploaded as multimodal input; this case
/// references a file URL whose binary is the model's *output*.
final class MessagePartGeneratedImageTests: XCTestCase {

    // MARK: - Fixtures

    private func makePayload(
        prompt: String = "a watercolor of a fox",
        imageURL: URL = URL(fileURLWithPath: "/tmp/baseChatKitTest/img.png"),
        modelIdentifier: String = "fake-model-v1"
    ) -> ImageMessagePayload {
        ImageMessagePayload(
            prompt: prompt,
            imageURL: imageURL,
            modelIdentifier: modelIdentifier,
            generationConfig: ImageGenerationConfigSnapshot(
                steps: 8,
                width: 512,
                height: 768,
                seed: 42,
                guidanceScale: 7.5
            ),
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Codable round-trip

    func test_generatedImage_codableRoundtrip() throws {
        let part: MessagePart = .generatedImage(makePayload())

        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)

        XCTAssertEqual(decoded, [part],
            ".generatedImage must survive Codable round-trip with all payload fields preserved")

        // Sabotage check (manual): if MessagePart.encode(to:) encoded
        // .generatedImage to a different key (e.g. `genImage`), the decoder's
        // discriminator switch would fail and this assertion would not even
        // compare equal payloads.
    }

    // MARK: - Wire-format discriminator pinning

    /// Renaming the `.generatedImage` raw key would silently strand every
    /// persisted row that already wrote it. Pin the literal key here so a
    /// rename surfaces as a test failure rather than a quiet migration.
    func test_generatedImage_wireFormatDiscriminatorIsPinned() throws {
        let part: MessagePart = .generatedImage(makePayload())
        let data = try JSONEncoder().encode([part])
        let json = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(json.contains(#""generatedImage""#),
            "Persisted JSON must use the literal discriminator key 'generatedImage'")
    }

    /// Pin a representative payload field name. If the persistence-layer
    /// `ImageMessagePayload` is renamed, persisted rows would silently
    /// fail to round-trip; pinning a stable field catches that earlier.
    func test_generatedImage_payloadFieldNamesArePinned() throws {
        let part: MessagePart = .generatedImage(makePayload())
        let data = try JSONEncoder().encode([part])
        let json = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(json.contains(#""prompt""#),
            "ImageMessagePayload.prompt must encode under the literal key 'prompt'")
        XCTAssertTrue(json.contains(#""imageURL""#),
            "ImageMessagePayload.imageURL must encode under the literal key 'imageURL'")
        XCTAssertTrue(json.contains(#""modelIdentifier""#),
            "ImageMessagePayload.modelIdentifier must encode under the literal key 'modelIdentifier'")
        XCTAssertTrue(json.contains(#""generationConfig""#),
            "ImageMessagePayload.generationConfig must encode under the literal key 'generationConfig'")
        XCTAssertTrue(json.contains(#""generatedAt""#),
            "ImageMessagePayload.generatedAt must encode under the literal key 'generatedAt'")
    }

    // MARK: - Mixed-array round-trip with all seven cases

    func test_allSevenCases_mixedArray_codableRoundtrip() throws {
        let parts: [MessagePart] = [
            .text("Here is what I generated:"),
            .thinking("Let me think about composition."),
            .toolCall(ToolCall(id: "c1", toolName: "render", arguments: "{}")),
            .toolResult(ToolResult(callId: "c1", content: "ok", isError: false)),
            .image(data: Data([0xFF]), mimeType: "image/jpeg"),
            .audio(url: URL(fileURLWithPath: "/Users/example/audio.m4a"), duration: 4, waveform: [0.1, 0.9]),
            .generatedImage(makePayload()),
        ]

        let data = try JSONEncoder().encode(parts)
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)

        XCTAssertEqual(decoded, parts,
            "Mixed array including .generatedImage must round-trip intact, preserving order")
    }

    // MARK: - textContent exclusion

    func test_textContent_returnsNil_forGeneratedImage() {
        let part: MessagePart = .generatedImage(makePayload())
        XCTAssertNil(part.textContent,
            ".textContent must be nil for .generatedImage (consistent with .image / .toolCall / .toolResult / .thinking)")
    }

    // MARK: - Accessor

    func test_generatedImageContent_returnsAssociatedValue() {
        let payload = makePayload(prompt: "a robot reading a book")
        let part: MessagePart = .generatedImage(payload)

        XCTAssertEqual(part.generatedImageContent, payload)
        XCTAssertNil(part.toolCallContent)
        XCTAssertNil(part.toolResultContent)
        XCTAssertNil(part.thinkingContent)
        XCTAssertNil(part.textContent)
    }

    func test_generatedImageContent_returnsNil_forOtherCases() {
        XCTAssertNil(MessagePart.text("x").generatedImageContent)
        XCTAssertNil(MessagePart.thinking("x").generatedImageContent)
        XCTAssertNil(MessagePart.image(data: Data(), mimeType: "image/png").generatedImageContent)
        XCTAssertNil(MessagePart.audio(url: URL(fileURLWithPath: "/Users/example/audio.m4a"), duration: 1, waveform: nil).generatedImageContent)
        XCTAssertNil(MessagePart.toolCall(ToolCall(id: "c", toolName: "t", arguments: "{}")).generatedImageContent)
        XCTAssertNil(MessagePart.toolResult(ToolResult(callId: "c", content: "x", isError: false)).generatedImageContent)
    }

    // MARK: - Canonical JSON fixture (hand-written)

    /// Decodes a JSON document **hand-written** to match the expected
    /// on-disk shape. The point is to pin the wire format byte-for-byte —
    /// using `JSONEncoder` to generate the fixture and then asserting
    /// against itself would be tautological and would silently shift if
    /// the encoder ever changed its key strategy.
    ///
    /// Only the inner `generationConfig` payload is generated via
    /// `JSONEncoder` because it's a separate snapshot type whose internals
    /// we deliberately don't want to hand-craft (and re-encode on every
    /// drift) here. The outer shape, discriminator, and field names are
    /// hand-written.
    ///
    /// Sets a precedent for fixture-pinning new MessagePart cases. Existing
    /// cases are not retroactively covered — that would be a separate
    /// cleanup.
    func test_generatedImage_decodesCanonicalJSONFixture() throws {
        // Generate only the nested `generationConfig` snapshot value via
        // JSONEncoder so we don't have to hand-mirror its own field shape.
        let snapshot = ImageGenerationConfigSnapshot(
            steps: 8, width: 512, height: 768, seed: 42, guidanceScale: 7.5
        )
        let snapshotData = try JSONEncoder().encode(snapshot)
        let snapshotJSON = try XCTUnwrap(String(data: snapshotData, encoding: .utf8))

        // Default JSONEncoder encodes Date as timeIntervalSinceReferenceDate.
        // Pick a fixed value so the fixture stays deterministic.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let dateValue = date.timeIntervalSinceReferenceDate

        // Hand-written outer shape. Note the literal discriminator
        // "generatedImage" and the literal field names "prompt",
        // "imageURL", "modelIdentifier", "generationConfig", "generatedAt".
        let json = """
        {"generatedImage":{"prompt":"a sunset","imageURL":"file:///tmp/img.png","modelIdentifier":"flux-schnell","generationConfig":\(snapshotJSON),"generatedAt":\(dateValue)}}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MessagePart.self, from: json)

        guard case .generatedImage(let payload) = decoded else {
            XCTFail("Canonical fixture must decode as .generatedImage, got \(decoded)")
            return
        }
        XCTAssertEqual(payload.prompt, "a sunset")
        XCTAssertEqual(payload.imageURL, URL(string: "file:///tmp/img.png"))
        XCTAssertEqual(payload.modelIdentifier, "flux-schnell")
        XCTAssertEqual(payload.generationConfig, snapshot)
        XCTAssertEqual(payload.generatedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    // MARK: - Discriminator-error guards

    /// Removing the empty-keys check in ``MessagePart/init(from:)`` would
    /// silently turn a `{}` row into an undefined behaviour path. Pin the
    /// throw so a refactor that drops the guard surfaces here.
    func test_messagePart_emptyDiscriminatorContainer_throws() {
        let json = "{}".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(MessagePart.self, from: json),
            "Empty discriminator container must throw — see MessagePart.init(from:)")
    }

    /// Removing the `keys.count > 1` check would silently pick whichever
    /// key happens to be `.first` from an unordered set, masking corrupt
    /// rows that carry two discriminators.
    func test_messagePart_multipleDiscriminatorKeys_throws() {
        let json = #"{"text":"hi","generatedImage":{"prompt":"a","imageURL":"file:///tmp/x.png","modelIdentifier":"m","generationConfig":{"steps":1,"width":1,"height":1},"generatedAt":0}}"#
            .data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(MessagePart.self, from: json),
            "Two discriminator keys present must throw — pinned guard in MessagePart.init(from:)")
    }

    // MARK: - Backwards-compat: legacy-only fixture (no .generatedImage)

    /// Decodes a hand-written `[MessagePart]` JSON containing only older
    /// cases (text, thinking, image, toolCall, toolResult) —
    /// no `.generatedImage`. Proves additive persistence: rows persisted
    /// before the new case existed still decode through the new build.
    func test_legacyMessageParts_withoutGeneratedImage_decodeIntact() throws {
        // Generate only the inner ToolCall/ToolResult JSON via the
        // encoder; the outer shape and the other discriminators are
        // hand-written so a renamed key (e.g. `text` → `t`) shows up as a
        // test failure rather than a silent migration.
        let toolCall = ToolCall(id: "c1", toolName: "search", arguments: "{"q":"swift"}")
        let toolResult = ToolResult(callId: "c1", content: "ok", isError: false)
        let toolCallJSON = try XCTUnwrap(String(data: try JSONEncoder().encode(toolCall), encoding: .utf8))
        let toolResultJSON = try XCTUnwrap(String(data: try JSONEncoder().encode(toolResult), encoding: .utf8))

        // Image bytes: `[0x01, 0x02]` → base64 `AQI=`.
        // Default encoder serialises Data as base64 strings, which
        // Base64 decoder then accepts on read.
        let json = """
        [
          {"text":"hello"},
          {"thinking":{"text":"reasoning","signature":"sig-1"}},
          {"image":{"data":"AQI=","mimeType":"image/png"}},
          {"toolCall":\(toolCallJSON)},
          {"toolResult":\(toolResultJSON)}
        ]
        """.data(using: .utf8)!

        let parts = try JSONDecoder().decode([MessagePart].self, from: json)
        XCTAssertEqual(parts.count, 5)

        // Spot-check each case decoded as the right enum variant.
        guard case .text(let t) = parts[0] else { return XCTFail("0: expected .text") }
        XCTAssertEqual(t, "hello")

        guard case .thinking(let think, let sig) = parts[1] else { return XCTFail("1: expected .thinking") }
        XCTAssertEqual(think, "reasoning")
        XCTAssertEqual(sig, "sig-1")

        guard case .image(let data, let mime, _) = parts[2] else { return XCTFail("2: expected .image") }
        XCTAssertEqual(data, Data([0x01, 0x02]))
        XCTAssertEqual(mime, "image/png")

        guard case .toolCall(let call) = parts[3] else { return XCTFail("3: expected .toolCall") }
        XCTAssertEqual(call, toolCall)

        guard case .toolResult(let result) = parts[4] else { return XCTFail("4: expected .toolResult") }
        XCTAssertEqual(result, toolResult)
    }

    /// Legacy bare-string `.thinking` form (pre-#604) must still decode.
    /// Pinned here as part of the additive-persistence proof so a future
    /// refactor that drops the type-mismatch fallback in
    /// ``MessagePart/init(from:)`` surfaces immediately.
    func test_legacyThinkingBareString_decodesAsThinkingWithNilSignature() throws {
        let json = #"{"thinking":"raw legacy reasoning"}"#.data(using: .utf8)!
        let part = try JSONDecoder().decode(MessagePart.self, from: json)

        guard case .thinking(let text, let sig) = part else {
            XCTFail("Bare-string thinking must decode as .thinking")
            return
        }
        XCTAssertEqual(text, "raw legacy reasoning")
        XCTAssertNil(sig)
    }
}
