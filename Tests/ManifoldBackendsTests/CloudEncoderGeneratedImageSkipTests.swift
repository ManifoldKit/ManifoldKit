import XCTest
import ManifoldInference
@testable import ManifoldBackends
@testable import ManifoldCloud
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore

/// Pins the contract that cloud encoders skip ``MessagePart/generatedImage(_:)``
/// when serialising request bodies.
///
/// Cloud providers accept user-uploaded inputs (including image bytes) as
/// multimodal prompts, but they don't accept *backend-produced output*
/// images replayed back to them as multimodal turns — the API wire shape
/// has no slot for that, and even if it did, replaying generated images
/// would balloon prompt size for no benefit.
///
/// Today the encoders skip `.generatedImage` "naturally" because their
/// `for part in parts` loops match only the cases they understand
/// (`.image`, `.text`, `.thinking`). A future refactor that switches to an
/// exhaustive `switch` could silently regress this — these tests are the
/// sentry that catches such drift.
final class CloudEncoderGeneratedImageSkipTests: XCTestCase {

    // MARK: - Fixtures

    private func generatedImagePart(prompt: String = "a forest at dusk") -> MessagePart {
        .generatedImage(
            ImageMessagePayload(
                prompt: prompt,
                imageURL: URL(fileURLWithPath: "/var/tmp/baseChatKitTest/generated.png"),
                modelIdentifier: "fake-image-model-v1",
                generationConfig: ImageGenerationConfigSnapshot(
                    steps: 4, width: 512, height: 512
                ),
                generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }

    private let inputImageBytes: Data = Data([0xDE, 0xAD, 0xBE, 0xEF])
    private let inputImageMime = "image/png"

    // The set of fields that are unique to ``ImageMessagePayload`` and
    // would never appear in an input-image encoding. If any of these
    // strings shows up in the encoded request body, the encoder leaked the
    // generated image into the wire payload.
    private func assertNoGeneratedImageLeaked(in json: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(json.contains("a forest at dusk"),
            "Encoded body must not contain the generated image's prompt — that field is unique to ImageMessagePayload",
            file: file, line: line)
        XCTAssertFalse(json.contains("fake-image-model-v1"),
            "Encoded body must not contain modelIdentifier from a generated-image payload",
            file: file, line: line)
        XCTAssertFalse(json.contains("generated.png"),
            "Encoded body must not reference the generated image's local file URL",
            file: file, line: line)
    }

    // MARK: - Claude (Anthropic Messages API)

    func test_claudeEncoder_skipsGeneratedImageOnUserTurn() throws {
        let message = StructuredMessage(role: "user", parts: [
            .text("hi"),
            .image(data: inputImageBytes, mimeType: inputImageMime),
            generatedImagePart(),
        ])

        let encoded = CloudMessageEncoder.claude.encodeStructuredMessageContent(for: message)

        // The user turn carries an input image, so content must be a
        // structured array — that's the path that loops over parts.
        let blocks = try XCTUnwrap(encoded["content"] as? [[String: Any]],
            "Image-bearing user turn must serialize as a content[] array")

        // Exactly one image block (the input image) plus one text block.
        let imageBlocks = blocks.filter { ($0["type"] as? String) == "image" }
        XCTAssertEqual(imageBlocks.count, 1,
            "Encoder must emit exactly one image block — the input image — and skip the generated image")

        let textBlocks = blocks.filter { ($0["type"] as? String) == "text" }
        XCTAssertEqual(textBlocks.count, 1)
        XCTAssertEqual(textBlocks.first?["text"] as? String, "hi")

        // Belt-and-braces: nothing in the serialised body should leak any
        // field unique to the generated-image payload.
        let json = String(data: try JSONSerialization.data(withJSONObject: encoded), encoding: .utf8) ?? ""
        assertNoGeneratedImageLeaked(in: json)
    }

    func test_claudeEncoder_generatedImageOnly_collapsesToPlainTextTurn() throws {
        // A turn whose only non-text part is `.generatedImage` has no
        // input image, so the encoder must take the "image-less" branch
        // and collapse to plain string content. Crucially, it must not
        // accidentally pick the structured-content path that loops over
        // parts — that would surface the generated image as a wire block.
        let message = StructuredMessage(role: "user", parts: [
            .text("hello"),
            generatedImagePart(),
        ])

        let encoded = CloudMessageEncoder.claude.encodeStructuredMessageContent(for: message)

        XCTAssertEqual(encoded["content"] as? String, "hello",
            "Image-less user turn (input-image-wise) must collapse to plain string content")

        let json = String(data: try JSONSerialization.data(withJSONObject: encoded), encoding: .utf8) ?? ""
        assertNoGeneratedImageLeaked(in: json)
    }

    // MARK: - OpenAI (Chat Completions API)

    func test_openAIEncoder_skipsGeneratedImageOnUserTurn() throws {
        let message = StructuredMessage(role: "user", parts: [
            .text("hi"),
            .image(data: inputImageBytes, mimeType: inputImageMime),
            generatedImagePart(),
        ])

        let encoded = CloudMessageEncoder.openAI.encodeStructuredMessageContent(for: message)

        // Image-bearing user turn → structured content[].
        let parts = try XCTUnwrap(encoded["content"] as? [[String: Any]],
            "Image-bearing user turn must serialize as a content[] array")

        let imageURLParts = parts.filter { ($0["type"] as? String) == "image_url" }
        XCTAssertEqual(imageURLParts.count, 1,
            "Encoder must emit exactly one image_url part — the input image — and skip the generated image")

        let textParts = parts.filter { ($0["type"] as? String) == "text" }
        XCTAssertEqual(textParts.count, 1)
        XCTAssertEqual(textParts.first?["text"] as? String, "hi")

        let json = String(data: try JSONSerialization.data(withJSONObject: encoded), encoding: .utf8) ?? ""
        assertNoGeneratedImageLeaked(in: json)
    }

    func test_openAIEncoder_generatedImageOnly_collapsesToPlainTextTurn() throws {
        // No input image present → encoder must take the plain-string
        // branch, not the structured-content branch that loops over parts.
        let message = StructuredMessage(role: "user", parts: [
            .text("hello"),
            generatedImagePart(),
        ])

        let encoded = CloudMessageEncoder.openAI.encodeStructuredMessageContent(for: message)

        XCTAssertEqual(encoded["content"] as? String, "hello",
            "Image-less user turn must collapse to plain string content")

        let json = String(data: try JSONSerialization.data(withJSONObject: encoded), encoding: .utf8) ?? ""
        assertNoGeneratedImageLeaked(in: json)
    }
}
