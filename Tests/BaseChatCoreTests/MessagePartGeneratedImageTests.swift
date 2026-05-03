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

    // MARK: - Mixed-array round-trip with all six cases

    func test_allSixCases_mixedArray_codableRoundtrip() throws {
        let parts: [MessagePart] = [
            .text("Here is what I generated:"),
            .thinking("Let me think about composition."),
            .toolCall(ToolCall(id: "c1", toolName: "render", arguments: "{}")),
            .toolResult(ToolResult(callId: "c1", content: "ok", isError: false)),
            .image(data: Data([0xFF]), mimeType: "image/jpeg"),
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
        XCTAssertNil(MessagePart.toolCall(ToolCall(id: "c", toolName: "t", arguments: "{}")).generatedImageContent)
        XCTAssertNil(MessagePart.toolResult(ToolResult(callId: "c", content: "x", isError: false)).generatedImageContent)
    }
}
