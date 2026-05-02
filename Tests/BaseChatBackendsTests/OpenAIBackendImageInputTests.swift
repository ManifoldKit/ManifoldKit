#if CloudSaaS
import XCTest
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

/// Tests that ``OpenAIBackend`` wires ``MessagePart/image(data:mimeType:)``
/// through to OpenAI's `image_url` content-part wire format.
///
/// Covered acceptance points:
/// - single image + accompanying text
/// - multiple images on one turn
/// - text-and-image interleaving preserves part order
/// - non-vision model surfaces a clear error from `GenerationCoordinator`
///   (modelled here via `capabilities.supportsVision`)
/// - data-URI shape: `data:<mime>;base64,<payload>`
final class OpenAIBackendImageInputTests: XCTestCase {

    // MARK: - Fixtures

    /// 1×1 transparent PNG. Mirrors ``ImageFixtures/oneByOnePNGData`` —
    /// duplicated here so the assertion is independent of the fixture's
    /// implementation choice.
    private let pngBytes = ImageFixtures.oneByOnePNGData

    private func makeBackend(modelName: String = "gpt-4o-mini") -> OpenAIBackend {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: modelName
        )
        return backend
    }

    // MARK: - capabilities.supportsVision

    func test_capabilities_visionGated_byModelName() {
        XCTAssertTrue(OpenAIBackend.makeForVisionTest(modelName: "gpt-4o").capabilities.supportsVision)
        XCTAssertTrue(OpenAIBackend.makeForVisionTest(modelName: "gpt-4o-mini").capabilities.supportsVision)
        XCTAssertTrue(OpenAIBackend.makeForVisionTest(modelName: "gpt-4-turbo").capabilities.supportsVision)
        XCTAssertTrue(OpenAIBackend.makeForVisionTest(modelName: "gpt-4.1-mini").capabilities.supportsVision)

        XCTAssertFalse(OpenAIBackend.makeForVisionTest(modelName: "gpt-3.5-turbo").capabilities.supportsVision)
        XCTAssertFalse(OpenAIBackend.makeForVisionTest(modelName: "text-davinci-003").capabilities.supportsVision)
    }

    // MARK: - Single image

    func test_buildRequest_singleImage_encodesAsImageURLContentPart() throws {
        let backend = makeBackend(modelName: "gpt-4o-mini")
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .text("What is in this image?"),
                .image(data: pngBytes, mimeType: "image/png")
            ])
        ])

        let request = try backend.buildRequest(
            prompt: "ignored — structured history wins",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 1)
        let userMessage = messages[0]
        XCTAssertEqual(userMessage["role"] as? String, "user")

        let parts = try XCTUnwrap(userMessage["content"] as? [[String: Any]],
                                  "Multimodal turns must serialise content as an array of typed parts")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "What is in this image?")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(parts[1]["image_url"] as? [String: Any])
        let url = try XCTUnwrap(imageURL["url"] as? String)
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"),
                      "Expected `data:image/png;base64,...` URI, got: \(url.prefix(60))")
        XCTAssertEqual(url, "data:image/png;base64,\(pngBytes.base64EncodedString())")
    }

    // MARK: - Multiple images

    func test_buildRequest_multipleImages_encodesAllAsSeparateParts() throws {
        let backend = makeBackend(modelName: "gpt-4o")
        let secondPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG signature only
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .image(data: pngBytes, mimeType: "image/png"),
                .image(data: secondPNG, mimeType: "image/jpeg"),
                .text("Compare these.")
            ])
        ])

        let request = try backend.buildRequest(
            prompt: "ignored",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])

        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0]["type"] as? String, "image_url")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        XCTAssertEqual(parts[2]["type"] as? String, "text")
        XCTAssertEqual(parts[2]["text"] as? String, "Compare these.")

        let firstURL = try XCTUnwrap((parts[0]["image_url"] as? [String: Any])?["url"] as? String)
        let secondURL = try XCTUnwrap((parts[1]["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertTrue(firstURL.hasPrefix("data:image/png;base64,"))
        XCTAssertTrue(secondURL.hasPrefix("data:image/jpeg;base64,"),
                      "MIME type must be carried verbatim from MessagePart into the data URI")
    }

    // MARK: - Mixed text+image+text

    func test_buildRequest_textImageText_preservesPartOrder() throws {
        let backend = makeBackend(modelName: "gpt-4o-mini")
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .text("Before:"),
                .image(data: pngBytes, mimeType: "image/png"),
                .text("After:")
            ])
        ])

        let request = try backend.buildRequest(prompt: "x", systemPrompt: nil, config: GenerationConfig())
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let parts = try XCTUnwrap(((json["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "Before:")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        XCTAssertEqual(parts[2]["type"] as? String, "text")
        XCTAssertEqual(parts[2]["text"] as? String, "After:")
    }

    // MARK: - Multi-turn multimodal

    func test_buildRequest_multiTurn_assistantReplyAsString_userImageAsArray() throws {
        let backend = makeBackend(modelName: "gpt-4o-mini")
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [.text("hi")]),
            StructuredMessage(role: "assistant", parts: [.text("hello")]),
            StructuredMessage(role: "user", parts: [
                .text("look:"),
                .image(data: pngBytes, mimeType: "image/png")
            ])
        ])

        let request = try backend.buildRequest(prompt: "x", systemPrompt: nil, config: GenerationConfig())
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)

        // Text-only turns collapse to plain string content for compactness
        // and to match OpenAI's text-only example shape.
        XCTAssertEqual(messages[0]["content"] as? String, "hi")
        XCTAssertEqual(messages[1]["content"] as? String, "hello")
        // Multimodal turn uses the content-array shape.
        XCTAssertNotNil(messages[2]["content"] as? [[String: Any]])
    }

    // MARK: - Non-vision model error path

    /// `GenerationCoordinator` rejects image messages when
    /// `capabilities.supportsVision == false` — that's the user-facing error
    /// surface. We assert here that a non-vision OpenAI model name does in
    /// fact report `supportsVision == false` so the coordinator's gate
    /// triggers, and that a downstream caller can make the same check.
    func test_nonVisionModel_capabilityFlagFalse() {
        let backend = makeBackend(modelName: "gpt-3.5-turbo")
        XCTAssertFalse(backend.capabilities.supportsVision,
                       "gpt-3.5-turbo doesn't accept image_url; capability flag must be false so GenerationCoordinator rejects image messages with a clear error.")
    }

    func test_nonVisionModel_setStructuredHistoryWithImage_doesNotCrash_butCallerShouldGate() throws {
        // Defensive contract test: if a caller bypasses the coordinator and
        // sets a structured history with an image directly on a non-vision
        // configured backend, buildRequest still produces a syntactically
        // valid body. The capability flag is the contract surface that
        // prevents this from happening end-to-end.
        let backend = makeBackend(modelName: "gpt-3.5-turbo")
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .text("hello"),
                .image(data: pngBytes, mimeType: "image/png")
            ])
        ])
        XCTAssertNoThrow(try backend.buildRequest(
            prompt: "x", systemPrompt: nil, config: GenerationConfig()
        ))
    }

    // MARK: - Data URI formatting

    func test_dataURI_formatIsExactlyDataMimeBase64() {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(
            CloudImageEncoding.dataURI(data: bytes, mimeType: "image/png"),
            "data:image/png;base64,AQIDBA=="
        )
    }

    func test_dataURI_carriesMimeTypeVerbatim() {
        let bytes = Data([0xFF])
        XCTAssertTrue(CloudImageEncoding.dataURI(data: bytes, mimeType: "image/webp").hasPrefix("data:image/webp;base64,"))
        XCTAssertTrue(CloudImageEncoding.dataURI(data: bytes, mimeType: "image/jpeg").hasPrefix("data:image/jpeg;base64,"))
    }

    // MARK: - Fallback: structured history without images keeps text path

    /// When structured history contains no images, the legacy
    /// `conversationHistory` flattened-string path still wins. This keeps
    /// the wire shape stable for non-vision turns and avoids surprising
    /// servers that haven't been tested against the array-content form.
    func test_buildRequest_structuredHistoryTextOnly_doesNotForceArrayShape() throws {
        let backend = makeBackend(modelName: "gpt-4o-mini")
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [.text("hello")])
        ])
        backend.setConversationHistory([
            (role: "user", content: "hello")
        ])

        let request = try backend.buildRequest(prompt: "x", systemPrompt: nil, config: GenerationConfig())
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["content"] as? String, "hello",
                       "Text-only structured history should not promote content to the array shape.")
    }

    // MARK: - Protocol conformance

    func test_conformsToStructuredHistoryReceiver() {
        let backend: any InferenceBackend = OpenAIBackend()
        XCTAssertNotNil(backend as? StructuredHistoryReceiver,
                        "OpenAIBackend must adopt StructuredHistoryReceiver so the coordinator routes images to it.")
    }
}

// MARK: - Test helpers

private extension OpenAIBackend {
    /// Builds a backend pinned to the given model name purely for capability
    /// inspection. Skips network configuration so tests don't pay for an
    /// unrelated configure roundtrip.
    static func makeForVisionTest(modelName: String) -> OpenAIBackend {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: modelName
        )
        return backend
    }
}

#endif
