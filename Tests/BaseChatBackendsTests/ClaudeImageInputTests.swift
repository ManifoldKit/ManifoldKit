#if CloudSaaS
import XCTest
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

/// Tests for #20 (part): image content blocks on the Anthropic Messages API.
///
/// `ClaudeBackend` must:
///
/// 1. Encode each ``MessagePart/image(data:mimeType:)`` part as a
///    `{type:"image", source:{type:"base64", media_type:..., data:...}}`
///    block on the request body.
/// 2. Place image blocks **before** the matching text block on a user turn —
///    Anthropic recommends this ordering so the model attends to the visual
///    context first.
/// 3. Reject requests that exceed the per-turn image cap before the round
///    trip, with a message that names the offending count.
/// 4. Reject image attachments when the configured model isn't vision-capable.
/// 5. Advertise `supportsVision` based on the configured model name so
///    GenerationCoordinator's pre-flight matches the wire-level behaviour.
final class ClaudeImageInputTests: XCTestCase {

    // MARK: - Helpers

    private func makeBackend(
        modelName: String = "claude-sonnet-4-20250514"
    ) async throws -> (ClaudeBackend, URL) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = ClaudeBackend(urlSession: session)
        let url = URL(string: "https://claude-image-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-ant-test", modelName: modelName)
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        return (backend, url)
    }

    private func sseStub(url: URL) {
        let chunk = Data("""
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}\n\ndata: {"type":"message_stop"}\n\n
            """.utf8)
        MockURLProtocol.stub(url: url, response: .sse(chunks: [chunk], statusCode: 200))
    }

    private func extractRequestJSON(host: String?) throws -> [String: Any] {
        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url?.host == host })
        let body: Data
        if let direct = captured?.httpBody {
            body = direct
        } else if let stream = captured?.httpBodyStream {
            var data = Data()
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read > 0 { data.append(buffer, count: read) }
            }
            stream.close()
            body = data
        } else {
            throw NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "no body"])
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// 4-byte payload — the bytes are not a valid PNG, but the encoder
    /// doesn't decode the data, it only base64-encodes it. Using a tiny
    /// fixture keeps the test fast and the assertion exact.
    private func fixtureImage(_ marker: UInt8) -> Data {
        Data([0x89, 0x50, 0x4E, marker])
    }

    // MARK: - 1. Single image — encoded as a content block

    func test_singleImage_emitsImageBlockBeforeText() async throws {
        let (backend, url) = try await makeBackend()
        sseStub(url: url)
        defer { MockURLProtocol.unstub(url: url) }

        let imageData = fixtureImage(0xAA)
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .image(data: imageData, mimeType: "image/png"),
                .text("Describe this image."),
            ]),
        ])

        let stream = try backend.generate(prompt: "Describe this image.", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let json = try extractRequestJSON(host: url.host)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let userContent = try XCTUnwrap(messages[0]["content"] as? [[String: Any]],
            "Image-bearing user turn must serialize as a content[] array, not a string")
        XCTAssertEqual(userContent.count, 2, "Expect exactly two blocks: image + text")

        XCTAssertEqual(userContent[0]["type"] as? String, "image",
            "Image block must come first — Anthropic recommends image-then-text ordering")
        let source = try XCTUnwrap(userContent[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, imageData.base64EncodedString(),
            "Image bytes must round-trip as base64 verbatim")

        XCTAssertEqual(userContent[1]["type"] as? String, "text")
        XCTAssertEqual(userContent[1]["text"] as? String, "Describe this image.")
    }

    // MARK: - 2. Multiple images on one turn

    func test_multipleImages_allEncoded_inOrder() async throws {
        let (backend, url) = try await makeBackend()
        sseStub(url: url)
        defer { MockURLProtocol.unstub(url: url) }

        let img1 = fixtureImage(0x01)
        let img2 = fixtureImage(0x02)
        let img3 = fixtureImage(0x03)
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .image(data: img1, mimeType: "image/png"),
                .image(data: img2, mimeType: "image/jpeg"),
                .image(data: img3, mimeType: "image/webp"),
                .text("Compare these."),
            ]),
        ])

        let stream = try backend.generate(prompt: "Compare these.", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let json = try extractRequestJSON(host: url.host)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let userContent = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(userContent.count, 4, "Three image blocks plus one text block")

        let imageBlocks = userContent.prefix(3)
        for block in imageBlocks {
            XCTAssertEqual(block["type"] as? String, "image")
        }
        XCTAssertEqual((imageBlocks[0]["source"] as? [String: Any])?["media_type"] as? String, "image/png")
        XCTAssertEqual((imageBlocks[1]["source"] as? [String: Any])?["media_type"] as? String, "image/jpeg")
        XCTAssertEqual((imageBlocks[2]["source"] as? [String: Any])?["media_type"] as? String, "image/webp")

        // Image data ordering must match the parts ordering — sabotage check:
        // if the encoder reordered images, these byte-level matches would fail.
        XCTAssertEqual((imageBlocks[0]["source"] as? [String: Any])?["data"] as? String, img1.base64EncodedString())
        XCTAssertEqual((imageBlocks[1]["source"] as? [String: Any])?["data"] as? String, img2.base64EncodedString())
        XCTAssertEqual((imageBlocks[2]["source"] as? [String: Any])?["data"] as? String, img3.base64EncodedString())

        XCTAssertEqual(userContent[3]["type"] as? String, "text")
        XCTAssertEqual(userContent[3]["text"] as? String, "Compare these.")
    }

    // MARK: - 3. Image + text mixed (no images on assistant turn)

    func test_imageAndText_mixedHistory_assistantTurnUnaffected() async throws {
        let (backend, url) = try await makeBackend()
        sseStub(url: url)
        defer { MockURLProtocol.unstub(url: url) }

        let imageData = fixtureImage(0xBB)
        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .image(data: imageData, mimeType: "image/png"),
                .text("What is this?"),
            ]),
            StructuredMessage(role: "assistant", content: "It looks like a logo."),
            StructuredMessage(role: "user", content: "Thanks."),
        ])

        let stream = try backend.generate(prompt: "Thanks.", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let json = try extractRequestJSON(host: url.host)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)

        // First turn: structured content with image + text.
        XCTAssertNotNil(messages[0]["content"] as? [[String: Any]],
            "Image-bearing user turn must serialize as a content[] array")

        // Second turn: assistant text-only turn serialises as a structured
        // content[] with a single text block — the existing
        // ``encodeMessageContent`` contract for assistant turns.
        let assistantContent = try XCTUnwrap(messages[1]["content"] as? [[String: Any]],
            "Assistant turns serialise as content[] arrays (see ClaudeStructuredReplayTests)")
        XCTAssertEqual(assistantContent.count, 1)
        XCTAssertEqual(assistantContent[0]["type"] as? String, "text")
        XCTAssertEqual(assistantContent[0]["text"] as? String, "It looks like a logo.")

        // Third turn: text-only user turn collapses to the simple form.
        XCTAssertEqual(messages[2]["content"] as? String, "Thanks.",
            "Image-less user turns must keep the simple string content shape")
    }

    // MARK: - 4. > 5 images per turn errors out before the round trip

    func test_moreThanFiveImagesPerTurn_throwsBeforeRequest() async throws {
        let (backend, url) = try await makeBackend()
        defer { MockURLProtocol.unstub(url: url) }

        var parts: [MessagePart] = (0..<6).map { i in
            .image(data: fixtureImage(UInt8(i)), mimeType: "image/png")
        }
        parts.append(.text("too many"))
        backend.setStructuredHistory([StructuredMessage(role: "user", parts: parts)])

        do {
            let stream = try backend.generate(prompt: "too many", systemPrompt: nil, config: GenerationConfig())
            for try await _ in stream.events { }
            XCTFail("Should have thrown before opening the stream")
        } catch let error as InferenceError {
            guard case .inferenceFailure(let message) = error else {
                XCTFail("Expected inferenceFailure, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("5"), "Error should name the cap: \(message)")
            XCTAssertTrue(message.contains("6"), "Error should name the offending count: \(message)")
        }
    }

    // MARK: - 5. Non-vision model rejects image input

    func test_nonVisionModel_rejectsImageInput() async throws {
        // `claude-2.1` predates vision support — image attachments must
        // never be forwarded to it.
        let (backend, url) = try await makeBackend(modelName: "claude-2.1")
        defer { MockURLProtocol.unstub(url: url) }

        backend.setStructuredHistory([
            StructuredMessage(role: "user", parts: [
                .image(data: fixtureImage(0xCC), mimeType: "image/png"),
                .text("hi"),
            ]),
        ])

        do {
            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
            for try await _ in stream.events { }
            XCTFail("Should have thrown for non-vision model")
        } catch let error as InferenceError {
            guard case .inferenceFailure(let message) = error else {
                XCTFail("Expected inferenceFailure, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("claude-2.1"), "Error should name the model: \(message)")
            XCTAssertTrue(message.lowercased().contains("image"), "Error should mention images: \(message)")
        }
    }

    // MARK: - 6. Capabilities flip with model name

    func test_capabilities_supportsVision_reflectsModelName() {
        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "x",
            modelName: "claude-sonnet-4-20250514"
        )
        XCTAssertTrue(backend.capabilities.supportsVision,
            "Claude 4 models must advertise vision support")

        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "x",
            modelName: "claude-3-5-sonnet-20241022"
        )
        XCTAssertTrue(backend.capabilities.supportsVision,
            "Claude 3.5 models must advertise vision support")

        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "x",
            modelName: "claude-2.1"
        )
        XCTAssertFalse(backend.capabilities.supportsVision,
            "Claude 2.x predates vision support — must not advertise it")

        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "x",
            modelName: "claude-instant-1.2"
        )
        XCTAssertFalse(backend.capabilities.supportsVision,
            "Claude Instant predates vision support — must not advertise it")
    }

    // MARK: - 7. isVisionCapableModel — direct unit coverage

    func test_isVisionCapableModel_classifierAcceptsKnownFamilies() {
        XCTAssertTrue(ClaudeBackend.isVisionCapableModel("claude-3-haiku-20240307"))
        XCTAssertTrue(ClaudeBackend.isVisionCapableModel("claude-3-5-sonnet-20241022"))
        XCTAssertTrue(ClaudeBackend.isVisionCapableModel("claude-3-7-sonnet-20250219"))
        XCTAssertTrue(ClaudeBackend.isVisionCapableModel("claude-sonnet-4-20250514"))
        XCTAssertTrue(ClaudeBackend.isVisionCapableModel("claude-opus-4-1-20250805"))
        // Vendor-prefixed aliases (Bedrock-style) should still match.
        XCTAssertTrue(ClaudeBackend.isVisionCapableModel("anthropic.claude-sonnet-4"))
    }

    func test_isVisionCapableModel_classifierRejectsLegacyFamilies() {
        XCTAssertFalse(ClaudeBackend.isVisionCapableModel("claude-2"))
        XCTAssertFalse(ClaudeBackend.isVisionCapableModel("claude-2.1"))
        XCTAssertFalse(ClaudeBackend.isVisionCapableModel("claude-instant-1"))
        XCTAssertFalse(ClaudeBackend.isVisionCapableModel("claude-instant-1.2"))
        // Unknown / future family that doesn't match any allowlisted token
        // defaults to false — better to surface a clear error than to assume
        // vision support and 400.
        XCTAssertFalse(ClaudeBackend.isVisionCapableModel("some-other-model"))
    }
}
#endif
